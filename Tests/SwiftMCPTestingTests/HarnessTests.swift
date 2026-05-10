import Testing
import Foundation
@testable import SwiftMCPCore
@testable import SwiftMCPServer
import SwiftMCPTesting

// MARK: - MCPTestHarness meta-tests (Wave D §3 — test the test helpers)

@Suite("MCPTestHarness")
struct HarnessTests {

    @Test("performHandshake completes successfully")
    func handshakeCompletes() async throws {
        let server = MCPServer(name: "harness-test", version: "0.0.1")
        let result = try await MCPTestHarness.performHandshake(server: server)
        #expect(result.protocolVersion == "2024-11-05")
        #expect(result.serverName == "harness-test")
    }

    @Test("callTool returns result for registered tool")
    func callToolReturnResult() async throws {
        let server = MCPServer(name: "harness-test", version: "0.0.1")
        try await server.register(EchoToolH())

        let result = try await MCPTestHarness.callTool(
            server: server,
            toolName: "echo_h",
            arguments: ["message": .string("ping")]
        )
        guard let content = result["content"]?.arrayValue?.first,
              let text = content["text"]?.stringValue else {
            Issue.record("Expected text content in result")
            return
        }
        #expect(text.contains("ping"))
    }

    @Test("callTool throws for unknown tool")
    func callToolThrowsForUnknown() async throws {
        let server = MCPServer(name: "harness-test", version: "0.0.1")
        await #expect(throws: MCPTestError.self) {
            _ = try await MCPTestHarness.callTool(server: server, toolName: "no_such_tool")
        }
    }

    @Test("withTimeout succeeds when operation is fast")
    func timeoutSucceeds() async throws {
        let result = try await withTimeout(2.0) {
            "done"
        }
        #expect(result == "done")
    }

    @Test("withTimeout throws TimeoutError when operation is slow")
    func timeoutThrows() async {
        await #expect(throws: TimeoutError.self) {
            _ = try await withTimeout(0.05) {
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1s > 0.05s timeout
                return "never"
            }
        }
    }
}

// MARK: - Fixture tool for harness tests

struct EchoToolH: MCPTool {
    static let name = "echo_h"
    static let description = "Echo tool for harness meta-tests"
    static let inputSchema: JSONValue = .object(["type": .string("object"), "properties": .object([:])])

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        let msg = params?.objectValue?["message"]?.stringValue ?? ""
        return ToolResultBuilder.success("echo: \(msg)")
    }
}
