require "./spec_helper"

private def ev(type, offset, app = "editor", pid = 7_u32, role = "text", name = "Body", path = "0/1", detail1 = 0, text = nil)
  Camelot::Events::Event.new(Time.local(2026, 9, 21, 12, 0, 0) + offset.seconds, type, app, pid, role, name, path, detail1, 0, text)
end

describe Camelot::History do
  it "is bounded" do
    h = Camelot::History.new(3, (365 * 100).days)
    5.times { |i| h.record(ev("window:activate", i)) }
    h.count.should eq 3
    h.total.should eq 5
  end

  # Events in these specs carry fixed timestamps, so retention is disabled.
  it "folds a burst of edits on one widget into one entry" do
    h = Camelot::History.new(2000, (365 * 100).days)
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

  it "expires events older than the retention window" do
    h = Camelot::History.new(100, 10.seconds)
    h.record(ev("window:activate", 0, name: "old"))
    h.record(ev("window:activate", 5, name: "mid"))
    h.record(ev("window:activate", 20, name: "new")) # 20s later: "old" and "mid" have aged out
    now = Time.local(2026, 9, 21, 12, 0, 21)
    h.count(now).should eq 1
    h.since(Time.local(2026, 9, 21, 11, 0, 0), now).map(&.name).should eq ["new"]
    h.count(now + 1.minute).should eq 0 # idle time expires the rest
  end

  it "respects since and limit" do
    h = Camelot::History.new(2000, (365 * 100).days)
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
    c.retention.should eq 30.minutes
    c.text.should be_true
    c.accessibility.should be_true
  end

  it "resolves the log directory" do
    Camelot::Config.from_yaml("log: false").log_dir.should be_nil
    Camelot::Config.from_yaml("log: ~/logs").log_dir.should eq File.join(Path.home, "logs")
    Camelot::Config.from_yaml("log: true").log_dir.not_nil!.should end_with "/camelot"
  end

  it "parses durations with s/m/h/d suffixes" do
    Camelot::Config.from_yaml("retention: 90s").retention.should eq 90.seconds
    Camelot::Config.from_yaml("retention: 2h").retention.should eq 2.hours
    Camelot::Config.from_yaml("retention: 45").retention.should eq 45.seconds
    expect_raises(YAML::ParseException, /bad duration/) { Camelot::Config.from_yaml("retention: soon") }
  end
end
