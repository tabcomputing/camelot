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
        callback = ->(event : Pointer(LibAtspi::Event), data : Pointer(Void)) {
          Box(Proc(Atspi::Event, Nil)).unbox(data).call(Atspi::Event.new(event.as(Void*), GICrystal::Transfer::None))
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

    # Drive the GLib main context from the current fiber until the block
    # returns false. Callbacks registered with libatspi run inside
    # `iteration`; between bursts the fiber sleeps so other fibers run.
    def self.pump(interval : Time::Span = 10.milliseconds, &keep_going : -> Bool) : Nil
      context = GLib::MainContext.default
      while keep_going.call
        while context.iteration(false)
        end
        sleep interval
      end
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

    # Snapshot the parts of a libatspi event we want, while it is still valid.
    def self.capture(ev : Atspi::Event) : Event
      source = ev.source
      app = source.try { |s| A11y.safe(nil) { s.application } }
      text = nil
      if ev.type.try(&.starts_with?("object:text-changed"))
        # Never the keystrokes going into a password field.
        text = string_payload(ev) unless source && A11y.secret?(source)
      end
      Event.new(
        Time.local,
        ev.type || "?",
        app.try { |a| A11y.safe(nil) { a.name } },
        source.try { |s| A11y.safe(nil) { s.process_id } },
        source.try { |s| A11y.safe(nil) { s.role_name } },
        source.try { |s| A11y.safe(nil) { s.name } }.try { |n| n.empty? ? nil : n },
        source.try { |s| A11y.safe(nil) { A11y.index_path(s) } },
        ev.detail1, ev.detail2, text)
    end
  end
end
