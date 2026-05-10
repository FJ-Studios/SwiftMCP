import Foundation
import Logging

// MARK: - MCPContext

/// Contextual information available to every tool handler during invocation.
/// Injected by MCPServer at dispatch time; tools access it but do not create it.
public struct MCPContext: Sendable {
    /// Logger scoped to this request. Use for tool-level diagnostics.
    public let logger: Logger
    /// Monotonically increasing request count from the server.
    public let requestNumber: Int
    /// The raw request ID for correlation.
    public let requestId: JSONRPCId?

    public init(logger: Logger, requestNumber: Int, requestId: JSONRPCId?) {
        self.logger = logger
        self.requestNumber = requestNumber
        self.requestId = requestId
    }
}

// MARK: - MCPTool protocol

/// A single callable MCP tool. Conform structs or classes to this protocol.
///
/// Design notes:
/// - `inputSchema` uses the manual JSONValue dict approach (same as ShikkiMCP tools).
///   Codable-based auto-generation is deferred (see §7 in spec — complex, adds 20%+ code).
///   Implementors supply the schema as a JSONValue literal; the server emits it verbatim
///   in `tools/list` responses.
/// - `handle` receives raw `JSONValue?` params from the wire. Tools destructure themselves.
///   This keeps the protocol surface stable even when input shapes change.
/// - Returns `JSONValue` matching the MCP `tools/call` result envelope shape.
///
/// Minimum conformance:
/// ```swift
/// struct MyTool: MCPTool {
///     static let name = "my_tool"
///     static let description = "Does something useful"
///     static let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])
///     func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
///         return ToolResultBuilder.success("done")
///     }
/// }
/// ```
public protocol MCPTool: Sendable {
    /// The wire name of the tool (e.g. `"shiki_save_decision"`).
    static var name: String { get }
    /// Human-readable description surfaced in `tools/list`.
    static var description: String { get }
    /// JSON Schema for the tool's input parameters. Use `.object([...])` literals.
    /// See `ToolResultBuilder` for the standard result shapes.
    static var inputSchema: JSONValue { get }
    /// Handle a `tools/call` invocation. Params are the raw `arguments` value from the wire.
    /// Throw to emit a JSON-RPC error response (the server stays alive).
    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue
}

// MARK: - MCPToolDefinition (type-erased registration entry)

/// Internal type-erased record stored in MCPServer's registry.
/// Not public — consumers work through MCPTool conformance.
public struct MCPToolEntry: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let handler: @Sendable (JSONValue?, MCPContext) async throws -> JSONValue

    public init(tool: some MCPTool) {
        let toolType = type(of: tool)
        self.name = toolType.name
        self.description = toolType.description
        self.inputSchema = toolType.inputSchema
        // Capture the tool instance in the closure for its lifetime.
        self.handler = { params, ctx in
            try await tool.handle(params, context: ctx)
        }
    }
}

// MARK: - ToolResultBuilder

/// Standard MCP content-envelope builders.
/// Tools return `.success(...)` or `.error(...)` from `handle(_:context:)`.
/// The format matches the ShikkiMCP wire format exactly for backward compatibility.
public enum ToolResultBuilder: Sendable {

    /// Emit a successful text result. Optionally attach structured data (pretty-printed JSON).
    public static func success(_ message: String, data: JSONValue? = nil) -> JSONValue {
        var text = message
        if let data = data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let jsonData = try? encoder.encode(data),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                text += "\n\(jsonString)"
            }
        }
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ]),
            ]),
        ])
    }

    /// Emit an error result. The server stays alive; this is a tool-level error, not a JSON-RPC error.
    public static func error(_ message: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(message),
                ]),
            ]),
            "isError": .bool(true),
        ])
    }
}
