require "./spec_helper"

private def ev(type, offset, app = "editor", pid = 7_u32, role = "text", name = "Body", path = "0/1", detail1 = 0, text = nil)
  Camelot::Events::Event.new(Time.local(2026, 9, 21, 12, 0, 0) + offset.seconds, type, app, pid, role, name, path, detail1, 0, text)
end

describe Camelot::History do
  it "is bounded" do
    h = Camelot::History.new(3)
    5.times { |i| h.record(ev("window:activate", i)) }
    h.count.should eq 3
    h.total.should eq 5
  end

  it "folds a burst of edits on one widget into one entry" do
    h = Camelot::History.new
    h.record(ev("window:activate", 0, role: "frame", name: "Doc", path: "0"))
    h.record(ev("object:state-changed:focused", 1, detail1: 1))
    h.record(ev("object:state-changed:focused", 1, detail1: 0, path: "0/9")) # focus lost: noise
    h.record(ev("object:text-changed:insert", 2, text: "hel"))
    h.record(ev("object:text-changed:delete", 3, text: "l"))
    h.record(ev("object:text-changed:insert", 4, text: "llo"))
    h.record(ev("object:text-changed:insert", 5, path: "0/2", name: "Title", text: "T"))
    h.record(ev("window:deactivate", 6)) # noise

    entries = h.recent(Time.local(2026, 9, 21, 11, 0, 0))
    entries.map(&.kind).should eq %w[window focus edit edit]
    burst = entries[2]
    burst.count.should eq 3
    burst.text.should eq "llo"
    burst.until.not_nil!.should eq entries[2].time + 2.seconds
    entries[3].name.should eq "Title"
  end

  it "respects since and limit" do
    h = Camelot::History.new
    10.times { |i| h.record(ev("window:activate", i, name: "W#{i}")) }
    h.recent(Time.local(2026, 9, 21, 12, 0, 5), 3).map(&.name).should eq %w[W7 W8 W9]
  end
end

describe Camelot::Config do
  it "matches ignore patterns case-insensitively with globs" do
    c = Camelot::Config.from_yaml("ignore: [KeePassXC, '1Password*']\nhistory: 5")
    c.ignored?("keepassxc").should be_true
    c.ignored?("1Password 8").should be_true
    c.ignored?("Firefox").should be_false
    c.ignored?(nil).should be_false
    c.history.should eq 5
  end

  it "defaults when there is no file" do
    c = Camelot::Config.load("/nonexistent/config.yaml")
    c.ignore.should be_empty
    c.history.should eq 2000
  end
end
