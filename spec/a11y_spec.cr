require "./spec_helper"

describe Camelot::A11y do
  describe ".prune" do
    it "splices anonymous wrappers out of the tree" do
      tree = node("frame", "Win", children: [
        node("panel", children: [
          node("grouping", children: [node("push button", "OK", path: "0/0/0")]),
          node("panel", "Sidebar", path: "0/1"),
        ]),
      ])
      pruned = Camelot::A11y.prune(tree).first
      pruned.children.not_nil!.map { |n| {n.role, n.name} }.should eq [{"push button", "OK"}, {"panel", "Sidebar"}]
      # The path still points at the real widget.
      pruned.children.not_nil!.first.path.should eq "0/0/0"
    end

    it "keeps a wrapper whose children were not expanded" do
      stub = node("panel", child_count: 3)
      Camelot::A11y.prune(stub).should eq [stub]
    end

    it "drops an empty anonymous wrapper" do
      Camelot::A11y.prune(node("panel")).should be_empty
    end

    it "keeps wrappers that carry content or focus" do
      Camelot::A11y.wrapper?(node("panel", text: "hello", children: [] of Camelot::A11y::Node)).should be_false
      Camelot::A11y.wrapper?(node("panel", states: ["focused"], children: [] of Camelot::A11y::Node)).should be_false
      Camelot::A11y.wrapper?(node("panel", actions: ["click"], children: [] of Camelot::A11y::Node)).should be_false
      Camelot::A11y.wrapper?(node("push button", children: [] of Camelot::A11y::Node)).should be_false
    end
  end

  describe "Node serialization" do
    it "round-trips through JSON and omits nils" do
      n = node("text", "Body", states: ["editable"], text: "hi")
      json = n.to_json
      json.should_not contain("description")
      back = Camelot::A11y::Node.from_json(json)
      back.role.should eq "text"
      back.text.not_nil!.content.should eq "hi"
      Camelot::A11y::Node.from_yaml(n.to_yaml).name.should eq "Body"
    end
  end
end
