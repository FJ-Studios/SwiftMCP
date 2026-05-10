import Testing
import Foundation
@testable import SwiftMCPCore
@testable import SwiftMCPServer
import SwiftMCPTesting

// MARK: - Robustness Battery (Wave B scenarios)

@Suite("MCPServer Robustness")
struct RobustnessTests {

    // MARK: - 1. Malformed JSON → log + continue (no crash, no exit)

    @Test("Malformed JSON returns parse error, server stays alive")
    func malformedJSONSurvives() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")
        // First: malformed message
        let badResponse = await server.handleMessage("not-valid-json{{{")
        #expect(badResponse != nil, "Malformed JSON should produce a parse-error response (not nil)")
        if let resp = badResponse,
           let data = resp.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
            #expect(decoded.error?.code == MCPError.parseError)
        }
        // Server must still respond to subsequent valid messages
        let toolsListMsg = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":null}"#
        let goodResponse = await server.handleMessage(toolsListMsg)
        #expect(goodResponse != nil, "Server must still respond after malformed input")
    }

    // MARK: - 2. Tool-handler throws → JSON-RPC error emitted, server alive

    @Test("Tool handler throw produces error response, server stays alive")
    func toolHandlerThrowProducesError() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")
        try await server.register(ThrowingTool())

        let callMsg = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"always_throws","arguments":{}}}"#
        let responseStr = await server.handleMessage(callMsg)

        guard let responseStr else {
            Issue.record("Expected error response, got nil")
            return
        }
        guard let data = responseStr.data(using: .utf8),
              let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) else {
            Issue.record("Could not decode response: \(responseStr)")
            return
        }
        #expect(response.error != nil, "Tool throw must produce JSON-RPC error")
        #expect(response.error?.code == MCPError.internalError)

        // Server must still respond after tool throw
        let listMsg = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":null}"#
        let listResponse = await server.handleMessage(listMsg)
        #expect(listResponse != nil, "Server must stay alive after tool throw")
    }

    // MARK: - 3. Notification → nil response (no response on wire)

    @Test("notifications/initialized returns nil (no response on wire)")
    func notificationReturnsNil() async {
        let server = MCPServer(name: "test", version: "0.0.1")
        let notifMsg = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let response = await server.handleMessage(notifMsg)
        #expect(response == nil, "Notifications must not produce a response")
    }

    @Test("Bare initialized notification (no id) returns nil")
    func bareInitializedNotificationReturnsNil() async {
        let server = MCPServer(name: "test", version: "0.0.1")
        let msg = #"{"jsonrpc":"2.0","method":"initialized"}"#
        let response = await server.handleMessage(msg)
        #expect(response == nil)
    }

    // MARK: - 4. Unknown method → methodNotFound error

    @Test("Unknown method returns methodNotFound error")
    func unknownMethodError() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")
        let msg = #"{"jsonrpc":"2.0","id":1,"method":"foo/bar","params":null}"#
        let responseStr = await server.handleMessage(msg)

        guard let responseStr,
              let data = responseStr.data(using: .utf8),
              let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) else {
            Issue.record("Could not decode response")
            return
        }
        #expect(response.error?.code == MCPError.methodNotFound)
    }

    // MARK: - 5. Duplicate tool registration throws

    @Test("Duplicate tool registration throws")
    func duplicateToolRegistrationThrows() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")
        try await server.register(EchoTool())
        // Swift 6: must await registration; wrap second call in async closure
        var caught = false
        do {
            try await server.register(EchoTool())
        } catch is RegistrationError {
            caught = true
        }
        #expect(caught, "Second registration of same tool name must throw RegistrationError")
    }

    // MARK: - 6. Initialize response matches protocolVersion

    @Test("Initialize response has correct protocolVersion")
    func initializeProtocolVersion() async throws {
        let server = MCPServer(name: "test-server", version: "1.0.0", protocolVersion: "2024-11-05")
        let msg = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.0.1"}}}"#
        let responseStr = await server.handleMessage(msg)

        guard let responseStr,
              let data = responseStr.data(using: .utf8),
              let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) else {
            Issue.record("Could not decode initialize response")
            return
        }
        #expect(response.error == nil)
        #expect(response.result?["protocolVersion"] == .string("2024-11-05"))
        #expect(response.result?["serverInfo"]?["name"] == .string("test-server"))
    }

    // MARK: - 7. Concurrent tool calls (race detector)

    @Test("100 concurrent tool calls produce no races")
    func concurrentToolCalls() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")
        try await server.register(EchoTool())

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let msg = """
                    {"jsonrpc":"2.0","id":\(i),"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello-\(i)"}}}
                    """
                    let resp = await server.handleMessage(msg)
                    return resp != nil
                }
            }
            var successes = 0
            for await ok in group {
                if ok { successes += 1 }
            }
            #expect(successes == 100)
        }
    }
}

// MARK: - Test fixtures

/// A tool that always throws — used to test Wave B error handling.
struct ThrowingTool: MCPTool {
    static let name = "always_throws"
    static let description = "Always throws an error"
    static let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    struct ToolError: Error { let message: String }

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        throw ToolError(message: "Intentional test error")
    }
}

/// A simple echo tool — used in concurrency tests.
struct EchoTool: MCPTool {
    static let name = "echo"
    static let description = "Echoes the message param"
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")]),
        ]),
    ])

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        let msg = params?.objectValue?["message"]?.stringValue ?? "(empty)"
        return ToolResultBuilder.success("echo: \(msg)")
    }
}
