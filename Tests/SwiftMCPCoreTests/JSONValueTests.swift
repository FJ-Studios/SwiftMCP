import Testing
import Foundation
@testable import SwiftMCPCore

// MARK: - JSONValue round-trip tests

@Suite("JSONValue")
struct JSONValueTests {

    @Test("String round-trip")
    func stringRoundTrip() throws {
        let value = JSONValue.string("hello")
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Int round-trip")
    func intRoundTrip() throws {
        let value = JSONValue.int(42)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Bool round-trip")
    func boolRoundTrip() throws {
        let value = JSONValue.bool(true)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Null round-trip")
    func nullRoundTrip() throws {
        let value = JSONValue.null
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Object round-trip")
    func objectRoundTrip() throws {
        let value = JSONValue.object(["key": .string("value"), "num": .int(1)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Array round-trip")
    func arrayRoundTrip() throws {
        let value = JSONValue.array([.string("a"), .int(2), .bool(false)])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test("Subscript access")
    func subscriptAccess() {
        let obj = JSONValue.object(["name": .string("test")])
        #expect(obj["name"] == .string("test"))
        #expect(obj["missing"] == nil)
    }
}

// MARK: - JSONRPCId tests

@Suite("JSONRPCId")
struct JSONRPCIdTests {

    @Test("Int id round-trip")
    func intId() throws {
        let id = JSONRPCId.int(1)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JSONRPCId.self, from: data)
        #expect(decoded == id)
    }

    @Test("String id round-trip")
    func stringId() throws {
        let id = JSONRPCId.string("abc-123")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(JSONRPCId.self, from: data)
        #expect(decoded == id)
    }
}

// MARK: - MCPError tests

@Suite("MCPError")
struct MCPErrorTests {

    @Test("Error codes match JSON-RPC spec")
    func errorCodes() {
        #expect(MCPError.parseError == -32700)
        #expect(MCPError.invalidRequest == -32600)
        #expect(MCPError.methodNotFound == -32601)
        #expect(MCPError.invalidParams == -32602)
        #expect(MCPError.internalError == -32603)
    }

    @Test("MCPError round-trip")
    func errorRoundTrip() throws {
        let err = MCPError(code: -32700, message: "Parse error", data: nil)
        let data = try JSONEncoder().encode(err)
        let decoded = try JSONDecoder().decode(MCPError.self, from: data)
        #expect(decoded.code == err.code)
        #expect(decoded.message == err.message)
    }
}

// MARK: - ToolResultBuilder tests

@Suite("ToolResultBuilder")
struct ToolResultBuilderTests {

    @Test("Success result has content array")
    func successHasContent() {
        let result = ToolResultBuilder.success("it worked")
        guard let content = result["content"]?.arrayValue else {
            Issue.record("Missing content array")
            return
        }
        #expect(content.count == 1)
        #expect(content[0]["type"] == .string("text"))
        #expect(content[0]["text"] == .string("it worked"))
    }

    @Test("Error result has isError=true")
    func errorHasFlag() {
        let result = ToolResultBuilder.error("something broke")
        #expect(result["isError"] == .bool(true))
    }

    @Test("Success result has no isError key")
    func successHasNoIsError() {
        let result = ToolResultBuilder.success("ok")
        #expect(result["isError"] == nil)
    }
}
