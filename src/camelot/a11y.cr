require "json"
require "yaml"
require "gi-crystal"
require "./config"

GICrystal.require("Atspi", "2.0")

@[Link("glib-2.0")]
lib LibGLibArray
  fun g_array_free(array : Void*, free_segment : LibC::Int) : Pointer(LibC::Char)
end

module Camelot
  # Read side of the AT-SPI2 accessibility bus: turns live `Atspi::Accessible`
  # objects into plain, serializable `Node` snapshots. Every D-Bus round trip
  # can fail (the app may have died mid-walk), so lookups are best-effort and
  # degrade to `nil` / empty rather than aborting a whole dump.
  module A11y
    CACHE_DEFAULT = Atspi::Cache::Parent | Atspi::Cache::Children | Atspi::Cache::Name |
                    Atspi::Cache::Description | Atspi::Cache::States | Atspi::Cache::Role |
                    Atspi::Cache::Interfaces

    class Error < Exception; end

    def self.init : Nil
      return if Atspi.is_initialized
      status = Atspi.init
      raise Error.new("could not connect to the accessibility bus (atspi_init=#{status}); is at-spi2 running?") unless status.zero?
    end

    # ---- Snapshot types ------------------------------------------------------

    record Extents, x : Int32, y : Int32, width : Int32, height : Int32 do
      include JSON::Serializable
      include YAML::Serializable
    end

    # Text-interface content. `content` is capped; `truncated` says so, and
    # `offset` is where `content` starts within the full text.
    record TextInfo, length : Int32, caret : Int32, offset : Int32, content : String, truncated : Bool do
      include JSON::Serializable
      include YAML::Serializable
    end

    class Node
      include JSON::Serializable
      include YAML::Serializable

      # Role name as AT-SPI reports it ("push button", "text", "frame"...).
      property role : String
      property name : String?
      property description : String?
      # Index path from the application root ("2/0/5"); with `pid` it
      # addresses the node again later (until the tree changes).
      property path : String
      property pid : UInt32?
      property states : Array(String)
      property extents : Extents?
      property text : TextInfo?
      property value : Float64?
      property actions : Array(String)?
      property child_count : Int32
      property children : Array(Node)?
      # Set when the widget holds secrets (a password field): its text is
      # never captured, whatever the options say.
      property redacted : Bool?

      def initialize(@role, @name, @description, @path, @pid, @states, @extents, @text, @value, @actions, @child_count, @children = nil, @redacted = nil)
      end
    end

    # Snapshot knobs. `depth` 0 means "this node only"; negative means unlimited.
    # `max_text` 0 skips text; negative means unlimited. `prune` splices out
    # anonymous layout containers (see `WRAPPER_ROLES`) so a tree reads as
    # content rather than toolkit plumbing. `hidden` keeps children that are
    # not SHOWING (collapsed menus, off-screen popups, hidden tabs).
    record Options,
      depth : Int32 = 0,
      max_text : Int32 = 200,
      extents : Bool = true,
      actions : Bool = false,
      all_states : Bool = false,
      prune : Bool = true,
      hidden : Bool = false

    # Roles that are pure layout when they carry no name, text or value.
    WRAPPER_ROLES = ["panel", "grouping", "filler", "section", "scroll pane", "viewport",
                     "layered pane", "split pane", "root pane", "glass pane"]

    # States that carry information beyond the usual "enabled sensitive
    # visible showing" chorus; the rest are kept only with `all_states`.
    QUIET_STATES = %w[enabled sensitive visible showing opaque]

    # ---- Desktop / application access ---------------------------------------

    def self.desktop : Atspi::Accessible
      init
      Atspi.desktop(0)
    end

    def self.applications : Array(Atspi::Accessible)
      children(desktop)
    end

    # Find an application by pid, exact name, or case-insensitive substring.
    def self.application(query : String) : Atspi::Accessible?
      apps = applications
      if pid = query.to_u32?
        apps.find { |a| safe(0_u32) { a.process_id } == pid }
      else
        apps.find { |a| safe("") { a.name } == query } ||
          apps.find { |a| safe("") { a.name }.downcase.includes?(query.downcase) }
      end
    end

    def self.windows(app : Atspi::Accessible) : Array(Atspi::Accessible)
      children(app)
    end

    def self.active?(acc : Atspi::Accessible) : Bool
      safe(false) { acc.state_set.contains(Atspi::StateType::Active) }
    end

    def self.focused?(acc : Atspi::Accessible) : Bool
      safe(false) { acc.state_set.contains(Atspi::StateType::Focused) }
    end

    # The window the user is working in, if any app reports one as ACTIVE.
    def self.active_window : Atspi::Accessible?
      applications.each do |app|
        windows(app).each { |w| return w if active?(w) }
      end
      nil
    end

    # The widget with keyboard focus. Looks inside the active window first,
    # then any window; uses the Collection interface when the toolkit offers
    # it and falls back to a depth-first walk otherwise.
    def self.focused : Atspi::Accessible?
      if win = active_window
        if f = find_focused(win)
          return f
        end
      end
      applications.each do |app|
        windows(app).each do |w|
          next if active?(w)
          if f = find_focused(w)
            return f
          end
        end
      end
      nil
    end

    def self.find_focused(root : Atspi::Accessible) : Atspi::Accessible?
      return root if focused?(root)
      if safe(false) { !collection?(root).nil? }
        hits = safe([] of Atspi::Accessible) { collection_matches(root, focused_rule, 1) }
        return hits.first unless hits.empty?
      end
      dfs_focused(root)
    end

    private def self.dfs_focused(acc : Atspi::Accessible) : Atspi::Accessible?
      children(acc).each do |child|
        return child if focused?(child)
        if hit = dfs_focused(child)
          return hit
        end
      end
      nil
    end

    # Deepest accessible under (x, y) within `window`, in window-relative
    # coordinates (the only kind Wayland toolkits can answer).
    # (`contains` is not consulted: GTK answers it wrongly for window coords.)
    def self.at_point(window : Atspi::Accessible, x : Int32, y : Int32) : Atspi::Accessible?
      hit = descend_to_point(window, x, y, Atspi::CoordType::Window)
      hit == window ? nil : hit
    end

    # Deepest accessible under screen point (x, y), searching every window
    # that claims to contain it (X11 / XWayland apps report real positions).
    def self.at_screen_point(x : Int32, y : Int32) : Atspi::Accessible?
      candidates = [] of Atspi::Accessible
      applications.each do |app|
        windows(app).each do |w|
          next unless safe(false) { component?(w).try(&.contains(x, y, Atspi::CoordType::Screen)) }
          candidates << w
        end
      end
      # Prefer the active window when several overlap.
      win = candidates.find { |w| active?(w) } || candidates.first?
      return nil unless win
      descend_to_point(win, x, y, Atspi::CoordType::Screen)
    end

    private def self.descend_to_point(acc : Atspi::Accessible, x, y, coords) : Atspi::Accessible
      current = acc
      loop do
        deeper = safe(nil) { component?(current).try(&.accessible_at_point(x, y, coords)) }
        break if deeper.nil? || deeper == current
        current = deeper
      end
      current
    end

    # Chain from the application down to `acc` (inclusive).
    def self.ancestry(acc : Atspi::Accessible) : Array(Atspi::Accessible)
      chain = [acc]
      current = acc
      while parent = parent?(current)
        break if safe("") { parent.role_name } == "desktop frame"
        chain.unshift(parent)
        current = parent
      end
      chain
    end

    # ---- Snapshots -----------------------------------------------------------

    def self.snapshot(acc : Atspi::Accessible, opts : Options = Options.new, path : String? = nil) : Node
      path ||= index_path(acc)
      return redacted(acc, path) if ignored?(acc)
      node = build(acc, opts, path, opts.depth).not_nil!
      if opts.prune
        node.children = node.children.try { |kids| kids.flat_map { |k| prune(k) } }
      end
      node
    end

    # On the user's ignore list (by application name)?
    def self.ignored?(acc : Atspi::Accessible) : Bool
      Config.ignored?(application?(acc).try { |a| safe(nil) { a.name } })
    end

    # Role and name only: what an ignored application looks like.
    def self.redacted(acc : Atspi::Accessible, path : String) : Node
      Node.new(safe("unknown") { acc.role_name }, blank_to_nil(safe("") { acc.name }), nil, path,
        safe(nil) { acc.process_id }, [] of String, nil, nil, nil, nil, 0, nil, true)
    end

    # A wrapper with nothing to say is replaced by its (pruned) children.
    # Paths are untouched, so a pruned node still addresses the real widget.
    def self.prune(node : Node) : Array(Node)
      kids = node.children.try { |cs| cs.flat_map { |k| prune(k) } }
      node.children = kids
      if wrapper?(node)
        kids || [] of Node
      else
        [node]
      end
    end

    def self.wrapper?(node : Node) : Bool
      return false unless WRAPPER_ROLES.includes?(node.role)
      return false if node.name || node.description || node.text || node.value
      return false if node.actions.try { |a| !a.empty? }
      return false if node.states.includes?("focused")
      node.child_count == 0 || !node.children.nil?
    end

    # Returns nil for a non-root node that is hidden (unless `opts.hidden`).
    private def self.build(acc : Atspi::Accessible, opts : Options, path : String, depth : Int32, root = true) : Node?
      set = safe(nil) { acc.state_set }
      extents = opts.extents ? extents_of(acc) : nil
      unless root || opts.hidden
        # Fetch extents only when needed to settle the question.
        e = extents || (set && !set.contains(Atspi::StateType::Showing) ? extents_of(acc) : nil)
        return nil if hidden?(set, e)
      end

      role = safe("unknown") { acc.role_name }
      name = blank_to_nil(safe("") { acc.name })
      description = blank_to_nil(safe("") { acc.description })
      pid = safe(nil) { acc.process_id }
      states = state_names(set, opts.all_states)
      secret = secret?(acc)
      text = secret ? nil : text_of(acc, opts.max_text)
      text = nil if text && text.content == name # labels: the name already says it
      value = secret ? nil : safe(nil) { value?(acc).try(&.current_value) }
      actions = opts.actions ? actions_of(acc) : nil
      count = safe(0) { acc.child_count }

      kids = nil
      if depth != 0 && count > 0
        kids = [] of Node
        children(acc).each_with_index do |child, i|
          if node = build(child, opts, path.empty? ? i.to_s : "#{path}/#{i}", depth - 1, root: false)
            kids << node
          end
        end
      end

      Node.new(role, name, description, path, pid, states, extents, text, value, actions, count, kids, secret || nil)
    end

    # Hidden means not VISIBLE, or not SHOWING with no real on-screen box.
    # SHOWING alone is not enough: Firefox clears it for its whole chrome
    # while the window is occluded, but its collapsed menus are also
    # "visible, not showing" — the -1x-1 extents are what tell them apart.
    def self.hidden?(set : Atspi::StateSet?, extents : Extents?) : Bool
      return false unless set
      return true unless set.contains(Atspi::StateType::Visible)
      return false if set.contains(Atspi::StateType::Showing)
      extents.nil? || extents.width <= 0 || extents.height <= 0
    end

    # Password entries: the toolkit masks them on screen, so we do too.
    def self.secret?(acc : Atspi::Accessible) : Bool
      safe(false) { acc.role == Atspi::Role::PasswordText }
    end

    def self.children(acc : Atspi::Accessible) : Array(Atspi::Accessible)
      count = safe(0) { acc.child_count }
      (0...count).compact_map { |i| child_at_index?(acc, i) }
    end

    # Index path of `acc` below its application ("" for the application itself).
    def self.index_path(acc : Atspi::Accessible) : String
      ancestry(acc).skip(1).map { |a| safe(-1) { a.index_in_parent } }.join("/")
    end

    def self.state_names(set : Atspi::StateSet?, all : Bool) : Array(String)
      return [] of String unless set
      # `contains` is a local bitmask test; only fetching the set hits the bus.
      names = Atspi::StateType.values.select { |s| set.contains(s) }.map { |s| s.to_s.underscore.tr("_", " ") }
      all ? names : names.reject { |n| QUIET_STATES.includes?(n) }
    end

    def self.extents_of(acc : Atspi::Accessible) : Extents?
      safe(nil) do
        c = component?(acc)
        next nil unless c
        # Window-relative: on Wayland toolkits have no global position to
        # report, so screen coordinates come back as zeros.
        r = c.extents(Atspi::CoordType::Window)
        Extents.new(r.x, r.y, r.width, r.height)
      end
    end

    # Hypertext marks each embedded child with U+FFFC; that is structure the
    # tree already shows, not content, so it is stripped.
    EMBEDDED_OBJECT = '￼'

    # Text content, capped at `max` characters kept around the caret.
    # `max` 0 skips text entirely; negative means unlimited.
    def self.text_of(acc : Atspi::Accessible, max : Int32) : TextInfo?
      return nil if max == 0
      safe(nil) do
        t = text?(acc)
        next nil unless t
        length = t.character_count
        next nil if length <= 0
        caret = t.caret_offset
        info = if max < 0 || length <= max
                 TextInfo.new(length, caret, 0, t.text(0, length), false)
               else
                 start = (caret - max // 2).clamp(0, length - max)
                 TextInfo.new(length, caret, start, t.text(start, start + max), true)
               end
        next info unless info.content.includes?(EMBEDDED_OBJECT)
        content = info.content.delete(EMBEDDED_OBJECT)
        content.blank? ? nil : info.copy_with(content: content)
      end
    end

    def self.actions_of(acc : Atspi::Accessible) : Array(String)?
      safe(nil) do
        a = action?(acc)
        next nil unless a
        (0...a.n_actions).map { |i| a.localized_name(i) }
      end
    end

    # ---- Helpers -------------------------------------------------------------

    # Object-returning lookups, called raw: libatspi answers NULL (with or
    # without a GError) for a child that vanished or an app whose cache is
    # broken, and the generated wrappers dereference that NULL.
    {% for name in %w[child_at_index parent application] %}
      def self.{{name.id}}?(acc : Atspi::Accessible{% if name == "child_at_index" %}, index : Int32{% end %}) : Atspi::Accessible?
        error = Pointer(LibGLib::Error).null
        ptr = LibAtspi.atspi_accessible_get_{{name.id}}(acc.to_unsafe, {% if name == "child_at_index" %}index, {% end %}pointerof(error))
        unless error.null?
          LibGLib.g_error_free(error)
          return nil
        end
        ptr.null? ? nil : Atspi::Accessible.new(ptr, GICrystal::Transfer::Full)
      end
    {% end %}

    # Interface lookups that work across libatspi versions: the `is_*`
    # predicates only exist from 2.5x on, while `get_*_iface` (NULL when the
    # object lacks the interface) has always been there. The generated
    # getters would hand that NULL to a wrapper constructor, so call the C
    # functions directly.
    {% for name, klass in {component: "AbstractComponent", text: "AbstractText", value: "AbstractValue",
                           action: "AbstractAction", collection: "AbstractCollection"} %}
      def self.{{name}}?(acc : Atspi::Accessible) : Atspi::{{klass.id}}?
        ptr = LibAtspi.atspi_accessible_get_{{name}}_iface(acc.to_unsafe)
        ptr.null? ? nil : Atspi::{{klass.id}}.new(ptr, GICrystal::Transfer::Full)
      end
    {% end %}

    # "Any object in the FOCUSED state." Built with the C constructor: the
    # StateSet array constructor is a GArray gi-crystal can't marshal, and
    # older GIRs don't mark the unused rule arguments nullable.
    def self.focused_rule : Atspi::MatchRule
      states = Atspi::StateSet.new
      states.add(Atspi::StateType::Focused)
      invalid = Atspi::CollectionMatchType::Invalid.value
      ptr = LibAtspi.atspi_match_rule_new(states.to_unsafe, Atspi::CollectionMatchType::All.value,
        Pointer(Void).null, invalid, Pointer(UInt32).null, invalid, Pointer(Pointer(LibC::Char)).null, invalid, 0)
      Atspi::MatchRule.new(ptr, GICrystal::Transfer::Full)
    end

    # Hand-rolled `atspi_collection_get_matches`: it returns a GArray of
    # AtspiAccessible*, which gi-crystal does not know how to unpack.
    def self.collection_matches(acc : Atspi::Accessible, rule : Atspi::MatchRule, count : Int32) : Array(Atspi::Accessible)
      error = Pointer(LibGLib::Error).null
      garray = LibAtspi.atspi_collection_get_matches(acc.to_unsafe, rule.to_unsafe,
        Atspi::CollectionSortOrder::Canonical.value, count, 1, pointerof(error))
      Atspi.raise_gerror(error) unless error.null?
      return [] of Atspi::Accessible if garray.null?
      arr = garray.as(Pointer(LibGLib::Array)).value
      # Not every toolkit's Collection implementation is sound: gnome-shell
      # answers with a length that is not a length. Anything past what we
      # asked for is nonsense, and the caller falls back to walking.
      length = arr.data.null? ? 0_i64 : arr.len.to_i64.clamp(0_i64, count.to_i64)
      items = arr.data.as(Pointer(Pointer(Void)))
      result = (0...length).map { |i| Atspi::Accessible.new(items[i], GICrystal::Transfer::Full) }
      LibGLibArray.g_array_free(garray.as(Void*), 0)
      result
    end

    private def self.blank_to_nil(s : String) : String?
      s.empty? ? nil : s
    end

    # Run an AT-SPI call, returning `default` if the bus throws.
    def self.safe(default : T, &block : -> U) : T | U forall T, U
      yield
    rescue GLib::Error | ArgumentError
      default
    end
  end
end
