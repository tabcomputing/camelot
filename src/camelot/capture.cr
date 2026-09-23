require "uri"
require "gi-crystal"
require "./config"
require "./events"

GICrystal.require("GdkPixbuf", "2.0")
GICrystal.require("Gio", "2.0")

module Camelot
  # Screen capture through the XDG desktop portal.
  #
  # Capture is always a pull: a frame is taken when something asks for one,
  # handed over and dropped. Nothing image-shaped enters the event stream
  # or the daemon's history — a stream of frames would cost more memory in
  # a minute than the whole event log does in a day.
  module Capture
    class Error < Exception; end

    # The user closed the picker: not a failure worth reporting.
    class Cancelled < Error; end

    PORTAL      = "org.freedesktop.portal.Desktop"
    PORTAL_PATH = "/org/freedesktop/portal/desktop"
    SCREENSHOT  = "org.freedesktop.portal.Screenshot"

    # Long edge of the delivered image. Beyond this an AI gains nothing:
    # the pixels are downsampled at the other end anyway, and the transfer
    # is pure cost.
    DEFAULT_MAX_EDGE = 1568
    DEFAULT_QUALITY  =   80

    record Image, bytes : Bytes, mime : String, width : Int32, height : Int32 do
      def size : Int32
        bytes.size
      end
    end

    # Is the screenshot portal running?
    def self.available? : Bool
      connection.call_sync(PORTAL, PORTAL_PATH, "org.freedesktop.DBus.Properties", "Get",
        GLib::Variant.parse(%(("#{SCREENSHOT}", "version"))), nil,
        Gio::DBusCallFlags::None, 2000, nil)
      true
    rescue
      false
    end

    # One frame. `interactive` hands the choice of window or region to the
    # user — the desktop's own picker, not ours.
    def self.shot(interactive : Bool = false, max_edge : Int32 = DEFAULT_MAX_EDGE,
                  quality : Int32 = DEFAULT_QUALITY, timeout : Time::Span = 2.minutes) : Image
      unless Config.current.screenshots
        raise Error.new("screen capture is switched off (`screenshots: false` in #{Config.path})")
      end
      path = request(interactive, timeout)
      begin
        encode(path, max_edge, quality)
      ensure
        # The portal created this file for us; it is ours to remove.
        File.delete?(path)
      end
    end

    # ---- portal ---------------------------------------------------------------

    private def self.connection : Gio::DBusConnection
      @@connection ||= Gio.bus_get_sync(Gio::BusType::Session, nil)
    end

    # Ask the portal for a screenshot and wait for its Response signal.
    # Returns the path of the PNG it wrote.
    private def self.request(interactive : Bool, timeout : Time::Span) : String
      conn = connection
      token = "camelot#{Random.rand(UInt32)}"
      sender = conn.unique_name.not_nil!.lchop(':').tr(".", "_")
      handle = "/org/freedesktop/portal/desktop/request/#{sender}/#{token}"

      answer = Channel(String | Int32).new(1)
      # Subscribed through C: the generated wrapper mishandles the nullable
      # string arguments this call needs.
      handler = ->(params : Pointer(Void)) { answer.send(response(params)); nil }
      box = Box.box(handler)
      trampoline = ->(_conn : Void*, _sender : Pointer(LibC::Char), _path : Pointer(LibC::Char), _iface : Pointer(LibC::Char), _signal : Pointer(LibC::Char), params : Void*, data : Void*) do
        Box(Proc(Pointer(Void), Nil)).unbox(data).call(params)
      end
      id = LibGio.g_dbus_connection_signal_subscribe(conn.to_unsafe, PORTAL,
        "org.freedesktop.portal.Request", "Response", handle, Pointer(LibC::Char).null,
        Gio::DBusSignalFlags::NoMatchRule.value, trampoline.pointer, box, Pointer(Void).null)

      begin
        options = %({"handle_token": <"#{token}">, "interactive": <#{interactive}>})
        conn.call_sync(PORTAL, PORTAL_PATH, SCREENSHOT, "Screenshot",
          GLib::Variant.parse(%(("", #{options}))), nil,
          Gio::DBusCallFlags::None, 10_000, nil)

        result = await(answer, timeout)
        case result
        when 1 then raise Cancelled.new("the screenshot was cancelled")
        when Int32
          raise Error.new("the desktop refused the screenshot (portal response #{result}); " \
                          "it may need permission for this application")
        end
        uri = result.as(String)
        file = path_from_uri(uri)
        raise Error.new("the portal reported a screenshot at #{uri}, which is not there") unless File.exists?(file)
        file
      ensure
        LibGio.g_dbus_connection_signal_unsubscribe(conn.to_unsafe, id)
      end
    end

    # The local path a file:// URI names. Interactive screenshots are saved
    # as "Screenshot From 2026-09-23 01-48-24.png", so the URI is
    # percent-encoded and must be decoded, not just stripped of its scheme.
    def self.path_from_uri(uri : String) : String
      URI.decode(URI.parse(uri).path)
    end

    # The Response signal is (u code, a{sv} results): the URI on success,
    # else the code — 1 means the user cancelled, 2 anything else.
    private def self.response(params : Pointer(Void)) : String | Int32
      code = LibGLib.g_variant_get_uint32(LibGLib.g_variant_get_child_value(params, 0))
      return code.to_i32 unless code.zero?
      results = LibGLib.g_variant_get_child_value(params, 1)
      value = LibGLib.g_variant_lookup_value(results, "uri", Pointer(Void).null)
      return 2 if value.null?
      ptr = LibGLib.g_variant_get_string(value, Pointer(UInt64).null)
      ptr.null? ? 2 : String.new(ptr)
    end

    # Wait for the portal, driving the GLib loop ourselves unless something
    # else in this process (the daemon, the panel) already is.
    private def self.await(answer : Channel(String | Int32), timeout : Time::Span) : String | Int32
      if Events::Pump.running?
        select
        when r = answer.receive then r
        when timeout(timeout) then raise Error.new("the desktop did not answer within #{timeout.total_seconds.to_i}s")
        end
      else
        stop = Channel(Nil).new(1)
        result = 2.as(String | Int32) # no answer in time counts as a failure
        spawn(name: "camelot-shot") do
          select
          when r = answer.receive then result = r
          when timeout(timeout) then nil
          end
          stop.send(nil)
        end
        Events::Pump.new.run(deadline: Time.instant + timeout, stop: stop)
        result
      end
    end

    # ---- encoding -------------------------------------------------------------

    # Load the PNG the portal wrote, scale it to fit `max_edge`, and encode
    # it as JPEG — a 2560x1440 screenshot is ~1.7 MB of PNG and ~150 KB of
    # JPEG that reads exactly as well.
    private def self.encode(path : String, max_edge : Int32, quality : Int32) : Image
      source = GdkPixbuf::Pixbuf.new_from_file(path)
      raise Error.new("could not read the screenshot at #{path}") unless source
      width, height = source.width, source.height
      if max_edge > 0 && (width > max_edge || height > max_edge)
        scale = max_edge / {width, height}.max.to_f
        width = (width * scale).round.to_i
        height = (height * scale).round.to_i
      end

      # Screens carry an alpha channel and JPEG has none, so the frame is
      # always composited onto an opaque canvas — which scales it too.
      pixbuf = GdkPixbuf::Pixbuf.new(GdkPixbuf::Colorspace::Rgb, false, 8, width, height)
      raise Error.new("could not allocate #{width}x#{height} for the screenshot") unless pixbuf
      pixbuf.fill(0xffffffff_u32)
      source.composite(pixbuf, 0, 0, width, height, 0.0, 0.0,
        width / source.width.to_f, height / source.height.to_f,
        GdkPixbuf::InterpType::Bilinear, 255)

      Image.new(to_jpeg(pixbuf, quality), "image/jpeg", width, height)
    end

    # `save_to_bufferv`'s generated wrapper takes the buffer as an argument
    # rather than returning it, so the C function is called directly.
    private def self.to_jpeg(pixbuf : GdkPixbuf::Pixbuf, quality : Int32) : Bytes
      keys = ["quality".to_unsafe, Pointer(LibC::Char).null]
      values = [quality.to_s.to_unsafe, Pointer(LibC::Char).null]
      buffer = Pointer(UInt8).null
      size = 0_u64
      error = Pointer(LibGLib::Error).null
      ok = LibGdkPixbuf.gdk_pixbuf_save_to_bufferv(pixbuf.to_unsafe, pointerof(buffer), pointerof(size),
        "jpeg", keys.to_unsafe, values.to_unsafe, pointerof(error))
      unless error.null?
        message = String.new(error.value.message)
        LibGLib.g_error_free(error)
        raise Error.new("could not encode the screenshot: #{message}")
      end
      raise Error.new("could not encode the screenshot") if ok.zero? || buffer.null?
      bytes = Bytes.new(size.to_i32)
      bytes.copy_from(buffer, size.to_i32)
      LibGLib.g_free(buffer.as(Void*))
      bytes
    end
  end
end
