require "json"
require "yaml"
require "gi-crystal"
require "./a11y"

GICrystal.require("Gio", "2.0")

module Camelot
  # The compositor's side of the story. On Wayland an application cannot
  # learn where its windows sit on screen, so AT-SPI's "screen" coordinates
  # are really window coordinates. The camelot GNOME Shell extension
  # (contrib/gnome-extension) runs inside the compositor and tells us where
  # windows are and where the pointer is; with that, a screen point becomes
  # a window point, and the application can answer in its own terms.
  module Shell
    class Error < Exception; end

    DEST  = "org.gnome.Shell"
    PATH  = "/com/tabcomputing/Camelot"
    IFACE = "com.tabcomputing.Camelot.Shell"

    record Rect, x : Int32, y : Int32, width : Int32, height : Int32 do
      include JSON::Serializable
      include YAML::Serializable
    end

    record Point, x : Int32, y : Int32 do
      include JSON::Serializable
      include YAML::Serializable
    end

    # A window as the compositor sees it.
    class Window
      include JSON::Serializable
      getter id : Int64
      getter pid : UInt32
      getter title : String?
      getter wm_class : String?
      getter client : String
      getter focused : Bool
      getter frame : Rect
      getter buffer : Rect
      getter stack : Int32
    end

    # What `WindowAt`/`Probe` add: the point in the window's frame and
    # buffer coordinates.
    class Hit
      include JSON::Serializable
      include YAML::Serializable
      getter id : Int64
      getter pid : UInt32
      getter title : String?
      getter client : String
      getter frame : Rect
      getter point : Hash(String, Point)

      def frame_point : Point
        point["frame"]
      end
    end

    class Probe
      include JSON::Serializable
      getter pointer : Point
      getter window : Hit?
    end

    # Is the extension there to ask?
    def self.available? : Bool
      call("GetPointer")
      true
    rescue Error
      false
    end

    def self.pointer : Point
      Probe.from_json(string_call("Probe")).pointer
    end

    def self.probe : Probe
      Probe.from_json(string_call("Probe"))
    end

    def self.windows : Array(Window)
      Array(Window).from_json(string_call("GetWindows"))
    end

    def self.window_at(x : Int32, y : Int32) : Hit?
      json = string_call("WindowAt", GLib::Variant.parse("(#{x}, #{y})"))
      json == "null" ? nil : Hit.from_json(json)
    end

    # ---- resolving a screen point to a widget ---------------------------------

    record Resolution, point : Point, window : Hit?, accessible_window : Atspi::Accessible?,
      widget : Atspi::Accessible?

    # The widget at screen point (x, y): the compositor names the window and
    # the point within it, the application names the widget.
    def self.resolve(x : Int32, y : Int32) : Resolution
      hit = window_at(x, y)
      resolution(Point.new(x, y), hit)
    end

    # The widget under the pointer, right now.
    def self.resolve_pointer : Resolution
      p = probe
      resolution(p.pointer, p.window)
    end

    private def self.resolution(point : Point, hit : Hit?) : Resolution
      return Resolution.new(point, nil, nil, nil) unless hit
      window = accessible_window(hit)
      widget = window.try { |w| A11y.at_point(w, hit.frame_point.x, hit.frame_point.y) || w }
      Resolution.new(point, hit, window, widget)
    end

    # The AT-SPI window for a compositor window: same process, then the same
    # title, else the same size, else the only one there is.
    def self.accessible_window(hit : Hit) : Atspi::Accessible?
      app = A11y.applications.find { |a| A11y.safe(0_u32) { a.process_id } == hit.pid }
      return nil unless app
      windows = A11y.windows(app)
      windows.find { |w| A11y.safe("") { w.name } == hit.title } ||
        windows.find { |w| same_size?(w, hit.frame) } ||
        (windows.size == 1 ? windows.first : nil)
    end

    private def self.same_size?(w : Atspi::Accessible, frame : Rect) : Bool
      e = A11y.extents_of(w)
      !e.nil? && e.width == frame.width && e.height == frame.height
    end

    # ---- D-Bus ----------------------------------------------------------------

    private def self.connection : Gio::DBusConnection
      @@connection ||= Gio.bus_get_sync(Gio::BusType::Session, nil)
    end

    private def self.call(method : String, args : GLib::Variant? = nil) : GLib::Variant
      connection.call_sync(DEST, PATH, IFACE, method, args, nil, Gio::DBusCallFlags::None, 2000, nil)
    rescue ex : GLib::Error
      message = ex.message.to_s
      if message.includes?("UnknownObject") || message.includes?("UnknownMethod") ||
         message.includes?("No such interface") || message.includes?("No such object")
        raise Error.new("the camelot GNOME Shell extension is not running " \
                        "(install contrib/gnome-extension, then log out and back in)")
      end
      raise Error.new("the camelot GNOME Shell extension said: #{message}")
    end

    # Methods answering a single string.
    private def self.string_call(method : String, args : GLib::Variant? = nil) : String
      reply = call(method, args)
      child = LibGLib.g_variant_get_child_value(reply.to_unsafe, 0)
      ptr = LibGLib.g_variant_get_string(child, Pointer(UInt64).null)
      ptr.null? ? "null" : String.new(ptr)
    end
  end
end
