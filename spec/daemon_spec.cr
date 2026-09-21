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

  it "rejects malformed requests without dying" do
    daemon.respond("nope")["ok"].should be_false
    daemon.respond("{}")["error"].should eq "missing command"
    daemon.respond(%({"command":"mcp"}))["ok"].should be_false
  end
end
