require "json"
require "yaml"
require "./capture"

module Camelot
  # One slot for the thing you chose to show an AI: a picked window or
  # region. It is the only image camelot keeps, and only because you put it
  # there. It lives in $XDG_RUNTIME_DIR (memory-backed, private to you,
  # gone at logout) as a real file, so it can be dragged anywhere that takes
  # images, and the MCP `shelf` tool hands the same file to an agent.
  module Shelf
    class Item
      include JSON::Serializable
      include YAML::Serializable

      property time : Time
      property source : String # pick, shot, point
      property mime : String
      property width : Int32
      property height : Int32
      property bytes : Int32
      # Where the image is: drag this, read this.
      property path : String

      def initialize(@time, @source, @mime, @width, @height, @bytes, @path)
      end

      def data : Bytes
        File.read(path).to_slice
      end
    end

    def self.dir : String
      base = ENV["XDG_RUNTIME_DIR"]? || File.join(Dir.tempdir, "camelot-#{LibC.getuid}")
      File.join(base, "camelot")
    end

    def self.image_path : String
      File.join(dir, "shelf.jpg")
    end

    def self.meta_path : String
      File.join(dir, "shelf.json")
    end

    # Put an image on the shelf, replacing what was there.
    def self.put(image : Capture::Image, source : String) : Item
      Dir.mkdir_p(dir)
      File.chmod(dir, 0o700)
      write_atomically(image_path, image.bytes)
      item = Item.new(Time.local, source, image.mime, image.width, image.height, image.size, image_path)
      write_atomically(meta_path, item.to_json.to_slice)
      item
    end

    # What is on the shelf, if anything.
    def self.item : Item?
      return nil unless File.exists?(meta_path) && File.exists?(image_path)
      Item.from_json(File.read(meta_path))
    rescue JSON::ParseException | File::Error
      nil
    end

    def self.clear : Bool
      had = !item.nil?
      File.delete?(image_path)
      File.delete?(meta_path)
      had
    end

    # Write then rename, so a reader (the panel, an agent) never sees half
    # an image.
    private def self.write_atomically(path : String, data : Bytes) : Nil
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, "w", perm: 0o600) { |f| f.write(data) }
      File.rename(tmp, path)
    end
  end
end
