require "./a11y"
require "./context"
require "./events"

module Camelot
  # Human-readable renderings. JSON and YAML come from the serializable
  # snapshot types themselves; this is only the `text` format.
  module Format
    FORMATS = %w[text json yaml]

    def self.emit(io : IO, obj, format : String) : Nil
      case format
      when "json" then io.puts obj.to_pretty_json
      when "yaml" then io.print obj.to_yaml
      else             text(io, obj)
      end
    end

    def self.text(io : IO, node : A11y::Node, indent : Int32 = 0) : Nil
      io.puts "#{"  " * indent}#{line(node)}"
      if t = node.text
        block(io, t, indent + 1)
      end
      node.children.try &.each { |c| text(io, c, indent + 1) }
    end

    def self.text(io : IO, nodes : Array(A11y::Node)) : Nil
      nodes.each { |n| text(io, n) }
    end

    def self.text(io : IO, ctx : Context) : Nil
      if app = ctx.application
        io.puts "application: #{app.name} (pid #{app.pid}#{app.toolkit ? ", #{app.toolkit}" : ""})"
      else
        io.puts "application: (none)"
      end
      io.puts "window: #{ctx.window.try { |w| line(w) } || "(none)"}"
      unless ctx.ancestors.empty?
        io.puts "path: #{ctx.ancestors.map { |a| label(a) }.join(" › ")}"
      end
      if f = ctx.focus
        io.puts "focus: #{line(f)}"
        if t = f.text
          block(io, t, 1)
        end
      else
        io.puts "focus: (none)"
      end
    end

    def self.text(io : IO, obj) : Nil
      io.puts obj.to_s
    end

    # One-line summary: role "name" [states] @x,y wxh
    def self.line(n : A11y::Node) : String
      String.build do |s|
        s << label(n)
        s << " [redacted]" if n.redacted
        s << " [" << n.states.join(", ") << "]" unless n.states.empty?
        s << " =" << n.value if n.value
        if e = n.extents
          s << " @" << e.x << "," << e.y << " " << e.width << "x" << e.height
        end
        s << " (" << n.child_count << " children)" if n.children.nil? && n.child_count > 0
        s << " — " << n.description if n.description
        if acts = n.actions
          s << " {" << acts.join(", ") << "}" unless acts.empty?
        end
      end
    end

    # One event per line: time, type, app, widget, and the detail that matters.
    def self.line(e : Events::Event) : String
      String.build do |s|
        s << e.time.to_s("%H:%M:%S.%L") << "  " << e.type.ljust(28) << "  "
        s << e.app << ": " if e.app
        s << (e.role || "?")
        s << " " << e.name.inspect if e.name
        case e.type
        when .starts_with?("object:text-changed")
          s << " @" << e.detail1 << " (" << e.detail2 << " chars)"
          s << " " << e.text.inspect if e.text
        when "object:text-caret-moved"
          s << " caret " << e.detail1
        when "object:state-changed:focused"
          s << (e.detail1 == 1 ? " gained" : " lost")
        end
      end
    end

    def self.label(n : A11y::Node) : String
      n.name ? "#{n.role} #{n.name.inspect}" : n.role
    end

    private def self.block(io : IO, t : A11y::TextInfo, indent : Int32) : Nil
      pad = "  " * indent
      span = t.truncated ? " (chars #{t.offset}-#{t.offset + t.content.size} of #{t.length})" : ""
      caret = t.caret >= 0 ? ", caret at #{t.caret}" : ""
      io.puts "#{pad}text#{span}#{caret}:"
      t.content.each_line(chomp: true) { |l| io.puts "#{pad}| #{l}" }
    end
  end
end
