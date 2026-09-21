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

      # Same widget as `e`, for coalescing.
      def same_widget?(e : Events::Event) : Bool
        pid == e.pid && path == e.path
      end
    end

    getter size : Int32
    getter retention : Time::Span
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

    def count : Int32
      expire
      @events.size
    end

    # Raw events newer than `since`, oldest first.
    def since(since : Time) : Array(Events::Event)
      expire
      @events.select { |e| e.time >= since }
    end

    # Digest of events newer than `since`, newest last, at most `limit`
    # lines. Text edits on one widget fold into one line; focus-lost and
    # window-deactivate events are noise and dropped.
    def recent(since : Time, limit : Int32 = 50) : Array(Entry)
      entries = [] of Entry
      since(since).each do |e|
        case e.type
        when "window:activate"
          entries << Entry.new(e.time, "window", e.app, e.pid, e.role, e.name, e.path)
        when "object:state-changed:focused"
          next unless e.detail1 == 1
          # A focus event right after the window switch to the same app is
          # what always happens; keep it, it names the widget.
          entries << Entry.new(e.time, "focus", e.app, e.pid, e.role, e.name, e.path)
        when .starts_with?("object:text-changed")
          last = entries.last?
          if last && last.kind == "edit" && last.same_widget?(e)
            last.count += 1
            last.until = e.time
            last.text = e.text if e.type.ends_with?("insert") && e.text
          else
            text = e.type.ends_with?("insert") ? e.text : nil
            entries << Entry.new(e.time, "edit", e.app, e.pid, e.role, e.name, e.path, text)
          end
        when "document:load-complete"
          entries << Entry.new(e.time, "load", e.app, e.pid, e.role, e.name, e.path)
        end
      end
      entries.size > limit ? entries[-limit..] : entries
    end
  end
end
