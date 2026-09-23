require "jargon"
require "./a11y"
require "./context"
require "./format"
require "./mcp"
require "./events"
require "./daemon"
require "./commands"

module Camelot
  # The camelot CLI, driven by Jargon. The subcommand schemas live in
  # schemas/commands.yaml and are embedded at compile time so the binary is
  # self-contained; the same schemas are what `camelot mcp` exposes as tools.
  class CLI
    SCHEMA = {{ read_file("#{__DIR__}/../../schemas/commands.yaml") }}

    # A command that could not do its job (bad argument, nothing found).
    class Error < Exception; end

    def self.build : Jargon::CLI
      Jargon.cli("camelot", yaml: SCHEMA)
    end

    def self.main(argv = ARGV) : Nil
      if argv == ["--version"] || argv == ["-V"]
        puts "camelot #{VERSION}"
        return
      end
      cli = build
      cli.run(argv) do |result|
        case result.subcommand
        when "mcp"
          MCP.new(cli).serve
        when "daemon"
          Daemon.new(cli,
            result["socket"]?.try(&.as_s?) || Config.socket_path,
            result["history"]?.try(&.as_i64?).try(&.to_i32) || Config.current.history).run
        when "watch"
          new(result).dispatch
        when "shot"
          new(result).cmd_shot
        when "subscribe"
          seconds = result["seconds"]?.try(&.as_i64?)
          streamed = Client.subscribe(seconds) do |msg|
            case msg
            in Events::Event  then puts msg.to_json
            in Daemon::Status then puts({"state" => msg}.to_json)
            end
            STDOUT.flush
          end
          raise Error.new("`subscribe` needs the daemon: start it with `camelot daemon`") if streamed.nil?
        else
          # A running daemon answers with warm caches and can answer
          # `recent`/`status`; otherwise run here.
          name = result.subcommand.not_nil!
          if !Commands::LOCAL_ONLY.includes?(name) && (answer = Client.call(name, result.data))
            output, is_error = answer
            raise Error.new(output) if is_error
            STDOUT.print output
          elsif Commands::DAEMON_ONLY.includes?(result.subcommand)
            raise Error.new("`#{result.subcommand}` needs the daemon: start it with `camelot daemon` (or `systemctl --user start camelot`)")
          else
            new(result).dispatch
          end
        end
      end
    rescue ex : Error
      STDERR.puts "camelot: #{ex.message}"
      exit 1
    rescue ex : A11y::Error | Config::Error | Capture::Error | Shell::Error
      STDERR.puts "camelot: #{ex.message}"
      exit 2
    rescue ex : IO::Error
      # `camelot tree | head` closes our stdout; that is not an error.
      raise ex unless ex.os_error == Errno::EPIPE
      exit 0
    end

    def initialize(@result : Jargon::Result, @out : IO = STDOUT)
      @format = str?("format") || "text"
    end

    def dispatch : Nil
      case @result.subcommand
      when "apps"    then cmd_apps
      when "windows" then cmd_windows
      when "tree"    then cmd_tree
      when "focus"   then cmd_focus
      when "at"      then cmd_at
      when "context" then cmd_context
      when "pointer" then cmd_pointer
      when "watch"   then cmd_watch
      else                fail("unknown command: #{@result.subcommand}")
      end
    end

    # ---- commands -------------------------------------------------------------

    private def cmd_apps
      apps = A11y.applications.map do |app|
        Context::Application.new(
          A11y.safe("") { app.name },
          A11y.safe(nil) { app.process_id },
          A11y.safe(nil) { app.toolkit_name })
      end
      case @format
      when "text"
        apps.each { |a| @out.puts "#{a.pid.to_s.rjust(7)}  #{a.name}#{a.toolkit ? "  (#{a.toolkit})" : ""}" }
      else
        Format.emit(@out, apps, @format)
      end
    end

    private def cmd_windows
      apps = if q = str?("app")
               [application(q)]
             else
               A11y.applications
             end
      opts = snapshot_options(depth: 0)
      nodes = apps.flat_map do |app|
        A11y.windows(app).map { |w| A11y.snapshot(w, opts) }
      end
      nodes.sort_by! { |n| n.states.includes?("active") ? 0 : 1 }
      Format.emit(@out, nodes, @format)
    end

    private def cmd_tree
      root = if q = str?("app")
               application(q)
             elsif win = A11y.active_window
               A11y.ancestry(win).first
             else
               fail("no active window; name an application")
             end
      path = ""
      if p = str?("path")
        path = p.strip("/")
        path.split("/").each do |i|
          idx = i.to_i? || fail("bad path segment: #{i}")
          root = A11y.child_at_index?(root, idx) || fail("no child at #{path}")
        end
      end
      opts = snapshot_options(depth: int?("depth") || -1)
      Format.emit(@out, A11y.snapshot(root, opts, path), @format)
    end

    private def cmd_focus
      focus = A11y.focused || fail("nothing has focus")
      opts = snapshot_options(depth: int?("depth") || 0, max_text: int?("max-text") || 4000)
      Format.emit(@out, A11y.snapshot(focus, opts), @format)
    end

    private def cmd_at
      x = int?("x") || fail("x required")
      y = int?("y") || fail("y required")
      acc = if bool?("screen")
              # Screen coordinates mean something only to the compositor on
              # Wayland; ask it when the extension is there (X11 apps answer
              # for themselves otherwise).
              Shell.available? ? Shell.resolve(x, y).widget : A11y.at_screen_point(x, y)
            else
              win = if q = str?("app")
                      app = application(q)
                      A11y.windows(app).find { |w| A11y.active?(w) } || A11y.windows(app).first?
                    else
                      A11y.active_window
                    end
              win ? A11y.at_point(win, x, y) : fail("no active window; name an application")
            end
      Format.emit(@out, A11y.snapshot(acc || fail("nothing at #{x},#{y}"), snapshot_options(depth: 0)), @format)
    end

    # Capture is deliberately not forwarded to the daemon: binary has no
    # place in a line-based JSON protocol, and the portal answers any
    # process of ours just as well.
    def cmd_shot : Nil
      image = Capture.shot(
        interactive: bool?("pick"),
        max_edge: int?("max-edge") || Capture::DEFAULT_MAX_EDGE,
        quality: int?("quality") || Capture::DEFAULT_QUALITY)
      if path = str?("output")
        File.write(path, image.bytes)
        @out.puts "#{path}: #{image.width}x#{image.height}, #{image.size // 1024} kB #{image.mime}"
      elsif @out.tty?
        fail("refusing to write an image to the terminal; use -o FILE or pipe it")
      else
        @out.write(image.bytes)
      end
    end

    record PointerReport, pointer : Shell::Point, application : String?, window : Shell::Hit?,
      widget : A11y::Node? do
      include JSON::Serializable
      include YAML::Serializable
    end

    private def cmd_pointer
      if (wait = int?("delay")) && wait > 0
        sleep wait.seconds
      end
      r = Shell.resolve_pointer
      app = r.widget.try { |w| A11y.application?(w) }.try { |a| A11y.safe(nil) { a.name } }
      node = r.widget.try { |w| A11y.snapshot(w, snapshot_options(depth: 0)) }
      if @format == "text"
        @out.puts "pointer: #{r.point.x},#{r.point.y}"
        if hit = r.window
          f = hit.frame
          @out.puts "window: #{app || "pid #{hit.pid}"} #{hit.title.inspect} at #{f.x},#{f.y} #{f.width}x#{f.height} " \
                    "(pointer at #{hit.frame_point.x},#{hit.frame_point.y} inside)"
        else
          @out.puts "window: (none: the desktop or the shell)"
        end
        @out.puts "under: #{node ? Format.line(node) : "(nothing the application will name)"}"
        if t = node.try(&.text)
          @out.puts "  text: #{t.content.lines.first?.try(&.strip)}"
        end
      else
        Format.emit(@out, PointerReport.new(r.point, app, r.window, node), @format)
      end
    end

    private def cmd_context
      Format.emit(@out, Context.capture(int?("max-text") || 4000), @format)
    end

    private def cmd_watch
      types = @result["events"]?.try(&.as_a?).try(&.map(&.as_s)) || Events::DEFAULT_TYPES
      duration = int?("duration") || 0
      stats_every = int?("stats") || 0
      count = 0

      queue = Events::Queue.new(types) do |event|
        count += 1
        case @format
        when "json" then @out.puts event.to_json
        when "yaml" then @out.puts event.to_yaml
        else             @out.puts Format.line(event)
        end
        @out.flush
      end

      if stats_every > 0
        # A plain Crystal fiber running alongside the GLib pump: the proof
        # that the two loops coexist.
        spawn do
          loop do
            sleep stats_every.seconds
            STDERR.puts "camelot watch: #{count} events"
          end
        end
      end

      Events.pump(duration > 0 ? Time.instant + duration.seconds : nil)
      queue.close
    end

    # ---- helpers --------------------------------------------------------------

    private def application(query : String) : Atspi::Accessible
      A11y.application(query) || fail("no such application: #{query}")
    end

    private def snapshot_options(depth : Int32, max_text : Int32? = nil) : A11y::Options
      A11y::Options.new(
        depth: depth,
        max_text: max_text || int?("max-text") || 200,
        extents: !bool?("no-extents"),
        actions: bool?("actions"),
        all_states: bool?("all-states"),
        prune: !bool?("raw"),
        hidden: bool?("hidden"))
    end

    private def str?(key) : String?
      @result[key]?.try(&.as_s?)
    end

    private def int?(key) : Int32?
      @result[key]?.try(&.as_i64?).try(&.to_i32)
    end

    private def bool?(key) : Bool
      @result[key]?.try(&.as_bool?) || false
    end

    private def fail(msg : String) : NoReturn
      raise Error.new(msg)
    end
  end
end
