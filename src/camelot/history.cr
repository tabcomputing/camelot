require "./events"

module Camelot
  # The daemon's memory: a bounded log of events, and the digest of it that
  # answers "what has the user been doing?"
  class History
    # A digest line. `count` > 1 means several raw events were folded into it.
    class Entry
      include JSON::Serializable
      include YAML::Serializable

      property time : Time
      property until : Time?
      property kind : String # window | focus | edit | load
      property app : String?
      property pid : UInt32?
      property role : String?
      property name : String?
      property path : String?
      property count : Int32
      property text : String?

      def initialize(@time, @kind, @app, @pid, @role, @name, @path, @text = nil, @count = 1, @until = nil)
      end

      # The last non-blank line of an insertion, capped: a hint, not a log.
      def self.snippet(text : String?) : String?
        return nil unless text
        line = text.lines.reverse.find { |l| !l.blank? }.try(&.strip)
        return nil unless line
        line.size > SNIPPET_MAX ? line[0, SNIPPET_MAX] + "…" : line
      end
    end

    property size : Int32
    property retention : Time::Span
    getter total : Int64 = 0

    # Keeps at most `size` events and nothing older than `retention`.
    def initialize(@size : Int32 = 2000, @retention : Time::Span = 30.minutes)
      @events = Deque(Events::Event).new
    end

    def record(event : Events::Event) : Nil
      @events.push(event)
      @events.shift if @events.size > @size
      @total += 1
      expire(event.time)
    end

    # Drop what has aged out, as of `now`.
    def expire(now : Time = Time.local) : Nil
      cutoff = now - @retention
      while (oldest = @events.first?) && oldest.time < cutoff
        @events.shift
      end
    end

    def count(now : Time = Time.local) : Int32
      expire(now)
      @events.size
    end

    # Raw events newer than `since`, oldest first.
    def since(since : Time, now : Time = Time.local) : Array(Events::Event)
      expire(now)
      @events.select { |e| e.time >= since }
    end

    # Edits on one widget fold into one entry while they keep coming
    # within this gap — longer for terminals, whose repaints are output,
    # not typing.
    FOLD_GAP          = 5.seconds
    TERMINAL_FOLD_GAP = 60.seconds
    SNIPPET_MAX       = 100

    # The digest, built incrementally: `add` folds one event and says
    # whether it appended a new entry or updated an existing one, so a
    # live view can change a single row instead of re-deriving the list.
    # `History#recent` is the batch use of the same folding.
    class Digest
      getter entries = [] of Entry
      @open_edits = {} of {UInt32?, String?} => Entry

      # Fold one event. Returns the entry touched and how, or nil for
      # events the digest ignores (focus lost, window deactivate...).
      def add(e : Events::Event) : {Entry, Symbol}?
        case e.type
        when "window:activate"
          append(Entry.new(e.time, "window", e.app, e.pid, e.role, e.name, e.path))
        when "object:state-changed:focused"
          return nil unless e.detail1 == 1
          append(Entry.new(e.time, "focus", e.app, e.pid, e.role, e.name, e.path))
        when .starts_with?("object:text-changed")
          key = {e.pid, e.path}
          gap = e.role == "terminal" ? TERMINAL_FOLD_GAP : FOLD_GAP
          snippet = e.type.ends_with?("insert") ? Entry.snippet(e.text) : nil
          if (open = @open_edits[key]?) && e.time - (open.until || open.time) <= gap
            open.count += 1
            open.until = e.time
            open.text = snippet if snippet
            {open, :updated}
          else
            entry = Entry.new(e.time, e.role == "terminal" ? "output" : "edit", e.app, e.pid, e.role, e.name, e.path, snippet)
            @open_edits[key] = entry
            append(entry)
          end
        when "document:load-complete"
          append(Entry.new(e.time, "load", e.app, e.pid, e.role, e.name, e.path))
        end
      end

      # Drop entries whose last activity is older than `since`. Returns them.
      def prune(since : Time) : Array(Entry)
        gone, @entries = @entries.partition { |en| (en.until || en.time) < since }
        @open_edits.reject! { |_, en| gone.includes?(en) }
        gone
      end

      private def append(entry : Entry) : {Entry, Symbol}
        @entries << entry
        {entry, :appended}
      end
    end

    # Digest of events newer than `since`, newest last, at most `limit`
    # lines.
    def recent(since : Time, limit : Int32 = 50) : Array(Entry)
      digest = Digest.new
      since(since).each { |e| digest.add(e) }
      entries = digest.entries
      entries.size > limit ? entries[-limit..] : entries
    end
  end
end
