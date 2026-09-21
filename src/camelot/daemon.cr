require "socket"
require "./config"
require "./events"
require "./history"
require "./commands"

module Camelot
  # Long-lived process that keeps the accessibility bus connection warm,
  # records events into `History`, and answers commands over a Unix socket
  # with the same runner the CLI and MCP use.
  class Daemon
    getter history : History
    getter started : Time

    def initialize(@cli : Jargon::CLI, @socket_path : String = Config.socket_path,
                   history_size : Int32 = Config.current.history, @log : IO = STDERR,
                   @config : Config = Config.current)
      @history = History.new(history_size, @config.retention)
      @started = Time.local
      @stop = Channel(Nil).new
    end

    def run : Nil
      A11y.init
      server = listen
      @log.puts "camelot daemon: listening on #{@socket_path}, keeping #{@history.size} events for #{@history.retention.total_minutes.to_i}m" \
                "#{@config.text ? "" : ", typed text not recorded"}"
      enable_accessibility if @config.accessibility

      listener = Events::Listener.new do |ev|
        event = Events.capture(ev)
        next if @config.ignored?(event.app)
        event.text = nil unless @config.text
        @history.record(event)
      end
      Events::DEFAULT_TYPES.each { |t| listener.register(t) }

      Process.on_terminate { @stop.send(nil) }
      spawn(name: "camelot-accept") { accept_loop(server) }
      Events.pump(stop: @stop)
    ensure
      listener.try &.deregister_all
      server.try &.close
      File.delete?(@socket_path)
      @log.puts "camelot daemon: stopped"
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
        client.puts respond(line).to_json
      end
    rescue IO::Error
      # client went away
    ensure
      client.close
    end

    def respond(line : String) : Hash(String, String | Bool)
      request = JSON.parse(line)
      command = request["command"]?.try(&.as_s?) || return {"ok" => false, "error" => "missing command"}
      args = request["arguments"]? || JSON.parse("{}")
      output, is_error = case command
                         when "recent" then recent(args)
                         when "status" then status(args)
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
      info = Status.new(Process.pid, @started, (Time.local - @started).total_seconds.round(1), @history.count, @history.total, @history.size, @socket_path)
      buffer = IO::Memory.new
      Format.emit(buffer, info, format)
      {buffer.to_s, false}
    end

    record Status, pid : Int64, started : Time, uptime_seconds : Float64, events : Int32, total_events : Int64, capacity : Int32, socket : String do
      include JSON::Serializable
      include YAML::Serializable
    end
  end
end
