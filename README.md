# SwiftMCP

Reusable MCP-server SDK for Swift. Extracted from ShikkiMCP's battle-tested JSON-RPC + dispatch machinery. Used by ShikkiMCP, shikki-xcode-tools-swift-port, and shi-discovery MCP.

## Architecture decision

An official Swift SDK exists at https://github.com/modelcontextprotocol/swift-sdk (discovered 2026-05-10). SwiftMCP is self-contained because:

1. **Wire-format compat**: ShikkiMCP uses `protocolVersion: "2024-11-05"`. The official SDK targets `"2025-11-25"`. SwiftMCP keeps the existing protocol version to avoid breaking Claude Desktop's existing config.
2. **Zero external deps**: Only `swift-log`. No NIO, no vapor, no heavyweight runtime.
3. **Opinionated `MCPTool` protocol**: ShikkiMCP proved that a concrete `MCPTool` protocol (name + description + schema + handler) is the right abstraction for this monorepo. The official SDK has a different shape.

When `modelcontextprotocol/swift-sdk` reaches protocol parity and the shikki ecosystem migrates to `2025-11-25`, SwiftMCP can be deprecated in favour of the official SDK. Until then, SwiftMCP is the foundation.

## Targets

| Target | Role |
|--------|------|
| `SwiftMCPCore` | JSON-RPC envelope types, `MCPTool` protocol, `JSONValue`, `MCPContext`, `MCPTransport`, `ToolResultBuilder` |
| `SwiftMCPServer` | `MCPServer` actor — stdio transport, tool registry, dispatch, robustness |
| `SwiftMCPTesting` | `MCPTestHarness`, `withTimeout`, fixture helpers for unit tests |

## Usage

```swift
// Package.swift dependency
.package(path: "../SwiftMCP")  // local sibling
// or via URL when published

// Target dependency
.product(name: "SwiftMCPServer", package: "SwiftMCP")
```

### 1. Define a tool

```swift
import SwiftMCPCore

struct SaveNoteTool: MCPTool {
    static let name = "save_note"
    static let description = "Save a note to persistent storage"
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("content")]),
        "properties": .object([
            "content": .object([
                "type": .string("string"),
                "description": .string("The note content"),
            ]),
        ]),
    ])

    let store: NoteStore  // injected at registration time

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        guard let content = params?.objectValue?["content"]?.stringValue else {
            return ToolResultBuilder.error("Missing required field: content")
        }
        try await store.save(content)
        return ToolResultBuilder.success("Note saved")
    }
}
```

### 2. Register and run

```swift
import SwiftMCPServer

@main
struct MyMCPServer {
    static func main() async {
        let server = MCPServer(name: "my-mcp", version: "1.0.0")
        let store = NoteStore()
        try! await server.register(SaveNoteTool(store: store))
        await server.run(transport: .stdio)
    }
}
```

### 3. Transport options

| Transport | Description | Status |
|-----------|-------------|--------|
| `.stdio` | Standard in/out — production default for Claude Desktop | Shipped |
| `.unixSocket(path:)` | Unix domain socket — planned for shi-discovery | Planned |
| `.test(input:output:)` | AsyncStream pair for unit tests | Shipped |

## Robustness contract

These scenarios are handled by `MCPServer` (not just documented):

1. **Malformed JSON** → logged to stderr, loop continues (no exit)
2. **Stdin EOF / pipe close** → clean exit within ~100ms
3. **Tool handler throws** → caught, emitted as JSON-RPC error (`-32603`), server stays alive
4. **Cancellation** → Task cancellation on stdin close propagates to in-flight calls
5. **Structured logging** → swift-log, label `swiftmcp.<server-name>`, stderr only

## JSON Schema approach

`MCPTool.inputSchema` is a `JSONValue` literal (manual dict). Codable-based auto-generation was considered and deferred — it would require ~20% additional code for marginal benefit, and the existing ShikkiMCP tools already use the manual approach. Override `inputSchema` in your conformance as needed.

## Wire format

Responses use `JSONEncoder.outputFormatting = [.sortedKeys]` for deterministic output. Protocol version `"2024-11-05"` (configurable in `MCPServer.init`).

## Kagami scope

Tests run via:
```
kagami test --scope swift-mcp
```

Scope registered in `packages/ShikkiTestRunner/Sources/ShikkiTestRunner/Core/ScopeManifest.swift`. `packagePath: "packages/SwiftMCP"` so kagami cd-s into the package before running.
