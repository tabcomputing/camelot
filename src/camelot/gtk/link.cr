module Camelot
  module Gtk
    # The panel's connection to the daemon. Holds a `subscribe` stream
    # open, mirrors the daemon's events into a local `History` and keeps
    # its last `Status`; when the daemon is absent, an inotify watch on the
    # socket directory (not a timer) tells us when it appears.
    class Link
      getter history : History
      getter status : Daemon::Status?
      getter? connected : Bool = false
      @monitor : Gio::FileMonitor?

      # Called (on the main fiber) after any change: an event, a state
      # message, connection or disconnection.
      property on_change : Proc(Symbol, Nil) = ->(what : Symbol) { }
      # Called for every event the daemon pushes, in order.
      property on_event : Proc(Events::Event, Nil) = ->(e : Events::Event) { }

      def initialize(@socket_path : String = Config.socket_path)
        @history = History.new(Config.current.history, Config.current.retention)
        @status = nil
        @wake = Channel(Nil).new(1)
      end

      def start : Nil
        spawn(name: "camelot-link") { run }
        watch_socket_dir
      end

      private def run : Nil
        loop do
          STDERR.puts "camelot-gtk: link: subscribing to #{@socket_path}" if ENV["CAMELOT_DEBUG"]?
          @history = History.new(@history.size, @history.retention)
          streamed = Client.subscribe do |msg|
            case msg
            in Events::Event
              @history.record(msg)
              on_event.call(msg)
            in Daemon::Status
              @status = msg
              @history.size = msg.capacity
              @history.retention = msg.retention_seconds.seconds
              unless @connected
                @connected = true
                notify(:connected)
              end
              notify(:state)
            end
          end
          STDERR.puts "camelot-gtk: link: subscribe returned #{streamed.inspect}" if ENV["CAMELOT_DEBUG"]?
          if @connected || streamed
            @connected = false
            @status = nil
            notify(:disconnected)
          end
          # Wait for the socket to (re)appear.
          @wake.receive
        end
      end

      # inotify on the runtime dir: the socket file being created is the
      # daemon starting.
      private def watch_socket_dir : Nil
        dir = Gio::File.new_for_path(File.dirname(@socket_path))
        @monitor = mon = dir.monitor_directory(Gio::FileMonitorFlags::None, nil)
        name = File.basename(@socket_path)
        mon.changed_signal.connect do |file, _other, kind|
          if file.basename == name && (kind.created? || kind.changes_done_hint?)
            select
            when @wake.send(nil)
            else
            end
          end
        end
      rescue ex
        STDERR.puts "camelot-gtk: cannot watch #{File.dirname(@socket_path)}: #{ex.message}"
      end

      def paused? : Bool
        !@status.try(&.paused_since).nil?
      end

      # ---- commands ------------------------------------------------------------

      def pause : Nil
        Client.call("pause", JSON.parse("{}"))
      end

      def resume : Nil
        Client.call("resume", JSON.parse("{}"))
      end

      def reload : String?
        Client.call("reload", JSON.parse("{}")).try { |reply, err| err ? reply : nil }
      end

      # Start the daemon: through systemd when the user unit exists, else
      # as a detached child next to this binary.
      def start_daemon : String?
        if unit_installed?
          st = Process.run("systemctl", ["--user", "start", "camelot"], error: Process::Redirect::Close)
          return st.success? ? nil : "systemctl --user start camelot failed"
        end
        exe = File.join(File.dirname(Process.executable_path || "camelot-gtk"), "camelot")
        exe = "camelot" unless File.info?(exe).try(&.permissions.owner_execute?)
        Process.new(exe, ["daemon"], input: Process::Redirect::Close, output: Process::Redirect::Close, error: Process::Redirect::Inherit)
        nil
      rescue ex : IO::Error
        "could not start camelot daemon: #{ex.message}"
      end

      def stop_daemon : String?
        if unit_installed?
          st = Process.run("systemctl", ["--user", "stop", "camelot"], error: Process::Redirect::Close)
          return st.success? ? nil : "systemctl --user stop camelot failed"
        end
        if pid = @status.try(&.pid)
          Process.signal(Signal::TERM, pid)
        end
        nil
      rescue ex : RuntimeError
        "could not stop the daemon: #{ex.message}"
      end

      def unit_installed? : Bool
        Process.run("systemctl", ["--user", "cat", "camelot"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
      rescue IO::Error
        false
      end

      private def notify(what : Symbol) : Nil
        on_change.call(what)
      end
    end
  end
end
