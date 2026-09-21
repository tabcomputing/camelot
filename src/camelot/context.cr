require "./a11y"

module Camelot
  # What the user is doing right now, packaged for an AI: the active
  # application and window, the focused widget with its text, and the
  # breadcrumb of ancestors between them.
  class Context
    include JSON::Serializable
    include YAML::Serializable

    record Application, name : String, pid : UInt32?, toolkit : String? do
      include JSON::Serializable
      include YAML::Serializable
    end

    property application : Application?
    property window : A11y::Node?
    property ancestors : Array(A11y::Node)
    property focus : A11y::Node?

    def initialize(@application, @window, @ancestors, @focus)
    end

    def self.capture(max_text : Int32 = 4000) : Context
      focus = A11y.focused
      window = A11y.active_window
      chain = focus ? A11y.ancestry(focus) : (window ? A11y.ancestry(window) : [] of Atspi::Accessible)

      app = chain.first?
      window ||= chain.find { |a| A11y.active?(a) } || chain[1]?

      leaf_opts = A11y::Options.new(max_text: max_text, actions: true)
      brief = A11y::Options.new(max_text: 0, extents: false)

      # Breadcrumb: what lies between the window and the focus, minus the
      # anonymous layout containers.
      between = [] of Atspi::Accessible
      if window && focus
        wi = chain.index(window)
        fi = chain.index(focus)
        between = chain[(wi + 1)...fi] if wi && fi && fi > wi + 1
      end
      ancestors = between.map { |a| A11y.snapshot(a, brief) }
      ancestors.reject! { |n| n.name.nil? && A11y::WRAPPER_ROLES.includes?(n.role) }

      new(
        app ? Application.new(A11y.safe("") { app.name }, A11y.safe(nil) { app.process_id }, A11y.safe(nil) { app.toolkit_name }) : nil,
        window ? A11y.snapshot(window, brief) : nil,
        ancestors,
        focus ? A11y.snapshot(focus, leaf_opts) : nil,
      )
    end
  end
end
