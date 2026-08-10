// MCPToolDescriptor.swift — the wire description of one MCP tool.
//
// SwiftMCPCore already models the tool you IMPLEMENT: `MCPTool` is a
// protocol with a `handle(_:context:)` method, and `MCPToolEntry`
// type-erases a conforming instance for the server registry. Both are
// about EXECUTION — they carry a closure you can call.
//
// What was missing is the tool you merely OBSERVE: the object an MCP
// server publishes in its `tools/list` response. That object is not
// executable — it is a description, and it is the only thing a client,
// a proxy or an aggregating gateway ever holds about a REMOTE tool.
// Until now it existed in this package solely as an anonymous
// dictionary literal inside `MCPServer.handleToolsList`:
//
//     .object([
//       "name": .string(entry.name),
//       "description": .string(entry.description),
//       "inputSchema": entry.inputSchema,
//     ])
//
// Because it had no name, it could not be shared. Every consumer that
// needed to hold a remote tool re-declared its own struct — which is
// how a downstream gateway ended up shipping a second, incompatible
// `MCPTool` type. `MCPToolDescriptor` is that missing type, and
// `handleToolsList` now emits through it, so the server's outbound
// shape and a client's inbound shape are the same declaration rather
// than two hand-written dictionaries that drift.
//
// Why `inputSchema` is a `JSONValue` and not a `String`: a serialised
// JSON string is the workaround you reach for when your schema type is
// neither `Sendable` nor `Codable`. `JSONValue` is both, so the
// workaround buys nothing and costs a parse on every read plus a class
// of "it round-tripped but the bytes changed" bugs. Descriptors decoded
// off the wire and descriptors built from a local `MCPTool` are
// therefore `Equatable` against each other without re-serialising.
//
// Conformances: `Codable` so a descriptor persists to disk or crosses a
// queue; `Sendable` so it crosses actor boundaries (a gateway holds its
// catalogue in an actor); `Equatable` for catalogue diffing when a
// server re-publishes; `Identifiable` because `name` is unique within
// one server's catalogue by MCP contract.

import Foundation

// MARK: - MCPToolDescriptor

/// A tool as ADVERTISED over the wire — the `tools/list` entry.
///
/// Hold this for tools you did not implement (a remote server's), and
/// build it from `MCPTool`/`MCPToolEntry` for tools you did. It carries
/// no handler: a descriptor describes, it does not execute.
public struct MCPToolDescriptor: Sendable, Equatable, Codable, Identifiable {

    /// The canonical empty input schema — an object taking no
    /// properties. MCP requires `inputSchema` to be present even when a
    /// tool takes no arguments, so this is the correct "no input"
    /// value rather than `.null` or an omitted key.
    public static let emptyObjectSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    /// Wire name of the tool, unique within its origin server.
    public let name: String

    /// Human-readable description surfaced to a model in `tools/list`.
    ///
    /// Optional in the MCP schema; normalised to `""` here so consumers
    /// never branch on nil just to concatenate a string.
    public let description: String

    /// JSON Schema for the tool's input parameters.
    public let inputSchema: JSONValue

    /// `Identifiable` — `name` is unique per server by MCP contract.
    /// Aggregators that merge several servers must namespace the name
    /// themselves before treating it as globally unique.
    public var id: String { name }

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue = MCPToolDescriptor.emptyObjectSchema
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Bridges from the executable side

extension MCPToolDescriptor {

    /// Describe a tool TYPE. `MCPTool`'s identity requirements are all
    /// static, so a conforming type describes itself without being
    /// instantiated.
    public init<T: MCPTool>(_ toolType: T.Type) {
        self.init(
            name: T.name,
            description: T.description,
            inputSchema: T.inputSchema
        )
    }

    /// Describe a tool INSTANCE, via its dynamic type. Use when you hold
    /// a value rather than a metatype.
    public init<T: MCPTool>(_ tool: T) {
        self.init(type(of: tool))
    }

    /// Describe an already type-erased registry entry. This is the path
    /// `MCPServer` takes when answering `tools/list`; the entry's
    /// handler is deliberately dropped.
    public init(_ entry: MCPToolEntry) {
        self.init(
            name: entry.name,
            description: entry.description,
            inputSchema: entry.inputSchema
        )
    }
}

extension MCPToolEntry {

    /// This entry's advertisement, without its handler.
    public var descriptor: MCPToolDescriptor { MCPToolDescriptor(self) }
}

// MARK: - Wire encoding / decoding

extension MCPToolDescriptor {

    /// This descriptor as a single `tools/list` array element.
    public var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
        ])
    }

    /// Decode one `tools/list` array element.
    ///
    /// Returns `nil` only when `name` is absent or not a string — that
    /// is the one field with no sane default, since a nameless tool can
    /// never be called. A missing `description` becomes `""` and a
    /// missing `inputSchema` becomes `emptyObjectSchema`, both of which
    /// are what a server that omitted them meant.
    public init?(jsonValue: JSONValue) {
        guard let name = jsonValue["name"]?.stringValue else { return nil }
        self.init(
            name: name,
            description: jsonValue["description"]?.stringValue ?? "",
            inputSchema: jsonValue["inputSchema"] ?? MCPToolDescriptor.emptyObjectSchema
        )
    }

    /// Decode the `tools` array out of a whole `tools/list` RESULT
    /// object (`{"tools": [...]}`).
    ///
    /// Entries that fail to decode are skipped rather than failing the
    /// batch: one malformed tool from a third-party server must not
    /// blind a client to the server's other tools. Callers that need to
    /// detect the loss can compare against the source array's count.
    public static func list(fromToolsListResult result: JSONValue) -> [MCPToolDescriptor] {
        guard let tools = result["tools"]?.arrayValue else { return [] }
        return tools.compactMap(MCPToolDescriptor.init(jsonValue:))
    }

    /// Build a `tools/list` RESULT object from descriptors — the
    /// inverse of `list(fromToolsListResult:)`.
    public static func toolsListResult(_ descriptors: [MCPToolDescriptor]) -> JSONValue {
        .object(["tools": .array(descriptors.map(\.jsonValue))])
    }
}
