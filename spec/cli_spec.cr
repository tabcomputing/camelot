require "./spec_helper"
require "jargon"

# The CLI schema is the contract an MCP layer will expose, so make sure it
# parses and the command surface stays as documented.
describe "camelot schema" do
  schema = File.read(File.join(__DIR__, "..", "schemas", "commands.yaml"))

  it "defines the documented commands" do
    cli = Jargon.cli("camelot", yaml: schema)
    %w[apps windows tree focus at context].each do |cmd|
      cli.help(cmd).should contain(cmd)
    end
  end

  it "parses tree with a positional app and options" do
    cli = Jargon.cli("camelot", yaml: schema)
    r = cli.parse(["tree", "gimp", "-d", "3", "-f", "json", "--raw"])
    r.subcommand.should eq "tree"
    r["app"].as_s.should eq "gimp"
    r["depth"].as_i64.should eq 3
    r["format"].as_s.should eq "json"
    r["raw"].as_bool.should be_true
    r["max-text"].as_i64.should eq 200
  end

  it "requires x and y for at" do
    cli = Jargon.cli("camelot", yaml: schema)
    cli.parse(["at", "10"]).valid?.should be_false
    r = cli.parse(["at", "10", "20"])
    r.valid?.should be_true
    r["y"].as_i64.should eq 20
  end
end
