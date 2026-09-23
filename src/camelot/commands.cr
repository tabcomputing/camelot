require "json"
require "jargon"
require "./client"

module Camelot
  # The one place a command is run from structured arguments. The MCP
  # server, the daemon's socket, and the CLI's forwarding all come here:
  # arguments are parsed by Jargon exactly as a command line would be,
  # then dispatched, with output captured.
  module Commands
    # Commands that only the daemon can answer.
    DAEMON_ONLY = %w[recent status pause resume reload subscribe]
    # Commands that are never forwarded to the daemon.
    LOCAL_ONLY = %w[mcp watch daemon shot pointer]
    # User controls over the daemon: not offered to an AI as tools.
    CONTROL = %w[pause resume reload subscribe]
    # Not offered as MCP tools: the server itself, the daemon, the
    # unbounded stream, and the user's own controls.
    NOT_TOOLS = %w[mcp watch daemon subscribe] + CONTROL

    # Run `name` with `args`. Forwards to a running daemon unless `local`.
    def self.run(cli : Jargon::CLI, name : String, args : JSON::Any, local : Bool = false) : {String, Bool}
      return {"unknown command: #{name}", true} unless cli.subcommands.has_key?(name)
      unless local || LOCAL_ONLY.includes?(name)
        if answer = Client.call(name, args)
          return answer
        end
      end
      if DAEMON_ONLY.includes?(name)
        return {"`#{name}` needs the daemon: start it with `camelot daemon` (or `systemctl --user start camelot`)", true}
      end
      result = cli.parse([name, "-"], IO::Memory.new(args.to_json))
      return {result.errors.join("\n"), true} unless result.valid?
      buffer = IO::Memory.new
      CLI.new(result, buffer).dispatch
      {buffer.to_s, false}
    rescue ex : CLI::Error | A11y::Error | Config::Error | Capture::Error | Shell::Error
      {ex.message || ex.class.name, true}
    end
  end
end
