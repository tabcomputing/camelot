require "./spec_helper"

describe Camelot::Format do
  it "renders a node as an indented tree" do
    tree = node("frame", "Win", states: ["active"], children: [
      node("text", "Body", text: "line one\nline two", actions: ["copy"]),
    ])
    out = String.build { |io| Camelot::Format.text(io, tree) }
    out.should eq <<-TXT
      frame "Win" [active]
        text "Body" {copy}
          text, caret at 0:
          | line one
          | line two

      TXT
  end

  it "marks redacted widgets" do
    Camelot::Format.line(node("password text", "Password", redacted: true)).should eq %(password text "Password" [redacted])
  end

  it "flags unexpanded children" do
    Camelot::Format.line(node("panel", child_count: 4)).should eq "panel (4 children)"
  end

  it "renders a context" do
    ctx = Camelot::Context.new(
      Camelot::Context::Application.new("editor", 42_u32, "GTK"),
      node("frame", "Doc"),
      [node("panel", "Tab 1")],
      node("text", states: ["focused"], text: "abc"))
    out = String.build { |io| Camelot::Format.text(io, ctx) }
    out.lines[0].should eq "application: editor (pid 42, GTK)"
    out.lines[2].should eq %(path: panel "Tab 1")
    out.lines[3].should eq "focus: text [focused]"
  end

  it "emits json and yaml" do
    n = node("label", "Hi")
    String.build { |io| Camelot::Format.emit(io, n, "json") }.should contain %("role": "label")
    String.build { |io| Camelot::Format.emit(io, n, "yaml") }.should contain "role: label"
  end
end
