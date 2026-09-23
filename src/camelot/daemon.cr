require "socket"
require "./config"
require "./events"
require "./history"
require "./commands"

module Camelot
  # Long-lived process that keeps the accessibility bus connection warm,
  # records events into `History` (and optionally a durable log), and
  # answers commands over a Unix socket with the same runner the CLI and
  # MCP use.
  class Daemon
    getter history : History
    getter started : Time
    getter config : Config
    getter paused_since : Time?

    def initialize(@cli : Jargon::CLI, @socket_path : String = Config.socket_path,
                   history_size : Int32? = nil, @log : IO = STDERR, @config : Config = Config.current)
      @history = History.new(history_size || @config.history, @config.retention)
      @started = Time.local
      @stop = Channel(Nil).new(1) # buffered: the signal handler must not block
      @sink = nil.as(Sink?)
      @subscribers = [] of Subscriber
      @queue = nil.as(Events::Queue?)
    end

    def run : Nil
      A11y.init
      server = listen
      apply_config(first: true)

      queue = @queue = Events::Queue.new { |event| record(event) }
      queue.gate = -> { !paused? } # paused costs nothing, not even a lookup

      Process.on_terminate do
        select
        when @stop.send(nil)
        else
        end
      end
      spawn(name: "camelot-accept") { accept_loop(server) }
      Events.pump(stop: @stop)
    ensure
      queue.try &.close
      @subscribers.dup.each(&.close)
      server.try &.close
      @sink.try &.close
      File.delete?(@socket_path)
      @log.puts "camelot daemon: stopped"
    end

    def paused? : Bool
      !@paused_since.nil?
    end

    # ---- recording -----------------------------------------------------------

    private def record(event : Events::Event) : Nil
      return if paused?
      return if @config.ignored?(event.app)
      event.text = nil unless @config.text
      @history.record(event)
      @sink.try &.write(event)
      broadcast({"event" => event}.to_json)
    end

    # A client of `subscribe`: a long-lived connection that receives every
    # recorded event and every state change as JSON lines, written by its
    # own fiber through a bounded queue so a stalled client cannot stall
    # the daemon — it is dropped instead.
    class Subscriber
      getter socket : UNIXSocket

      def initialize(@socket, @on_close : Subscriber ->)
        @queue = Channel(String).new(4096)
        spawn(name: "camelot-subscriber") do
          begin
            while line = @queue.receive?
              @socket.puts line
              @socket.flush
            end
          rescue IO::Error
          ensure
            @socket.close rescue nil
            @on_close.call(self)
          end
        end
      end

      # Queue a line; false if the client is too far behind.
      def push(line : String) : Bool
        select
        when @queue.send(line) then true
        else
          false
        end
      end

      def close : Nil
        @queue.close
      end
    end

    private def broadcast(line : String) : Nil
      @subscribers.dup.each do |sub|
        unless sub.push(line)
          @log.puts "camelot daemon: dropping a subscriber that stopped reading"
          @subscribers.delete(sub)
          sub.close
        end
      end
    end

    private def broadcast_state : Nil
      broadcast({"state" => status_info}.to_json) unless @subscribers.empty?
    end

    # Hand a connection over to the subscriber list: backfill, then stream
    # until the client hangs up.
    private def subscribe(client : UNIXSocket, args : JSON::Any) : Nil
      seconds = args["seconds"]?.try(&.as_i64?) || @history.retention.total_seconds.to_i64
      sub = Subscriber.new(client, ->(gone : Subscriber) { @subscribers.delete(gone); nil })
      @subscribers << sub
      @history.since(Time.local - seconds.seconds).each { |e| sub.push({"event" => e}.to_json) }
      sub.push({"state" => status_info}.to_json)
      # Reading detects the hang-up (clients send nothing more).
      client.read_timeout = nil
      client.gets
    rescue IO::Error
    ensure
      sub.try &.close
    end

    # Durable log: one JSON line per event, one file per day.
    class Sink
      getter dir : String
      getter since : Time

      def initialize(@dir : String)
        Dir.mkdir_p(@dir)
        File.chmod(@dir, 0o700)
        @since = Time.local
        @day = ""
        @file = nil.as(File?)
      end

      def write(event : Events::Event) : Nil
        day = event.time.to_s("%Y-%m-%d")
        if day != @day
          @file.try &.close
          @file = File.open(File.join(@dir, "events-#{day}.jsonl"), "a", perm: 0o600)
          @day = day
        end
        if f = @file
          f.puts event.to_json
          f.flush
        end
      end

      def close : Nil
        @file.try &.close
        @file = nil
      end
    end

    # ---- configuration -------------------------------------------------------

    # (Re)apply the current config: history bounds, the durable log, and
    # the accessibility switch.
    private def apply_config(first = false) : Nil
      @history.size = @config.history
      @history.retention = @config.retention
      @history.expire

      dir = @config.log_dir
      if dir != @sink.try(&.dir)
        @sink.try &.close
        @sink = dir ? Sink.new(dir) : nil
      end

      enable_accessibility if @config.accessibility

      @log.puts "camelot daemon: #{first ? "listening on #{@socket_path}, " : "reloaded: "}" \
                "keeping #{@history.size} events for #{@history.retention.total_minutes.to_i}m" \
                "#{@config.text ? "" : ", typed text not recorded"}" \
                "#{dir ? ", logging to #{dir}" : ""}" \
                "#{@config.ignore.empty? ? "" : ", ignoring #{@config.ignore.join(", ")}"}"
    end

    # Browsers and some toolkits only build their accessibility tree when
    # toolkit accessibility was on at their startup. Turn it on (and say
    # so); never turn it off, a screen reader may depend on it.
    private def enable_accessibility : Nil
      return unless gsettings = Process.find_executable("gsettings")
      key = {"org.gnome.desktop.interface", "toolkit-accessibility"}
      current = IO::Memory.new
      status = Process.run(gsettings, ["get", *key], output: current, error: Process::Redirect::Close)
      return unless status.success? # no such schema: not a GNOME-style desktop
      return if current.to_s.strip == "true"
      if Process.run(gsettings, ["set", *key, "true"], error: Process::Redirect::Close).success?
        @log.puts "camelot daemon: turned on #{key[0]} #{key[1]} so browsers expose page content " \
                  "(applies to apps started from now on; set `accessibility: false` in config to leave it alone)"
      end
    end

    # ---- socket --------------------------------------------------------------

    private def listen : UNIXServer
      if File.exists?(@socket_path)
        # Stale socket from an unclean exit, or a live daemon?
        if Client.running?(@socket_path)
          raise A11y::Error.new("another camelot daemon is already listening on #{@socket_path}")
        end
        File.delete(@socket_path)
      end
      server = UNIXServer.new(@socket_path)
      File.chmod(@socket_path, 0o600)
      server
    end

    private def accept_loop(server : UNIXServer) : Nil
      while client = server.accept?
        spawn(name: "camelot-client") { serve(client) }
      end
    end

    private def serve(client : UNIXSocket) : Nil
      client.read_timeout = 10.seconds
      if line = client.gets
        request = JSON.parse(line) rescue nil
        if request && request["command"]? == "subscribe"
          subscribe(client, request["arguments"]? || JSON.parse("{}"))
          return
        end
        client.puts respond(line).to_json
      end
    rescue IO::Error
      # client went away
    rescue ex
      # One malformed desktop must not take the service down with it: an
      # exception escaping a fiber ends the process.
      @log.puts "camelot daemon: #{ex.inspect_with_backtrace}"
      client.puts({"ok" => false, "error" => "camelot: #{ex.message}"}.to_json) rescue nil
    ensure
      client.close rescue nil
    end

    def respond(line : String) : Hash(String, String | Bool)
      request = JSON.parse(line)
      command = request["command"]?.try(&.as_s?) || return {"ok" => false, "error" => "missing command"}
      args = request["arguments"]? || JSON.parse("{}")
      output, is_error = case command
                         when "recent" then recent(args)
                         when "status" then status(args)
                         when "pause"  then pause
                         when "resume" then resume
                         when "reload" then reload
                         else               Commands.run(@cli, command, args, local: true)
                         end
      is_error ? {"ok" => false, "error" => output} : {"ok" => true, "output" => output}
    rescue ex : JSON::ParseException
      {"ok" => false, "error" => "bad request: #{ex.message}"}
    end

    # ---- daemon-only commands ------------------------------------------------

    private def recent(args : JSON::Any) : {String, Bool}
      result = @cli.parse(["recent", "-"], IO::Memory.new(args.to_json))
      return {result.errors.join("\n"), true} unless result.valid?
      seconds = result["seconds"]?.try(&.as_i64?) || 60
      limit = (result["limit"]?.try(&.as_i64?) || 50).to_i32
      since = Time.local - seconds.seconds
      format = result["format"]?.try(&.as_s?) || "text"
      buffer = IO::Memory.new
      if (p = @paused_since) && format == "text"
        buffer.puts "(recording paused since #{p.to_s("%H:%M:%S")})"
      end
      if result["raw"]?.try(&.as_bool?)
        events = @history.since(since)
        events = events[-limit..] if events.size > limit
        format == "text" ? events.each { |e| buffer.puts Format.line(e) } : Format.emit(buffer, events, format)
      else
        entries = @history.recent(since, limit)
        format == "text" ? Format.text(buffer, entries) : Format.emit(buffer, entries, format)
      end
      {buffer.to_s, false}
    end

    private def status(args : JSON::Any) : {String, Bool}
      format = args["format"]?.try(&.as_s?) || "text"
      buffer = IO::Memory.new
      Format.emit(buffer, status_info, format)
      {buffer.to_s, false}
    end

    def status_info : Status
      Status.new(Process.pid, @started, (Time.local - @started).total_seconds.round(1),
        @history.count, @history.total, @history.size, @history.retention.total_seconds.to_i64,
        @config.text, @paused_since, @sink.try(&.dir), @sink.try(&.since), @config.ignore, @socket_path)
    end

    private def pause : {String, Bool}
      if p = @paused_since
        return {"already paused since #{p.to_s("%H:%M:%S")}\n", false}
      end
      @paused_since = Time.local
      @queue.try &.unsubscribe
      @log.puts "camelot daemon: recording paused"
      broadcast_state
      {"recording paused\n", false}
    end

    private def resume : {String, Bool}
      return {"not paused\n", false} unless paused?
      @paused_since = nil
      @queue.try &.subscribe
      @log.puts "camelot daemon: recording resumed"
      broadcast_state
      {"recording resumed\n", false}
    end

    private def reload : {String, Bool}
      @config = Config.load
      Config.current = @config # keeps A11y.snapshot's ignore check in step
      apply_config
      broadcast_state
      {"reloaded #{Config.path}\n", false}
    rescue ex : Config::Error
      {ex.message.to_s, true}
    end

    record Status, pid : Int64, started : Time, uptime_seconds : Float64,
      events : Int32, total_events : Int64, capacity : Int32, retention_seconds : Int64,
      text : Bool, paused_since : Time?, log_dir : String?, log_since : Time?,
      ignore : Array(String), socket : String do
      include JSON::Serializable
      include YAML::Serializable
    end
  end
end
