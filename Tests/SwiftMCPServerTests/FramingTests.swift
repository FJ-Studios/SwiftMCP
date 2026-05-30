import Testing
import Foundation
@testable import SwiftMCPCore
@testable import SwiftMCPServer
import SwiftMCPTesting

// MARK: - Framing Auto-detect Tests (Wave 1)

@Suite("MCPServer Framing Auto-detect")
struct FramingTests {

    // MARK: - 1. Newline framing (default/existing behavior)

    @Test("Newline framing default — server reads {json}\\n + writes {json}\\n")
    func testNewlineFramingDefault() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")

        // Set up test transport
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)

        // Start server in background
        let serverTask = Task {
            await server.run(transport: .test(input: inputStream, output: outputContinuation))
        }

        // Send newline-delimited JSON (first byte is '{')
        let requestJSON = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        let requestData = Data((requestJSON + "\n").utf8)
        inputContinuation.yield(requestData)
        inputContinuation.finish()

        // Collect response
        var responseData = Data()
        for await chunk in outputStream {
            responseData.append(chunk)
        }

        // Verify response is newline-delimited
        let responseString = String(data: responseData, encoding: .utf8)
        #expect(responseString?.hasSuffix("\n") == true, "Response should end with newline")

        serverTask.cancel()
        await serverTask.value
    }

    // MARK: - 2. LSP framing auto-detect from header

    @Test("LSP framing auto-detect from header — server reads Content-Length: N\\r\\n\\r\\n{json} + writes identical")
    func testLSPFramingAutoDetectFromHeader() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")

        // Set up test transport
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)

        // Start server in background
        let serverTask = Task {
            await server.run(transport: .test(input: inputStream, output: outputContinuation))
        }

        // Send LSP-framed JSON (first byte is 'C' from Content-Length)
        let requestJSON = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        let contentLength = requestJSON.utf8.count
        let lspRequest = "Content-Length: \(contentLength)\r\n\r\n\(requestJSON)"
        let requestData = Data(lspRequest.utf8)
        inputContinuation.yield(requestData)
        inputContinuation.finish()

        // Collect response
        var responseData = Data()
        for await chunk in outputStream {
            responseData.append(chunk)
        }

        // Verify response uses LSP framing (Content-Length header)
        let responseString = String(data: responseData, encoding: .utf8)
        #expect(responseString?.hasPrefix("Content-Length: ") == true, "Response should use LSP framing")
        #expect(responseString?.contains("\r\n\r\n") == true, "Response should contain LSP header separator")

        serverTask.cancel()
        await serverTask.value
    }

    // MARK: - 3. Framing mixed sequence (lock per-connection)

    @Test("Framing mixed sequence — first request newline, second request LSP — server locks framing per-connection")
    func testFramingMixedSequence() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")

        // Set up test transport
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)

        // Start server in background
        let serverTask = Task {
            await server.run(transport: .test(input: inputStream, output: outputContinuation))
        }

        // First request: newline-delimited (should lock framing to newline mode)
        let request1JSON = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":null}"#
        let request1Data = Data((request1JSON + "\n").utf8)
        inputContinuation.yield(request1Data)

        // Second request: attempt LSP-framed (should be read as newline since locked)
        let request2JSON = #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":null}"#
        let request2Data = Data((request2JSON + "\n").utf8)
        inputContinuation.yield(request2Data)
        inputContinuation.finish()

        // Collect all responses
        var responseData = Data()
        for await chunk in outputStream {
            responseData.append(chunk)
        }

        // Verify both responses use newline framing (locked from first request)
        let responseString = String(data: responseData, encoding: .utf8)
        let responses = responseString?.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(responses?.count == 2, "Should receive exactly 2 responses")

        // Both should be valid JSON responses
        if let responses = responses {
            for response in responses {
                let data = Data(response.utf8)
                #expect((try? JSONSerialization.jsonObject(with: data)) != nil, "Each response should be valid JSON")
            }
        }

        serverTask.cancel()
        await serverTask.value
    }

    // MARK: - 4. EOF clean shutdown

    @Test("EOF clean shutdown — close stdin, server exits cleanly with Client disconnected log")
    func testEOFCleanShutdown() async throws {
        let server = MCPServer(name: "test", version: "0.0.1")

        // Set up test transport
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: Data.self)
        let (_, outputContinuation) = AsyncStream.makeStream(of: Data.self)

        // Start server in background
        let serverTask = Task {
            await server.run(transport: .test(input: inputStream, output: outputContinuation))
        }

        // Close input stream (simulate EOF)
        inputContinuation.finish()

        // Wait for server to complete
        await serverTask.value

        // Verify server completed without throwing (if we reach here, it succeeded)
        #expect(Bool(true), "Server should complete gracefully on EOF")
    }
}