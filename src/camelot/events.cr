require "./a11y"

module Camelot
  # AT-SPI event stream. libatspi delivers events through the GLib main
  # context, so `pump` runs that context from a Crystal fiber: no second
  # thread, every callback fires on the main thread between Crystal's own
  # fibers, and normal Crystal IO/sleep/channels keep working alongside.
  module Events
    # Event types worth watching by default: what the user switched to,
    # what got focus, what they typed.
    DEFAULT_TYPES = %w[
      window:activate
      window:deactivate
      object:state-changed:focused
      object:text-changed
      object:text-caret-moved
      document:load-complete
    ]

    # A delivered event, detached from libatspi's memory.
    class Event
      include JSON::Serializable
      include YAML::Serializable

      property time : Time
      property type : String
      property app : String?
      property pid : UInt32?
      property role : String?
      property name : String?
      property path : String?
      property detail1 : Int32
      property detail2 : Int32
      # Inserted/deleted text for text-changed events.
      property text : String?

      def initialize(@time, @type, @app, @pid, @role, @name, @path, @detail1, @detail2, @text)
      end
    end

    # Bridges libatspi's C callback to a Crystal block. The generated
    # `Atspi::EventListener.new` is not used: it constructs the event with
    # transfer FULL and frees a struct libatspi still owns (a double free
    # on every event), so the callback is set up by hand here.
    class Listener
      @listener : Pointer(Void)
      @box : Pointer(Void)
      @types = [] of String

      def initialize(&handler : Atspi::Event ->)
        A11y.init
        @box = Box.box(handler)
        # An exception must never unwind through libatspi's C frames (it
        # leaves its dispatch state wedged), so the handler is fenced here.
        callback = ->(event : Pointer(LibAtspi::Event), data : Pointer(Void)) {
          begin
            Box(Proc(Atspi::Event, Nil)).unbox(data).call(Atspi::Event.new(event.as(Void*), GICrystal::Transfer::None))
          rescue ex
            STDERR.puts "camelot: event handler failed: #{ex.inspect_with_backtrace}"
          end
        }
        @listener = LibAtspi.atspi_event_listener_new(callback.pointer, @box, Pointer(Void).null)
      end

      def register(type : String) : Nil
        error = Pointer(LibGLib::Error).null
        LibAtspi.atspi_event_listener_register(@listener, type, pointerof(error))
        Atspi.raise_gerror(error) unless error.null?
        @types << type
      end

      def deregister_all : Nil
        @types.each do |type|
          error = Pointer(LibGLib::Error).null
          LibAtspi.atspi_event_listener_deregister(@listener, type, pointerof(error))
          LibGLib.g_error_free(error) unless error.null?
        end
        @types.clear
      end
    end

    # Runs a GLib main context inside Crystal's event loop. GLib is asked
    # what it would poll (`prepare` + `query`: fds and a timeout), Crystal
    # waits for that — one fiber per fd parked in `wait_readable`, plus a
    # timer — and then GLib runs its own non-blocking iteration to check and
    # dispatch. An idle pump costs nothing; an event wakes it immediately.
    # libatspi's context starts with two fds (the a11y bus socket and GLib's
    # wakeup eventfd) and adds one per application it talks to.
    # Runs a GLib main context inside Crystal's event loop: ask GLib what
    # it would poll (`prepare`/`query`), wait for exactly that in Crystal,
    # then let GLib dispatch. No polling, no second thread — but the loop
    # must never run without letting other fibers (and Crystal's own event
    # loop) have a turn, or everything else in the process starves.
    class Pump
      MAX_FDS = 64
      # Most sources dispatched in one pass before breathing. libatspi arms
      # a source while draining its own queue, so "dispatch until nothing
      # is ready" can be an infinite loop.
      MAX_DISPATCH = 64
      # A real (if tiny) sleep, not `Fiber.yield`: while this fiber stays
      # runnable Crystal has no reason to run its event loop, so fibers
      # waiting on timers or IO would never wake.
      BREATH = 1.millisecond
      # If GLib keeps claiming a source is ready but dispatching it does
      # no work, stop asking so often.
      IDLE_BACKOFF   = 20.milliseconds
      IDLE_TOLERANCE = 3

      # Reports one fd's readability to the pump, once per wait. Stops
      # when GLib stops polling that fd: a watcher left on a dead
      # connection would report EOF forever.
      class Watcher
        getter fd : Int32

        def initialize(@fd : Int32, @ready : Channel(Int32))
          @io = IO::FileDescriptor.new(handle: @fd, close_on_finalize: false)
          @live = true
          spawn(name: "glib-fd-#{@fd}") { watch }
        end

        def stop : Nil
          @live = false
        end

        private def watch : Nil
          while @live
            begin
              Crystal::EventLoop.current.wait_readable(@io)
            rescue IO::Error
              break # fd closed under us
            end
            break unless @live
            @ready.send(@fd)
          end
        end
      end

      # Is a pump already driving the default context in this process?
      class_property? running : Bool = false

      @context : Pointer(Void)
      @ready = Channel(Int32).new
      @watchers = {} of Int32 => Watcher

      def initialize(context : GLib::MainContext = GLib::MainContext.default)
        @context = context.to_unsafe
      end

      # Run until `stop` yields, or `deadline` passes.
      def run(deadline : Time::Instant? = nil, stop : Channel(Nil) = Channel(Nil).new) : Nil
        raise Error.new("GLib main context is owned by another thread") if LibGLib.g_main_context_acquire(@context).zero?
        Pump.running = true
        fds = Slice(LibGLib::PollFD).new(MAX_FDS, LibGLib::PollFD.new)
        idle = 0
        loop do
          break if deadline && Time.instant >= deadline
          break if stopped?(stop)

          # Dispatch what is ready, but never unboundedly.
          dispatched = 0
          while dispatched < MAX_DISPATCH && LibGLib.g_main_context_iteration(@context, 0) != 0
            dispatched += 1
          end
          if dispatched >= MAX_DISPATCH
            sleep BREATH # GLib still has work; come back after a breath
            next
          end
          idle = dispatched > 0 ? 0 : idle + 1

          # Ask GLib what it would poll, and wait for that in Crystal.
          priority = 0
          LibGLib.g_main_context_prepare(@context, pointerof(priority))
          timeout_ms = -1
          count = LibGLib.g_main_context_query(@context, priority, pointerof(timeout_ms),
            fds.to_unsafe.as(Pointer(Pointer(LibGLib::PollFD))), fds.size)
          raise Error.new("GLib wants #{count} fds, more than #{MAX_FDS}") if count > fds.size
          rewatch(fds[0, count])

          if timeout_ms == 0
            # A source says it is ready now, yet dispatching it did
            # nothing: breathe rather than spin.
            sleep(idle > IDLE_TOLERANCE ? IDLE_BACKOFF : BREATH)
            next
          end

          wait = timeout_ms < 0 ? nil : timeout_ms.milliseconds
          if deadline
            left = deadline - Time.instant
            wait = left if wait.nil? || left < wait
          end
          wait = IDLE_BACKOFF if wait.nil? && idle > IDLE_TOLERANCE
          break if await(wait, stop) == :stop
        end
      ensure
        Pump.running = false
        @watchers.each_value(&.stop)
        @watchers.clear
        LibGLib.g_main_context_release(@context)
      end

      # Watch exactly the fds GLib polls now: add the new, stop watchers
      # for fds it has given up (a closed peer connection's fd stays
      # readable at EOF, and its watcher would wake us forever).
      private def rewatch(polled : Slice(LibGLib::PollFD)) : Nil
        wanted = Set(Int32).new
        polled.each do |pfd|
          wanted << pfd.fd
          @watchers[pfd.fd] ||= Watcher.new(pfd.fd, @ready)
        end
        @watchers.reject! do |fd, watcher|
          next false if wanted.includes?(fd)
          watcher.stop
          true
        end
      end

      private def stopped?(stop : Channel(Nil)) : Bool
        select
        when stop.receive? then true
        else
          false
        end
      end

      private def await(wait : Time::Span?, stop : Channel(Nil)) : Symbol
        if wait
          select
          when @ready.receive then :fd
          when stop.receive? then :stop
          when timeout(wait) then :timeout
          end
        else
          select
          when @ready.receive then :fd
          when stop.receive? then :stop
          end
        end
      end
    end

    class Error < Exception; end

    # Convenience: run the default context on the current fiber.
    def self.pump(deadline : Time::Instant? = nil, stop : Channel(Nil) = Channel(Nil).new) : Nil
      Pump.new.run(deadline, stop)
    end

    # The event's `any_data` GValue as a string, if it holds one. (The
    # generated `Atspi::Event#any_data` accessor does not compile, so the
    # GValue is read in place.)
    private def self.string_payload(ev : Atspi::Event) : String?
      raw = ev.to_unsafe.as(Pointer(LibAtspi::Event))
      value = pointerof(raw.value.@any_data).as(Void*)
      return nil unless raw.value.any_data.g_type == GObject::TYPE_STRING
      ptr = LibGObject.g_value_get_string(value)
      ptr.null? ? nil : String.new(ptr)
    end

    # What a callback may take from a libatspi event without talking to the
    # bus: libatspi delivers events while it waits on a synchronous call, so
    # a handler that makes calls of its own nests D-Bus round trips inside a
    # dispatch inside a round trip. Names are resolved later, from a fiber,
    # by `Pending#resolve`. The source is ref'd and stays valid.
    record Pending, time : Time, type : String, source : Atspi::Accessible?, detail1 : Int32, detail2 : Int32, text : String? do
      def resolve : Event
        src = source
        payload = text
        # Never the keystrokes going into a password field.
        payload = nil if payload && src && A11y.secret?(src)
        where = src ? Resolver.locate(src) : Resolver::Location.new(nil, nil, nil)
        Event.new(
          time, type, where.app, where.pid,
          src.try { |s| A11y.safe(nil) { s.role_name } },
          src.try { |s| A11y.safe(nil) { s.name } }.try { |n| n.empty? ? nil : n },
          where.path, detail1, detail2, payload)
      end
    end

    # Where a widget lives — app, pid, index path — remembered per source
    # object. Role and name are served from libatspi's own cache (kept
    # fresh by property-change events), but the index path is a walk up
    # the tree with a round trip per level, and a flood of events comes
    # from a handful of widgets. libatspi hands out one object per remote
    # widget, so its address identifies it while it is alive; the object
    # is kept in the entry so the address cannot be reused meanwhile.
    module Resolver
      record Location, app : String?, pid : UInt32?, path : String?

      CAPACITY = 512
      @@cache = {} of UInt64 => {Atspi::Accessible, Location}

      def self.locate(src : Atspi::Accessible) : Location
        key = src.to_unsafe.address
        if hit = @@cache[key]?
          return hit[1]
        end
        app = A11y.application?(src)
        loc = Location.new(
          app.try { |a| A11y.safe(nil) { a.name } },
          A11y.safe(nil) { src.process_id },
          A11y.safe(nil) { A11y.index_path(src) })
        @@cache.shift if @@cache.size >= CAPACITY
        @@cache[key] = {src, loc}
        loc
      end

      def self.clear : Nil
        @@cache.clear
      end
    end

    # Take the cheap parts of a libatspi event while it is still valid.
    def self.pending(ev : Atspi::Event) : Pending
      type = ev.type || "?"
      text = type.starts_with?("object:text-changed") ? string_payload(ev) : nil
      Pending.new(Time.local, type, ev.source, ev.detail1, ev.detail2, text)
    end

    # A listener whose handler runs in a fiber, off the dispatch path, with
    # the event already resolved. Bursts are queued (bounded); a flood the
    # handler cannot keep up with is dropped rather than stalling libatspi.
    class Queue
      getter dropped : Int64 = 0

      # `gate` is asked before an event is resolved: while it answers
      # false nothing is looked up, which is what "paused" should cost.
      property gate : Proc(Bool) = -> { true }

      def initialize(types : Array(String) = DEFAULT_TYPES, capacity : Int32 = 4096, &handler : Event ->)
        @channel = Channel(Pending).new(capacity)
        @listener = Listener.new do |ev|
          p = Events.pending(ev)
          select
          when @channel.send(p)
          else
            @dropped += 1
          end
        end
        types.each { |t| @listener.register(t) }
        spawn(name: "camelot-events") do
          while p = @channel.receive?
            next unless gate.call
            handler.call(p.resolve)
          end
        end
      end

      def close : Nil
        @listener.deregister_all
        @channel.close
      end
    end
  end
end
