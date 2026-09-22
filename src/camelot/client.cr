require "json"
require "socket"
require "./config"
require "./events"

module Camelot
  # Client side of the daemon socket: one JSON line out, one back.
  #
  #   {"command": "context", "arguments": {"format": "json"}}
  #   {"ok": true, "output": "..."}   or   {"ok": false, "error": "..."}
  module Client
    # Set to skip the daemon even when it is running (CAMELOT_LOCAL=1).
    def self.disabled? : Bool
      !ENV["CAMELOT_LOCAL"]?.nil?
    end

    # Ask the daemon; nil when there is no daemon to ask.
    def self.call(command : String, args : JSON::Any, path : String = Config.socket_path) : {String, Bool}?
      return nil if disabled?
      sock = connect(path)
      return nil unless sock
      begin
        sock.puts({"command" => command, "arguments" => args}.to_json)
        line = sock.gets
        return {"daemon closed the connection", true} unless line
        reply = JSON.parse(line)
        if reply["ok"]?.try(&.as_bool?)
          {reply["output"].as_s, false}
        else
          {reply["error"]?.try(&.as_s?) || "daemon error", true}
        end
      ensure
        sock.close
      end
    rescue IO::Error
      {"lost the daemon mid-request", true}
    end

    # A message from a subscription: an event, or the daemon's state.
    alias Message = Events::Event | Daemon::Status

    # Hold a connection open and yield every message the daemon pushes:
    # first a backfill of retained events and the current state, then each
    # recorded event and each state change as it happens. Returns when the
    # daemon goes away; nil right away if there is no daemon.
    def self.subscribe(seconds : Int64? = nil, path : String = Config.socket_path, &block : Message ->) : Bool?
      return nil if disabled?
      sock = connect(path)
      return nil unless sock
      sock.read_timeout = nil
      args = seconds ? {"seconds" => seconds} : {} of String => Int64
      sock.puts({"command" => "subscribe", "arguments" => args}.to_json)
      while line = sock.gets
        msg = JSON.parse(line)
        if e = msg["event"]?
          block.call(Events::Event.from_json(e.to_json))
        elsif st = msg["state"]?
          block.call(Daemon::Status.from_json(st.to_json))
        end
      end
      true
    rescue IO::Error
      true
    ensure
      sock.try &.close
    end

    def self.running?(path : String = Config.socket_path) : Bool
      return false if disabled?
      sock = connect(path)
      return false unless sock
      sock.close
      true
    end

    private def self.connect(path : String) : UNIXSocket?
      return nil unless File.exists?(path)
      sock = UNIXSocket.new(path)
      sock.read_timeout = 30.seconds
      sock
    rescue Socket::ConnectError | IO::Error
      nil
    end
  end
end
