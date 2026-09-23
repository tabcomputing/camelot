require "./spec_helper"

private def with_runtime_dir(&)
  dir = File.join(Dir.tempdir, "camelot-shelf-spec-#{Random.rand(1_000_000)}")
  old = ENV["XDG_RUNTIME_DIR"]?
  ENV["XDG_RUNTIME_DIR"] = dir
  begin
    yield dir
  ensure
    old ? (ENV["XDG_RUNTIME_DIR"] = old) : ENV.delete("XDG_RUNTIME_DIR")
    FileUtils.rm_rf(dir)
  end
end

describe Camelot::Shelf do
  it "holds one image, privately, until cleared" do
    with_runtime_dir do
      Camelot::Shelf.item.should be_nil
      image = Camelot::Capture::Image.new(Bytes[0xff, 0xd8, 1, 2, 3], "image/jpeg", 40, 30)
      item = Camelot::Shelf.put(image, "pick")
      item.source.should eq "pick"
      {item.width, item.height, item.bytes}.should eq({40, 30, 5})

      read = Camelot::Shelf.item.not_nil!
      read.data.should eq image.bytes
      (File.info(Camelot::Shelf.dir).permissions.value & 0o077).should eq 0
      (File.info(read.path).permissions.value & 0o077).should eq 0

      Camelot::Shelf.put(Camelot::Capture::Image.new(Bytes[9], "image/jpeg", 1, 1), "shot")
      Camelot::Shelf.item.not_nil!.source.should eq "shot" # replaced, not added
      Dir.children(Camelot::Shelf.dir).sort.should eq ["shelf.jpg", "shelf.json"]

      Camelot::Shelf.clear.should be_true
      Camelot::Shelf.item.should be_nil
      Camelot::Shelf.clear.should be_false
    end
  end
end

describe Camelot::Capture do
  it "decodes the file URIs the portal answers with" do
    Camelot::Capture.path_from_uri("file:///home/me/Pictures/Screenshot.png").should eq "/home/me/Pictures/Screenshot.png"
    Camelot::Capture.path_from_uri("file:///home/me/Pictures/Screenshots/Screenshot%20From%202026-09-23%2001-48-24.png")
      .should eq "/home/me/Pictures/Screenshots/Screenshot From 2026-09-23 01-48-24.png"
  end
end
