require "./spec_helper"
require "jargon"

private def mcp
  schema = File.read(File.join(__DIR__, "..", "schemas", "commands.yaml"))
  Camelot::MCP.new(Jargon.cli("camelot", yaml: schema), IO::Memory.new, IO::Memory.new, IO::Memory.new)
end

private def rpc(server, method, params = nil, id = 1)
  msg = {"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  server.handle(JSON.parse(msg.to_json)).not_nil!
end

describe Camelot::MCP do
  it "answers initialize with tool capability" do
    r = rpc(mcp, "initialize", {"protocolVersion" => "2025-06-18"})
    r["result"]["protocolVersion"].as_s.should eq Camelot::MCP::PROTOCOL_VERSION
    r["result"]["capabilities"]["tools"].as_h.should be_empty
    r["result"]["serverInfo"]["name"].as_s.should eq "camelot"
  end

  it "lists every command except mcp as a tool" do
    r = rpc(mcp, "tools/list")
    names = r["result"]["tools"].as_a.map(&.["name"].as_s)
    names.sort.should eq %w[apps at context focus tree windows]
  end

  it "turns the Jargon schema into plain JSON Schema" do
    r = rpc(mcp, "tools/list")
    at = r["result"]["tools"].as_a.find! { |t| t["name"] == "at" }
    schema = at["inputSchema"]
    schema["type"].as_s.should eq "object"
    schema["required"].as_a.map(&.as_s).sort.should eq %w[x y]
    schema["properties"]["x"]["type"].as_s.should eq "integer"
    schema["properties"]["format"]["enum"].as_a.map(&.as_s).should eq %w[text json yaml]
    schema["properties"]["format"]["default"].as_s.should eq "text"
    schema["properties"]["screen"]["type"].as_s.should eq "boolean"
    # CLI-only hints do not leak into the tool contract.
    schema["properties"]["format"].as_h.has_key?("short").should be_false
    schema.as_h.has_key?("positional").should be_false
  end

  it "reports validation failures as tool errors, not protocol errors" do
    r = rpc(mcp, "tools/call", {"name" => "at", "arguments" => {"x" => 1}})
    r["result"]["isError"].as_bool.should be_true
    r["result"]["content"][0]["text"].as_s.should contain "y"
  end

  it "refuses to serve itself as a tool" do
    r = rpc(mcp, "tools/call", {"name" => "mcp"})
    r["result"]["isError"].as_bool.should be_true
  end

  it "stays silent on notifications and errors on unknown methods" do
    server = mcp
    server.handle(JSON.parse(%({"jsonrpc":"2.0","method":"notifications/initialized"}))).should be_nil
    rpc(server, "nope")["error"]["code"].as_i.should eq -32601
    server.handle_line("{").not_nil!["error"]["code"].as_i.should eq -32700
  end
end
