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

    # Digest of events newer than `since`, newest last, at most `limit`
    # lines. Text edits on one widget fold into one entry (even when other
    # widgets' events interleave); focus-lost and window-deactivate events
    # are noise and dropped.
    def recent(since : Time, limit : Int32 = 50) : Array(Entry)
      entries = [] of Entry
      open_edits = {} of {UInt32?, String?} => Entry
      since(since).each do |e|
        case e.type
        when "window:activate"
          entries << Entry.new(e.time, "window", e.app, e.pid, e.role, e.name, e.path)
        when "object:state-changed:focused"
          next unless e.detail1 == 1
          entries << Entry.new(e.time, "focus", e.app, e.pid, e.role, e.name, e.path)
        when .starts_with?("object:text-changed")
          key = {e.pid, e.path}
          gap = e.role == "terminal" ? TERMINAL_FOLD_GAP : FOLD_GAP
          snippet = e.type.ends_with?("insert") ? Entry.snippet(e.text) : nil
          if (open = open_edits[key]?) && e.time - (open.until || open.time) <= gap
            open.count += 1
            open.until = e.time
            open.text = snippet if snippet
          else
            entry = Entry.new(e.time, e.role == "terminal" ? "output" : "edit", e.app, e.pid, e.role, e.name, e.path, snippet)
            entries << entry
            open_edits[key] = entry
          end
        when "document:load-complete"
          entries << Entry.new(e.time, "load", e.app, e.pid, e.role, e.name, e.path)
        end
      end
      entries.size > limit ? entries[-limit..] : entries
    end
  end
end
