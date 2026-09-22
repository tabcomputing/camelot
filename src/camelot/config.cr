require "yaml"

module Camelot
  # User configuration, ~/.config/camelot/config.yaml:
  #
  #   ignore:              # applications never snapshotted or recorded
  #     - keepassxc
  #     - "1Password*"     # case-insensitive globs
  #   history: 2000        # most events the daemon keeps...
  #   retention: 30m       # ...and for how long (s/m/h suffix, or seconds)
  #   text: true           # record what was typed, not just that typing happened
  #   accessibility: true  # daemon turns on toolkit accessibility at start
  #   screenshots: true    # allow screen capture at all (the desktop announces each one)
  #   log: false           # durable JSONL log: false, true ($XDG_STATE_HOME/camelot), or a directory
  #
  class Config
    include YAML::Serializable

    property ignore : Array(String) = [] of String
    property history : Int32 = 2000
    @[YAML::Field(converter: Camelot::Config::Duration)]
    property retention : Time::Span = 30.minutes
    property text : Bool = true
    property accessibility : Bool = true
    property screenshots : Bool = true
    property log : Bool | String = false

    # Directory for the durable log, or nil when logging is off.
    def log_dir : String?
      case l = log
      when String then Path[l].expand(home: true).to_s
      when true   then File.join(ENV["XDG_STATE_HOME"]? || File.join(Path.home, ".local", "state"), "camelot")
      else             nil
      end
    end

    # "30m", "2h", "90s" or a bare number of seconds.
    module Duration
      def self.from_yaml(ctx : YAML::ParseContext, node : YAML::Nodes::Node) : Time::Span
        raw = String.new(ctx, node)
        parse(raw) || raise YAML::ParseException.new("bad duration #{raw.inspect} (use e.g. 30m, 2h, 90s)", *node.location)
      end

      def self.to_yaml(value : Time::Span, yaml : YAML::Nodes::Builder)
        yaml.scalar(format(value))
      end

      # The largest unit that divides evenly: 1800s -> "30m".
      def self.format(value : Time::Span) : String
        secs = value.total_seconds.to_i64
        {86400 => "d", 3600 => "h", 60 => "m"}.each do |unit, suffix|
          return "#{secs // unit}#{suffix}" if secs > 0 && secs % unit == 0
        end
        "#{secs}s"
      end

      def self.parse(raw : String) : Time::Span?
        if m = raw.strip.match(/\A(\d+)\s*([smhd]?)\z/)
          n = m[1].to_i64
          case m[2]
          when "m" then n.minutes
          when "h" then n.hours
          when "d" then n.days
          else          n.seconds
          end
        end
      end
    end

    def initialize
    end

    def self.path : String
      base = ENV["XDG_CONFIG_HOME"]? || File.join(Path.home, ".config")
      File.join(base, "camelot", "config.yaml")
    end

    def self.load(path : String = self.path) : Config
      File.exists?(path) ? Config.from_yaml(File.read(path)) : Config.new
    rescue ex : YAML::ParseException
      raise Error.new("#{path}: #{ex.message}")
    end

    class Error < Exception; end

    # Write back to the config file (creating the directory).
    def save(path : String = Config.path) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.write(path, to_yaml, perm: 0o600)
    end

    # The loaded configuration, read once per process.
    class_property current : Config { load }

    # Is this application on the ignore list?
    def ignored?(app_name : String?) : Bool
      return false unless app_name
      name = app_name.downcase
      ignore.any? { |pattern| File.match?(pattern.downcase, name) }
    end

    def self.ignored?(app_name : String?) : Bool
      current.ignored?(app_name)
    end

    # Where the daemon listens.
    def self.socket_path : String
      if dir = ENV["XDG_RUNTIME_DIR"]?
        File.join(dir, "camelot.sock")
      else
        File.join(Dir.tempdir, "camelot-#{LibC.getuid}.sock")
      end
    end
  end
end
