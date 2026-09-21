require "yaml"

module Camelot
  # User configuration, ~/.config/camelot/config.yaml:
  #
  #   ignore:            # applications never snapshotted or recorded
  #     - keepassxc
  #     - "1Password*"   # case-insensitive globs
  #   history: 2000      # events the daemon keeps
  #
  class Config
    include YAML::Serializable

    property ignore : Array(String) = [] of String
    property history : Int32 = 2000

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
