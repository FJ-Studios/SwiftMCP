import Foundation
import Logging
import SwiftMCPCore

// MARK: - MCPServer

/// Reusable MCP server actor. Handles JSON-RPC 2.0 dispatch over stdio (default transport).
///
/// Usage:
/// ```swift
/// let server = MCPServer(name: "my-mcp", version: "1.0.0")
/// try server.register(MyTool())
/// try await server.run(transport: .stdio)
/// ```
///
/// Robustness contract (Wave B):
/// - Malformed JSON input: logged to stderr, loop continues (no exit).
/// - Stdin EOF / pipe close: clean exit(0) within ~100ms.
/// - Tool-handler `throws`: caught and emitted as JSON-RPC error response; server stays alive.
/// - Cancellation: Task cancellation on stdin close propagates to in-flight tool calls.
/// - Structured logging via swift-log; label scoped to server name.
public actor MCPServer {
    // MARK: - Configuration

    private let serverName: String
    private let serverVersion: String
    private let protocolVersion: String

    // MARK: - State

    private var tools: [String: MCPToolEntry] = [:]
    private var requestCount: Int = 0
    private let logger: Logger

    // MARK: - Init

    public init(
        name: String,
        version: String,
        protocolVersion: String = "2024-11-05"
    ) {
        self.serverName = name
        self.serverVersion = version
        self.protocolVersion = protocolVersion
        self.logger = Logger(label: "swiftmcp.\(name)")
    }

    // MARK: - Tool Registration

    /// Register a tool. Throws if a tool with the same name is already registered.
    public func register(_ tool: some MCPTool) throws {
        let entry = MCPToolEntry(tool: tool)
        guard tools[entry.name] == nil else {
            throw RegistrationError.duplicateTool(name: entry.name)
        }
        tools[entry.name] = entry
        logger.debug("Registered tool: \(entry.name)")
    }

    /// Register multiple tools at once.
    public func register(_ toolList: [any MCPTool]) throws {
        for tool in toolList {
            try register(tool)
        }
    }

    // MARK: - Run

    /// Start the server. Blocks until stdin closes (EOF) or the Task is cancelled.
    /// - Parameter transport: `.stdio` for production, `.test(...)` for unit tests.
    public func run(transport: MCPTransport = .stdio) async {
        logger.info("\(serverName) v\(serverVersion) starting — protocol \(protocolVersion)")

        switch transport {
        case .stdio:
            await runStdio()
        case .test(let input, let output):
            await runTest(input: input, output: output)
        case .unixSocket(let path):
            // Planned for shi-discovery MCP. Not implemented yet.
            logger.error("unixSocket transport not yet implemented (path: \(path))")
        }

        logger.info("\(serverName) shutting down (processed \(requestCount) requests)")
    }

    // MARK: - Stdio loop

    private func runStdio() async {
        let stdout = FileHandle.standardOutput

        // `readLine()` blocks synchronously. Swift 6 concurrency note: this is fine
        // inside an actor method — the actor suspends at `await` points, not at
        // synchronous blocking calls. The tradeoff is that we can't cancel mid-read.
        // EOF from the peer (Claude Desktop closing) causes readLine() to return nil,
        // which exits the loop cleanly.
        while !Task.isCancelled {
            guard let line = readLine() else {
                // stdin EOF — clean shutdown
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // handleMessage returns nil for notifications (no response on wire per spec)
            if let responseJSON = await handleMessage(trimmed) {
                if let data = responseJSON.data(using: .utf8) {
                    stdout.write(data)
                    stdout.write(Data("\n".utf8))
                }
            }
        }
    }

    // MARK: - Test transport loop

    private func runTest(input: AsyncStream<Data>, output: AsyncStream<Data>.Continuation) async {
        for await chunk in input {
            guard !Task.isCancelled else { break }

            guard let line = String(data: chunk, encoding: .utf8) else {
                logger.error("Test transport received non-UTF8 data chunk")
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let responseJSON = await handleMessage(trimmed) {
                if let data = responseJSON.data(using: .utf8) {
                    output.yield(data)
                }
            }
        }
        output.finish()
    }

    // MARK: - Message handling (internal + testable)

    /// Returns the JSON response string, or nil for notifications (which MUST NOT produce a response).
    /// Public for test access only — normal callers use `run(transport:)`.
    public func handleMessage(_ message: String) async -> String? {
        requestCount += 1
        let reqNum = requestCount

        // Wave B robustness: invalid UTF-8 → log + continue
        guard let data = message.data(using: .utf8) else {
            logger.error("[req-\(reqNum)] Invalid UTF-8 input")
            return encodeResponse(JSONRPCResponse(
                id: nil,
                error: MCPError(code: MCPError.parseError, message: "Invalid UTF-8")
            ))
        }

        // Wave B robustness: malformed JSON → log to stderr, continue loop (no exit)
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            logger.error("[req-\(reqNum)] Parse error: \(error.localizedDescription)")
            return encodeResponse(JSONRPCResponse(
                id: nil,
                error: MCPError(code: MCPError.parseError, message: "Parse error: \(error.localizedDescription)")
            ))
        }

        logger.info("[req-\(reqNum)] \(request.method)")

        // Notifications: per MCP spec 2024-11-05, no response on the wire.
        if isNotification(request) {
            return nil
        }

        // Wave B robustness: tool-handler throws → JSON-RPC error response, server stays alive.
        // Dispatch handles this via do/catch in handleToolsCall.
        let response = await dispatch(request)
        return encodeResponse(response)
    }

    // MARK: - Notification detection

    /// True if this message is a one-way notification per MCP spec.
    private func isNotification(_ request: JSONRPCRequest) -> Bool {
        // Spec-compliant: method starts with "notifications/"
        if request.method.hasPrefix("notifications/") {
            return true
        }
        // Legacy bare form: method == "initialized" with no id
        if request.method == "initialized" && request.id == nil {
            return true
        }
        return false
    }

    // MARK: - Dispatch

    private func dispatch(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        switch request.method {
        case "initialize":
            return handleInitialize(request)
        case "initialized":
            // Notification-like ack — safe to return empty result
            return JSONRPCResponse(id: request.id, result: .object([:]))
        case "tools/list":
            return handleToolsList(request)
        case "tools/call":
            return await handleToolsCall(request)
        default:
            return JSONRPCResponse(
                id: request.id,
                error: MCPError(code: MCPError.methodNotFound, message: "Unknown method: \(request.method)")
            )
        }
    }

    // MARK: - Handlers

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let result: JSONValue = .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object([:]),
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(serverVersion),
            ]),
        ])
        return JSONRPCResponse(id: request.id, result: result)
    }

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        let toolList: [JSONValue] = tools.values
            .sorted { $0.name < $1.name }
            .map { entry in
                .object([
                    "name": .string(entry.name),
                    "description": .string(entry.description),
                    "inputSchema": entry.inputSchema,
                ])
            }
        return JSONRPCResponse(id: request.id, result: .object(["tools": .array(toolList)]))
    }

    private func handleToolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard let params = request.params?.objectValue,
              let toolName = params["name"]?.stringValue else {
            return JSONRPCResponse(
                id: request.id,
                error: MCPError(code: MCPError.invalidParams, message: "Missing tool name in params")
            )
        }

        guard let entry = tools[toolName] else {
            return JSONRPCResponse(
                id: request.id,
                error: MCPError(code: MCPError.invalidParams, message: "Unknown tool: \(toolName)")
            )
        }

        let arguments = params["arguments"]
        let context = MCPContext(
            logger: logger,
            requestNumber: requestCount,
            requestId: request.id
        )

        // Wave B robustness: tool-handler throws → emit JSON-RPC error, server stays alive.
        do {
            let result = try await entry.handler(arguments, context)
            return JSONRPCResponse(id: request.id, result: result)
        } catch {
            logger.error("[req-\(requestCount)] Tool '\(toolName)' threw: \(error)")
            return JSONRPCResponse(
                id: request.id,
                error: MCPError(
                    code: MCPError.internalError,
                    message: "Tool error: \(error.localizedDescription)"
                )
            )
        }
    }

    // MARK: - Encoding

    private func encodeResponse(_ response: JSONRPCResponse) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(response),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":-32603,"message":"Internal encoding error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return str
    }

    // MARK: - Diagnostics

    /// Number of requests processed (for diagnostics and tests).
    public var processedRequestCount: Int {
        requestCount
    }

    /// Names of all registered tools.
    public var registeredToolNames: [String] {
        tools.keys.sorted()
    }
}

// MARK: - Errors

public enum RegistrationError: Error, Sendable {
    case duplicateTool(name: String)
}
