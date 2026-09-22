require "json"
require "jargon"
require "base64"
require "./commands"
require "./capture"

module Camelot
  # Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
  # Every Jargon subcommand becomes a tool: its schema is the tool's
  # inputSchema, and a call is parsed by Jargon exactly as the command line
  # would be, so validation, defaults and behaviour are identical.
  class MCP
    PROTOCOL_VERSION = "2025-06-18"

    # Subcommands that are not tools: the server itself, the daemon, the
    # unbounded event stream (`recent` is its tool-shaped counterpart), and
    # the user's controls over recording, which are not an AI's to flip.
    EXCLUDED = Commands::NOT_TOOLS

    def initialize(@cli : Jargon::CLI, @input : IO = STDIN, @output : IO = STDOUT, @log : IO = STDERR)
    end

    def serve : Nil
      while line = @input.gets
        next if line.blank?
        if response = handle_line(line)
          @output.puts response.to_json
          @output.flush
        end
      end
    end

    # One JSON-RPC message in, one response out (nil for notifications).
    def handle_line(line : String) : Hash(String, JSON::Any)?
      message = JSON.parse(line)
      handle(message)
    rescue ex : JSON::ParseException
      error(nil, -32700, "parse error: #{ex.message}")
    end

    def handle(message : JSON::Any) : Hash(String, JSON::Any)?
      id = message["id"]?
      method = message["method"]?.try(&.as_s?)
      params = message["params"]?
      return error(id, -32600, "invalid request") unless method

      case method
      when "initialize"
        result(id, {
          "protocolVersion" => PROTOCOL_VERSION,
          "capabilities"    => {"tools" => {} of String => String},
          "serverInfo"      => {"name" => "camelot", "version" => VERSION},
        })
      when "ping"
        result(id, {} of String => String)
      when "tools/list"
        result(id, {"tools" => tools})
      when "tools/call"
        name = params.try(&.["name"]?).try(&.as_s?) || return error(id, -32602, "missing tool name")
        args = params.try(&.["arguments"]?) || JSON.parse("{}")
        content, is_error = call_content(name, args)
        result(id, {"content" => content, "isError" => is_error})
      else
        # Notifications (no id) are acknowledged by silence.
        id ? error(id, -32601, "method not found: #{method}") : nil
      end
    end

    # Tool definitions derived from the subcommand schemas.
    def tools : Array(Hash(String, JSON::Any))
      @cli.subcommands.compact_map do |name, schema|
        next if EXCLUDED.includes?(name)
        next unless schema.is_a?(Jargon::Schema)
        input = input_schema(schema)
        # `output` writes a file; an MCP client receives the image itself.
        input.as_h["properties"].as_h.delete("output") if name == "shot"
        {
          "name"        => JSON::Any.new(name),
          "description" => JSON::Any.new(schema.root.description || name),
          "inputSchema" => input,
        }
      end
    end

    # Run a tool through the shared command runner (which forwards to the
    # daemon when one is running).
    def call(name : String, args : JSON::Any) : {String, Bool}
      Commands.run(@cli, name, args)
    rescue ex
      @log.puts "camelot mcp: #{name}: #{ex.inspect_with_backtrace}"
      {"internal error: #{ex.message}", true}
    end

    # A tool call as MCP content blocks. `shot` answers with an image;
    # everything else with the command's text.
    def call_content(name : String, args : JSON::Any) : {Array(Hash(String, String)), Bool}
      return {[{"type" => "text", "text" => "unknown tool: #{name}"}], true} if EXCLUDED.includes?(name)
      if name == "shot"
        return shot(args)
      end
      text, is_error = call(name, args)
      {[{"type" => "text", "text" => text}], is_error}
    end

    # One frame, as an MCP image block. The desktop announces every
    # capture its own way; nothing is recorded.
    private def shot(args : JSON::Any) : {Array(Hash(String, String)), Bool}
      image = Capture.shot(
        interactive: args["pick"]?.try(&.as_bool?) || false,
        max_edge: (args["max-edge"]?.try(&.as_i64?) || Capture::DEFAULT_MAX_EDGE.to_i64).to_i32,
        quality: (args["quality"]?.try(&.as_i64?) || Capture::DEFAULT_QUALITY.to_i64).to_i32)
      {[{"type" => "image", "data" => Base64.strict_encode(image.bytes), "mimeType" => image.mime}], false}
    rescue ex : Capture::Error
      {[{"type" => "text", "text" => ex.message || "capture failed"}], true}
    end

    # ---- schema conversion ---------------------------------------------------

    # Jargon's parsed schema back to plain JSON Schema (CLI-only hints such
    # as `short` dropped, `x-*` extensions kept).
    def input_schema(schema : Jargon::Schema) : JSON::Any
      root = property_schema(schema.root, schema)
      root["type"] = JSON::Any.new("object")
      root.delete("description") # already the tool description
      JSON::Any.new(root)
    end

    private def property_schema(prop : Jargon::Property, schema : Jargon::Schema) : Hash(String, JSON::Any)
      if ref = prop.ref
        target = schema.definitions[ref.lchop("#/$defs/").lchop("#/definitions/")]?
        return property_schema(target, schema) if target
      end
      h = {} of String => JSON::Any
      h["type"] = JSON::Any.new(prop.type.to_s.downcase)
      h["description"] = JSON::Any.new(prop.description.not_nil!) if prop.description
      h["default"] = prop.default.not_nil! if prop.default
      h["enum"] = JSON::Any.new(prop.enum_values.not_nil!) if prop.enum_values
      h["const"] = prop.const.not_nil! if prop.const
      h["format"] = JSON::Any.new(prop.format.not_nil!) if prop.format && prop.format != "path"
      h["pattern"] = JSON::Any.new(prop.pattern.not_nil!.source) if prop.pattern
      number(h, "minimum", prop.minimum)
      number(h, "maximum", prop.maximum)
      number(h, "exclusiveMinimum", prop.exclusive_minimum)
      number(h, "exclusiveMaximum", prop.exclusive_maximum)
      number(h, "multipleOf", prop.multiple_of)
      h["minLength"] = JSON::Any.new(prop.min_length.not_nil!.to_i64) if prop.min_length
      h["maxLength"] = JSON::Any.new(prop.max_length.not_nil!.to_i64) if prop.max_length
      h["minItems"] = JSON::Any.new(prop.min_items.not_nil!.to_i64) if prop.min_items
      h["maxItems"] = JSON::Any.new(prop.max_items.not_nil!.to_i64) if prop.max_items
      h["uniqueItems"] = JSON::Any.new(true) if prop.unique_items?
      if items = prop.items
        h["items"] = JSON::Any.new(property_schema(items, schema))
      end
      if props = prop.properties
        h["properties"] = JSON::Any.new(props.transform_values { |p| JSON::Any.new(property_schema(p, schema)) })
        required = props.values.select(&.required?).map { |p| JSON::Any.new(p.name) }
        h["required"] = JSON::Any.new(required) unless required.empty?
      end
      h["additionalProperties"] = JSON::Any.new(false) if prop.additional_properties == false
      prop.extensions.each { |k, v| h[k] = v }
      h
    end

    private def number(h, key : String, value : Float64?)
      return unless value
      h[key] = value == value.floor ? JSON::Any.new(value.to_i64) : JSON::Any.new(value)
    end

    # ---- JSON-RPC envelopes --------------------------------------------------

    private def result(id : JSON::Any?, payload) : Hash(String, JSON::Any)
      {
        "jsonrpc" => JSON::Any.new("2.0"),
        "id"      => id || JSON::Any.new(nil),
        "result"  => JSON.parse(payload.to_json),
      }
    end

    private def error(id : JSON::Any?, code : Int32, message : String) : Hash(String, JSON::Any)
      {
        "jsonrpc" => JSON::Any.new("2.0"),
        "id"      => id || JSON::Any.new(nil),
        "error"   => JSON.parse({"code" => code, "message" => message}.to_json),
      }
    end
  end
end
