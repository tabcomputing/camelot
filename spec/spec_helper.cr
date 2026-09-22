require "file_utils"
require "spec"
require "../src/camelot"

# Build a snapshot node by hand, without touching the accessibility bus.
def node(role : String, name : String? = nil, *, path = "0", states = [] of String,
         text : String? = nil, children : Array(Camelot::A11y::Node)? = nil,
         child_count : Int32? = nil, actions : Array(String)? = nil, redacted : Bool? = nil) : Camelot::A11y::Node
  info = text ? Camelot::A11y::TextInfo.new(text.size, 0, 0, text, false) : nil
  Camelot::A11y::Node.new(role, name, nil, path, 1_u32, states, nil, info, nil, actions,
    child_count || children.try(&.size) || 0, children, redacted)
end
