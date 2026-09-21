require "jargon"
require "./camelot"

module Camelot
  # The camelot CLI, driven by Jargon. The subcommand schemas live in
  # schemas/commands.yaml and are embedded at compile time so the binary is
  # self-contained; the same schemas are the contract an MCP layer will expose.
  class CLI
    SCHEMA = {{ read_file("#{__DIR__}/../schemas/commands.yaml") }}

    def self.build : Jargon::CLI
      Jargon.cli("camelot", yaml: SCHEMA)
    end

    def self.main(argv = ARGV) : Nil
      cli = build
      cli.run(argv) do |result|
        new(result).dispatch
      end
    rescue ex : A11y::Error
      STDERR.puts "camelot: #{ex.message}"
      exit 2
    end

    def initialize(@result : Jargon::Result)
      @format = str?("format") || "text"
    end

    def dispatch
      case @result.subcommand
      when "apps"    then cmd_apps
      when "windows" then cmd_windows
      when "tree"    then cmd_tree
      when "focus"   then cmd_focus
      when "at"      then cmd_at
      when "context" then cmd_context
      else                abort("unknown command")
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
        apps.each { |a| puts "#{a.pid.to_s.rjust(7)}  #{a.name}#{a.toolkit ? "  (#{a.toolkit})" : ""}" }
      else
        Format.emit(STDOUT, apps, @format)
      end
    end

    private def cmd_windows
      apps = if q = str?("app")
               [A11y.application(q) || abort("no such application: #{q}")]
             else
               A11y.applications
             end
      opts = snapshot_options(depth: 0)
      nodes = apps.flat_map do |app|
        A11y.windows(app).map { |w| A11y.snapshot(w, opts) }
      end
      nodes.sort_by! { |n| n.states.includes?("active") ? 0 : 1 }
      Format.emit(STDOUT, nodes, @format)
    end

    private def cmd_tree
      root = if q = str?("app")
               A11y.application(q) || abort("no such application: #{q}")
             elsif win = A11y.active_window
               A11y.ancestry(win).first
             else
               abort("no active window; name an application")
             end
      path = ""
      if p = str?("path")
        path = p.strip("/")
        path.split("/").each do |i|
          idx = i.to_i? || abort("bad path segment: #{i}")
          root = A11y.safe(nil) { root.child_at_index(idx) } || abort("no child at #{path}")
        end
      end
      opts = snapshot_options(depth: int?("depth") || -1)
      Format.emit(STDOUT, A11y.snapshot(root, opts, path), @format)
    end

    private def cmd_focus
      focus = A11y.focused || abort("nothing has focus")
      opts = snapshot_options(depth: int?("depth") || 0, max_text: int?("max-text") || 4000)
      Format.emit(STDOUT, A11y.snapshot(focus, opts), @format)
    end

    private def cmd_at
      x = int?("x") || abort("x required")
      y = int?("y") || abort("y required")
      acc = if bool?("screen")
              A11y.at_screen_point(x, y)
            else
              win = if q = str?("app")
                      app = A11y.application(q) || abort("no such application: #{q}")
                      A11y.windows(app).find { |w| A11y.active?(w) } || A11y.windows(app).first?
                    else
                      A11y.active_window
                    end
              win ? A11y.at_point(win, x, y) : abort("no active window; name an application")
            end
      Format.emit(STDOUT, A11y.snapshot(acc || abort("nothing at #{x},#{y}"), snapshot_options(depth: 0)), @format)
    end

    private def cmd_context
      Format.emit(STDOUT, Context.capture(int?("max-text") || 4000), @format)
    end

    # ---- helpers --------------------------------------------------------------

    private def snapshot_options(depth : Int32, max_text : Int32? = nil) : A11y::Options
      A11y::Options.new(
        depth: depth,
        max_text: max_text || int?("max-text") || 200,
        extents: !bool?("no-extents"),
        actions: bool?("actions"),
        all_states: bool?("all-states"),
        prune: !bool?("raw"))
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

    private def abort(msg : String) : NoReturn
      STDERR.puts "camelot: #{msg}"
      exit 1
    end
  end
end

Camelot::CLI.main
