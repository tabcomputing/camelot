require "json"
require "socket"
require "./config"

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
