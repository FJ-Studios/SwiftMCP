import Foundation
import Testing

@testable import SwiftMCPCore
@testable import SwiftMCPServer

// MARK: - Fixtures

private struct AlphaTool: MCPTool {
    static let name = "alpha"
    static let description = "First tool"
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["n": .object(["type": .string("integer")])]),
    ])

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        ToolResultBuilder.success("alpha")
    }
}

private struct ZuluTool: MCPTool {
    static let name = "zulu"
    static let description = "Last tool"
    static let inputSchema: JSONValue = MCPToolDescriptor.emptyObjectSchema

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        ToolResultBuilder.success("zulu")
    }
}

/// `handleToolsList` was rewritten to emit through `MCPToolDescriptor`
/// instead of an inline dictionary literal. These tests pin the wire
/// shape so that refactor is provably byte-compatible — a silent change
/// to `tools/list` would break every already-shipped client.
@Suite("tools/list wire shape")
struct ToolsListWireShapeTests {

    private func makeServer() async throws -> MCPServer {
        let server = MCPServer(name: "test", version: "0.0.1")
        // Registered out of alphabetical order on purpose: the response
        // must still come back name-sorted.
        try await server.register(ZuluTool())
        try await server.register(AlphaTool())
        return server
    }

    @Test("Response carries exactly the three documented keys per tool")
    func wireKeysUnchanged() async throws {
        let server = try await makeServer()
        let raw = await server.handleMessage(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        )

        let data = try #require(raw?.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        let tools = try #require(response.result?["tools"]?.arrayValue)

        #expect(tools.count == 2)
        for tool in tools {
            let object = try #require(tool.objectValue)
            #expect(Set(object.keys) == ["name", "description", "inputSchema"])
        }
    }

    @Test("Tools stay name-sorted regardless of registration order")
    func sortOrderUnchanged() async throws {
        let server = try await makeServer()
        let raw = await server.handleMessage(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        )

        let data = try #require(raw?.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        let tools = try #require(response.result?["tools"]?.arrayValue)

        #expect(tools.compactMap { $0["name"]?.stringValue } == ["alpha", "zulu"])
    }

    @Test("The emitted payload decodes back through the client-side reader")
    func serverOutputDecodesWithClientReader() async throws {
        // The point of the shared type: what this server emits is what a
        // client decodes, without either side hand-rolling a dictionary.
        let server = try await makeServer()
        let raw = await server.handleMessage(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        )

        let data = try #require(raw?.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        let result = try #require(response.result)

        let decoded = MCPToolDescriptor.list(fromToolsListResult: result)

        #expect(decoded == [MCPToolDescriptor(AlphaTool.self), MCPToolDescriptor(ZuluTool.self)])
    }

    @Test("descriptors() matches what the JSON-RPC handler advertises")
    func descriptorsMatchHandler() async throws {
        let server = try await makeServer()

        let direct = await server.descriptors()

        let raw = await server.handleMessage(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        )
        let data = try #require(raw?.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        let viaWire = MCPToolDescriptor.list(fromToolsListResult: try #require(response.result))

        #expect(direct == viaWire)
    }

    @Test("A server with no tools advertises an empty array, not a missing key")
    func emptyServerStillEmitsToolsKey() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")
        let raw = await server.handleMessage(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        )

        let data = try #require(raw?.data(using: .utf8))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)

        #expect(response.result?["tools"]?.arrayValue == [])
    }
}
