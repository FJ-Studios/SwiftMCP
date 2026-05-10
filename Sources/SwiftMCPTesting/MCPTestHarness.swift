import Foundation
import SwiftMCPCore
import SwiftMCPServer

// MARK: - MCPTestHarness

/// Test helper for exercising MCPServer without real stdin/stdout.
///
/// Usage:
/// ```swift
/// let server = MCPServer(name: "test-server", version: "0.0.1")
/// try server.register(MyTool())
/// let response = try await MCPTestHarness.call(
///     server: server,
///     message: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
/// )
/// ```
public enum MCPTestHarness {

    // MARK: - Single message call

    /// Send a single raw JSON-RPC message to the server and return the response string.
    /// Returns nil for notifications (server correctly produces no response).
    public static func call(server: MCPServer, message: String) async -> String? {
        await server.handleMessage(message)
    }

    // MARK: - Initialize handshake

    /// Perform the standard MCP initialize + notifications/initialized handshake.
    /// Returns the initialize response for assertion.
    @discardableResult
    public static func performHandshake(server: MCPServer, requestId: Int = 0) async throws -> MCPInitializeResult {
        let initMsg = """
        {"jsonrpc":"2.0","id":\(requestId),"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"0.0.1"}}}
        """
        guard let responseStr = await server.handleMessage(initMsg) else {
            throw MCPTestError.unexpectedNilResponse(for: "initialize")
        }
        guard let responseData = responseStr.data(using: .utf8) else {
            throw MCPTestError.invalidUTF8Response
        }
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        guard response.error == nil else {
            throw MCPTestError.serverError(response.error!)
        }
        guard let result = response.result else {
            throw MCPTestError.missingResult
        }

        // Send notifications/initialized (no response expected)
        let notif = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        _ = await server.handleMessage(notif)  // should return nil

        guard let version = result["protocolVersion"]?.stringValue,
              let serverInfo = result["serverInfo"]?.objectValue,
              let name = serverInfo["name"]?.stringValue else {
            throw MCPTestError.malformedResult("Missing protocolVersion or serverInfo")
        }
        return MCPInitializeResult(protocolVersion: version, serverName: name)
    }

    // MARK: - Tool call helper

    /// Call a tool and decode the response.
    public static func callTool(
        server: MCPServer,
        toolName: String,
        arguments: [String: JSONValue] = [:],
        requestId: Int = 1
    ) async throws -> JSONValue {
        let argsJSON: String
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let argsValue = JSONValue.object(arguments)
        guard let argsData = try? encoder.encode(argsValue),
              let argsStr = String(data: argsData, encoding: .utf8) else {
            throw MCPTestError.malformedResult("Cannot encode arguments")
        }
        argsJSON = argsStr

        let message = """
        {"jsonrpc":"2.0","id":\(requestId),"method":"tools/call","params":{"name":"\(toolName)","arguments":\(argsJSON)}}
        """
        guard let responseStr = await server.handleMessage(message) else {
            throw MCPTestError.unexpectedNilResponse(for: "tools/call")
        }
        guard let responseData = responseStr.data(using: .utf8) else {
            throw MCPTestError.invalidUTF8Response
        }
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        if let err = response.error {
            throw MCPTestError.serverError(err)
        }
        guard let result = response.result else {
            throw MCPTestError.missingResult
        }
        return result
    }

    // MARK: - Fixture loader

    /// Load a JSON fixture from the test bundle. Returns nil if not found.
    public static func loadFixture(named name: String, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - MCPInitializeResult

public struct MCPInitializeResult: Sendable {
    public let protocolVersion: String
    public let serverName: String
}

// MARK: - Errors

public enum MCPTestError: Error, Sendable {
    case unexpectedNilResponse(for: String)
    case invalidUTF8Response
    case serverError(MCPError)
    case missingResult
    case malformedResult(String)
}

// MARK: - Timeout assertion helper

/// Assert that an async block completes within `timeout` seconds.
/// Throws `TimeoutError` if it does not.
public func withTimeout<T: Sendable>(
    _ timeout: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw TimeoutError(seconds: timeout)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

public struct TimeoutError: Error, Sendable {
    public let seconds: TimeInterval
}
