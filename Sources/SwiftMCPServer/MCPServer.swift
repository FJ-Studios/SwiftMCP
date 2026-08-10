import Foundation
import Logging
import SwiftMCPCore

// MARK: - Framing Types

/// Transport framing mode auto-detected from first message
private enum FramingMode: Sendable {
    case newline    // JSON terminated by \n
    case lsp        // Content-Length: N\r\n\r\n{JSON}
}

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
    private var framingMode: FramingMode? = nil  // Auto-detected on first message

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
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput

        while !Task.isCancelled {
            // Read message with framing auto-detect
            guard let message = await readFramedMessage(from: stdin) else {
                // stdin EOF — clean shutdown
                logger.info("Client disconnected")
                break
            }

            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // handleMessage returns nil for notifications (no response on wire per spec)
            if let responseJSON = await handleMessage(trimmed) {
                await writeFramedResponse(responseJSON, to: stdout)
            }
        }
    }

    // MARK: - Framing I/O

    /// Read a message using auto-detected framing. Returns nil on EOF.
    private func readFramedMessage(from fileHandle: FileHandle) async -> String? {
        if let mode = framingMode {
            // Framing already locked
            switch mode {
            case .newline:
                return readLine()
            case .lsp:
                return await readLSPMessage(from: fileHandle)
            }
        } else {
            // Auto-detect from first byte
            return await autoDetectAndReadMessage(from: fileHandle)
        }
    }

    /// Auto-detect framing from the first byte and read the complete message
    private func autoDetectAndReadMessage(from fileHandle: FileHandle) async -> String? {
        // Peek at first byte without consuming
        var firstByte: UInt8 = 0
        let bytesRead = withUnsafeMutableBytes(of: &firstByte) { buffer in
            read(fileHandle.fileDescriptor, buffer.baseAddress, 1)
        }

        guard bytesRead == 1 else {
            return nil  // EOF
        }

        let firstChar = Character(UnicodeScalar(firstByte))

        if firstChar == "{" || firstChar == "[" {
            // Newline framing detected
            framingMode = .newline
            logger.debug("Auto-detected newline framing")

            // Read the rest of the line (we already consumed the first byte)
            guard let restOfLine = readLine() else { return nil }
            return String(firstChar) + restOfLine

        } else if firstChar == "C" {
            // LSP framing detected (Content-Length)
            framingMode = .lsp
            logger.debug("Auto-detected LSP framing")

            // Put the 'C' back by seeking back one byte
            lseek(fileHandle.fileDescriptor, -1, SEEK_CUR)
            return await readLSPMessage(from: fileHandle)

        } else {
            logger.error("Unknown framing: first byte 0x\(String(firstByte, radix: 16))")
            return nil
        }
    }

    /// Read an LSP-framed message (Content-Length header + body)
    private func readLSPMessage(from fileHandle: FileHandle) async -> String? {
        // Read headers until \r\n\r\n
        var headerData = Data()
        var consecutiveCR = 0

        while true {
            var byte: UInt8 = 0
            let bytesRead = withUnsafeMutableBytes(of: &byte) { buffer in
                read(fileHandle.fileDescriptor, buffer.baseAddress, 1)
            }

            guard bytesRead == 1 else { return nil }  // EOF
            headerData.append(byte)

            if byte == 13 {  // \r
                consecutiveCR += 1
            } else if byte == 10 && consecutiveCR > 0 {  // \n after \r
                consecutiveCR += 1
                if consecutiveCR >= 4 {  // \r\n\r\n
                    break
                }
            } else {
                consecutiveCR = 0
            }
        }

        // Parse Content-Length from headers
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        var contentLength: Int = 0
        for line in headerString.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let lengthStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(lengthStr) ?? 0
                break
            }
        }

        guard contentLength > 0 else { return nil }

        // Read the JSON body
        var bodyData = Data()
        while bodyData.count < contentLength {
            var byte: UInt8 = 0
            let bytesRead = withUnsafeMutableBytes(of: &byte) { buffer in
                read(fileHandle.fileDescriptor, buffer.baseAddress, 1)
            }
            guard bytesRead == 1 else { return nil }  // EOF
            bodyData.append(byte)
        }

        return String(data: bodyData, encoding: .utf8)
    }

    /// Write response using the locked framing mode
    private func writeFramedResponse(_ responseJSON: String, to fileHandle: FileHandle) async {
        guard let mode = framingMode else {
            // Fallback to newline if no framing detected yet
            if let data = responseJSON.data(using: .utf8) {
                fileHandle.write(data)
                fileHandle.write(Data("\n".utf8))
            }
            return
        }

        switch mode {
        case .newline:
            if let data = responseJSON.data(using: .utf8) {
                fileHandle.write(data)
                fileHandle.write(Data("\n".utf8))
            }
        case .lsp:
            if let data = responseJSON.data(using: .utf8) {
                let contentLength = data.count
                let header = "Content-Length: \(contentLength)\r\n\r\n"
                if let headerData = header.data(using: .utf8) {
                    fileHandle.write(headerData)
                    fileHandle.write(data)
                }
            }
        }
    }

    // MARK: - Test transport loop

    private func runTest(input: AsyncStream<Data>, output: AsyncStream<Data>.Continuation) async {
        var buffer = Data()

        for await chunk in input {
            guard !Task.isCancelled else { break }
            buffer.append(chunk)

            // Process complete messages from buffer
            while let message = extractMessageFromBuffer(&buffer) {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let responseJSON = await handleMessage(trimmed) {
                    let responseData = await formatTestResponse(responseJSON)
                    output.yield(responseData)
                }
            }
        }
        output.finish()
    }

    /// Extract a complete message from the buffer using framing auto-detect
    private func extractMessageFromBuffer(_ buffer: inout Data) -> String? {
        guard !buffer.isEmpty else { return nil }

        if let mode = framingMode {
            // Framing already locked
            switch mode {
            case .newline:
                return extractNewlineMessage(&buffer)
            case .lsp:
                return extractLSPMessage(&buffer)
            }
        } else {
            // Auto-detect framing from first byte
            let firstByte = buffer[0]
            let firstChar = Character(UnicodeScalar(firstByte))

            if firstChar == "{" || firstChar == "[" {
                framingMode = .newline
                logger.debug("Auto-detected newline framing (test)")
                return extractNewlineMessage(&buffer)
            } else if firstChar == "C" {
                framingMode = .lsp
                logger.debug("Auto-detected LSP framing (test)")
                return extractLSPMessage(&buffer)
            } else {
                logger.error("Unknown framing in test: first byte 0x\(String(firstByte, radix: 16))")
                buffer.removeFirst() // Skip unknown byte
                return nil
            }
        }
    }

    /// Extract newline-delimited message from buffer
    private func extractNewlineMessage(_ buffer: inout Data) -> String? {
        guard let newlineIndex = buffer.firstIndex(of: 10) else { // \n
            return nil // No complete message yet
        }

        let messageData = buffer.prefix(newlineIndex)
        let removeCount = min(newlineIndex + 1, buffer.count) // Safe removal count
        buffer.removeFirst(removeCount)

        return String(data: messageData, encoding: .utf8)
    }

    /// Extract LSP-framed message from buffer
    private func extractLSPMessage(_ buffer: inout Data) -> String? {
        // Look for \r\n\r\n header terminator
        let headerTerminator = Data([13, 10, 13, 10]) // \r\n\r\n
        guard let headerEndIndex = buffer.firstRange(of: headerTerminator)?.upperBound else {
            return nil // No complete header yet
        }

        let headerData = buffer.prefix(headerEndIndex - 4) // Exclude the \r\n\r\n
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        // Parse Content-Length
        var contentLength = 0
        for line in headerString.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let lengthStr = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(lengthStr) ?? 0
                break
            }
        }

        guard contentLength > 0 else { return nil }

        // Check if we have the complete body
        let totalMessageLength = headerEndIndex + contentLength
        guard buffer.count >= totalMessageLength else {
            return nil // Body not complete yet
        }

        let bodyData = buffer.subdata(in: headerEndIndex..<totalMessageLength)
        let removeCount = min(totalMessageLength, buffer.count) // Safe removal count
        buffer.removeFirst(removeCount)

        return String(data: bodyData, encoding: .utf8)
    }

    /// Format response data for test transport using locked framing
    private func formatTestResponse(_ responseJSON: String) async -> Data {
        guard let mode = framingMode else {
            // Fallback to newline
            return Data((responseJSON + "\n").utf8)
        }

        switch mode {
        case .newline:
            return Data((responseJSON + "\n").utf8)
        case .lsp:
            let contentLength = responseJSON.utf8.count
            let response = "Content-Length: \(contentLength)\r\n\r\n\(responseJSON)"
            return Data(response.utf8)
        }
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
        // Emitted through `MCPToolDescriptor` rather than an inline dict
        // literal so this server's outbound shape IS the shape clients
        // decode with (`MCPToolDescriptor.list(fromToolsListResult:)`).
        // Byte-identical to the previous literal — same three keys, same
        // name-sorted order.
        return JSONRPCResponse(
            id: request.id,
            result: MCPToolDescriptor.toolsListResult(descriptors())
        )
    }

    /// Every registered tool's advertisement, name-sorted. Exposed
    /// separately from the JSON-RPC handler so callers that aggregate or
    /// filter this server's catalogue (a gateway, a test) can read it
    /// without building a request.
    public func descriptors() -> [MCPToolDescriptor] {
        tools.values
            .sorted { $0.name < $1.name }
            .map(\.descriptor)
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
