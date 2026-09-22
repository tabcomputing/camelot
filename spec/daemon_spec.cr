require "./spec_helper"

# The daemon's socket protocol, exercised without a bus: `status` and
# `recent` only touch the daemon's own state.
describe Camelot::Daemon do
  schema = File.read(File.join(__DIR__, "..", "schemas", "commands.yaml"))
  daemon = Camelot::Daemon.new(Jargon.cli("camelot", yaml: schema), "/tmp/camelot-spec.sock", 10, IO::Memory.new)

  it "answers status" do
    reply = daemon.respond(%({"command":"status","arguments":{"format":"json"}}))
    reply["ok"].should be_true
    JSON.parse(reply["output"].as(String))["capacity"].as_i.should eq 10
  end

  it "answers recent from its history" do
    daemon.history.record(Camelot::Events::Event.new(Time.local, "window:activate", "app", 1_u32, "frame", "Win", "0", 0, 0, nil))
    reply = daemon.respond(%({"command":"recent","arguments":{"seconds":5}}))
    reply["ok"].should be_true
    reply["output"].as(String).should contain %(window  app: frame "Win")
  end

  it "pauses and resumes recording" do
    daemon.respond(%({"command":"pause"}))["output"].should eq "recording paused\n"
    daemon.paused?.should be_true
    daemon.respond(%({"command":"pause"}))["output"].as(String).should start_with "already paused"
    daemon.respond(%({"command":"recent"}))["output"].as(String).should start_with "(recording paused since"
    JSON.parse(daemon.respond(%({"command":"status","arguments":{"format":"json"}}))["output"].as(String))["paused_since"].as_s?.should_not be_nil
    daemon.respond(%({"command":"resume"}))["output"].should eq "recording resumed\n"
    daemon.paused?.should be_false
    daemon.respond(%({"command":"resume"}))["output"].should eq "not paused\n"
  end

  it "writes a durable log, one JSON line per event, per day" do
    dir = File.join(Dir.tempdir, "camelot-spec-log-#{Random.rand(1_000_000)}")
    sink = Camelot::Daemon::Sink.new(dir)
    e1 = Camelot::Events::Event.new(Time.local(2026, 9, 21, 9, 0, 0), "window:activate", "app", 1_u32, "frame", "A", "0", 0, 0, nil)
    e2 = Camelot::Events::Event.new(Time.local(2026, 9, 22, 9, 0, 0), "object:text-changed:insert", "app", 1_u32, "text", "B", "0/1", 3, 1, "x")
    sink.write(e1)
    sink.write(e2)
    sink.close
    files = Dir.children(dir).sort
    files.should eq ["events-2026-09-21.jsonl", "events-2026-09-22.jsonl"]
    JSON.parse(File.read_lines(File.join(dir, files[1]))[0])["text"].as_s.should eq "x"
    (File.info(dir).permissions.value & 0o077).should eq 0
    FileUtils.rm_rf(dir)
  end

  it "rejects malformed requests without dying" do
    daemon.respond("nope")["ok"].should be_false
    daemon.respond("{}")["error"].should eq "missing command"
    daemon.respond(%({"command":"mcp"}))["ok"].should be_false
  end
end
