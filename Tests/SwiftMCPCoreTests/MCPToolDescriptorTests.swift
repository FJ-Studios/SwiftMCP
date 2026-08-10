import Foundation
import Testing

@testable import SwiftMCPCore

// MARK: - Fixtures

/// A minimal executable tool, used to prove a descriptor can be derived
/// from the protocol side without instantiating a handler path.
private struct EchoTool: MCPTool {
    static let name = "echo"
    static let description = "Echoes its input back"
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "text": .object(["type": .string("string")])
        ]),
        "required": .array([.string("text")]),
    ])

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        ToolResultBuilder.success(params?["text"]?.stringValue ?? "")
    }
}

/// A tool that takes no arguments — exercises the empty-schema default.
private struct PingTool: MCPTool {
    static let name = "ping"
    static let description = ""
    static let inputSchema: JSONValue = MCPToolDescriptor.emptyObjectSchema

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        ToolResultBuilder.success("pong")
    }
}

@Suite("MCPToolDescriptor")
struct MCPToolDescriptorTests {

    // MARK: - Bridges from the executable side

    @Test("Describes a tool type without instantiating it")
    func fromToolType() {
        let descriptor = MCPToolDescriptor(EchoTool.self)

        #expect(descriptor.name == "echo")
        #expect(descriptor.description == "Echoes its input back")
        #expect(descriptor.inputSchema == EchoTool.inputSchema)
    }

    @Test("Describes a tool instance via its dynamic type")
    func fromToolInstance() {
        #expect(MCPToolDescriptor(EchoTool()) == MCPToolDescriptor(EchoTool.self))
    }

    @Test("Describes a type-erased registry entry, dropping the handler")
    func fromRegistryEntry() {
        let entry = MCPToolEntry(tool: EchoTool())

        #expect(entry.descriptor == MCPToolDescriptor(EchoTool.self))
        #expect(MCPToolDescriptor(entry) == entry.descriptor)
    }

    @Test("Identity is the wire name")
    func identity() {
        #expect(MCPToolDescriptor(EchoTool.self).id == "echo")
    }

    // MARK: - Wire encoding

    @Test("Emits exactly the three tools/list keys")
    func jsonValueShape() throws {
        let json = MCPToolDescriptor(EchoTool.self).jsonValue
        let object = try #require(json.objectValue)

        #expect(Set(object.keys) == ["name", "description", "inputSchema"])
        #expect(object["name"] == .string("echo"))
        #expect(object["description"] == .string("Echoes its input back"))
        #expect(object["inputSchema"] == EchoTool.inputSchema)
    }

    @Test("Round-trips through its own wire shape")
    func wireRoundTrip() throws {
        let original = MCPToolDescriptor(EchoTool.self)
        let decoded = try #require(MCPToolDescriptor(jsonValue: original.jsonValue))

        #expect(decoded == original)
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        let original = MCPToolDescriptor(EchoTool.self)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPToolDescriptor.self, from: data)

        #expect(decoded == original)
    }

    @Test("A descriptor off the wire equals one built locally — no re-serialisation")
    func wireAndLocalAreComparable() throws {
        // The reason inputSchema is a JSONValue and not a serialised
        // String: these two must be Equatable without a parse step.
        let local = MCPToolDescriptor(EchoTool.self)
        let fromWire = try #require(
            MCPToolDescriptor(
                jsonValue: .object([
                    "name": .string("echo"),
                    "description": .string("Echoes its input back"),
                    "inputSchema": EchoTool.inputSchema,
                ])
            )
        )

        #expect(fromWire == local)
    }

    // MARK: - Decoding tolerance

    @Test("A nameless entry does not decode — it could never be called")
    func namelessEntryRejected() {
        #expect(MCPToolDescriptor(jsonValue: .object(["description": .string("x")])) == nil)
        #expect(MCPToolDescriptor(jsonValue: .object(["name": .int(7)])) == nil)
        #expect(MCPToolDescriptor(jsonValue: .string("echo")) == nil)
    }

    @Test("Missing description and inputSchema take their documented defaults")
    func optionalFieldsDefault() throws {
        let decoded = try #require(
            MCPToolDescriptor(jsonValue: .object(["name": .string("bare")]))
        )

        #expect(decoded.description == "")
        #expect(decoded.inputSchema == MCPToolDescriptor.emptyObjectSchema)
    }

    @Test("A no-argument tool advertises the empty object schema, not null")
    func emptySchemaIsAnObject() {
        // MCP requires inputSchema to be present even with no arguments;
        // `.null` or an omitted key would be a protocol violation.
        let descriptor = MCPToolDescriptor(PingTool.self)

        #expect(descriptor.inputSchema == .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]))
    }

    // MARK: - tools/list batches

    @Test("Decodes a tools/list result and survives one malformed entry")
    func listSkipsMalformedEntries() {
        // One bad tool from a third-party server must not blind a client
        // to that server's other tools.
        let result: JSONValue = .object([
            "tools": .array([
                MCPToolDescriptor(EchoTool.self).jsonValue,
                .object(["description": .string("no name here")]),
                MCPToolDescriptor(PingTool.self).jsonValue,
            ])
        ])

        let decoded = MCPToolDescriptor.list(fromToolsListResult: result)

        #expect(decoded.count == 2)
        #expect(decoded.map(\.name) == ["echo", "ping"])
    }

    @Test("A result with no tools key decodes as empty, not a crash")
    func listMissingKey() {
        #expect(MCPToolDescriptor.list(fromToolsListResult: .object([:])).isEmpty)
        #expect(MCPToolDescriptor.list(fromToolsListResult: .null).isEmpty)
    }

    @Test("toolsListResult is the inverse of list(fromToolsListResult:)")
    func listRoundTrip() {
        let originals = [MCPToolDescriptor(EchoTool.self), MCPToolDescriptor(PingTool.self)]
        let round = MCPToolDescriptor.list(
            fromToolsListResult: MCPToolDescriptor.toolsListResult(originals)
        )

        #expect(round == originals)
    }
}
