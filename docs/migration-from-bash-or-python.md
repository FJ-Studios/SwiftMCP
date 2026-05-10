# Migration guide: Bash or Python MCP → SwiftMCP

This guide covers porting an existing Bash or Python MCP server to SwiftMCP. Written for `shikki-xcode-tools-swift-port` (the sister spec to `shikki-swift-mcp-sdk-extraction`), applicable to any future MCP consumer.

## Why migrate

The Python `shikki-xcode-mcp` (PR #279) introduced:
- Python venv + pip + pytest as a parallel runtime
- Bash subshell spawning for each tool call
- `python3` on PATH dependency
- No type safety on tool inputs/outputs

SwiftMCP replaces all of this with:
- A single Swift binary, no runtime deps
- Type-safe tool dispatch via `MCPTool` protocol
- swift-log structured logging (stderr, no stdout pollution)
- kagami test scope instead of pytest

## Step-by-step migration

### 1. Add SwiftMCP to Package.swift

```swift
dependencies: [
    .package(path: "../SwiftMCP"),  // local sibling in packages/
],
targets: [
    .executableTarget(
        name: "MyMCPServer",
        dependencies: [
            .product(name: "SwiftMCPServer", package: "SwiftMCP"),
        ]
    )
]
```

### 2. Convert each tool

For each tool in your Python/Bash server, create an `MCPTool` conformer:

**Python (before):**
```python
@app.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="xcode_build",
            description="Build an Xcode project",
            inputSchema={
                "type": "object",
                "required": ["project"],
                "properties": {
                    "project": {"type": "string"}
                }
            }
        )
    ]

@app.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if name == "xcode_build":
        project = arguments["project"]
        result = subprocess.run(["xcodebuild", "-project", project], capture_output=True)
        return [types.TextContent(type="text", text=result.stdout.decode())]
```

**SwiftMCP (after):**
```swift
import SwiftMCPCore

struct XcodeBuildTool: MCPTool {
    static let name = "xcode_build"
    static let description = "Build an Xcode project"
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "required": .array([.string("project")]),
        "properties": .object([
            "project": .object([
                "type": .string("string"),
                "description": .string("Path to .xcodeproj or .xcworkspace"),
            ]),
        ]),
    ])

    func handle(_ params: JSONValue?, context: MCPContext) async throws -> JSONValue {
        guard let project = params?.objectValue?["project"]?.stringValue else {
            return ToolResultBuilder.error("Missing required field: project")
        }
        // Use Process instead of subprocess
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = ["-project", project]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ToolResultBuilder.success(output)
    }
}
```

### 3. Wire up main.swift

```swift
import Foundation
import Logging
import SwiftMCPServer

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = .info
    return handler
}

let server = MCPServer(name: "xcode-tools", version: "1.0.0")
try await server.register(XcodeBuildTool())
try await server.register(SimulatorListTool())
// ... register all tools
await server.run(transport: .stdio)
```

### 4. Register kagami scope

In `packages/ShikkiTestRunner/Sources/ShikkiTestRunner/Core/ScopeManifest.swift`, add:

```swift
ScopeDefinition(
    name: "xcode-tools-swift",
    modulePatterns: ["XcodeToolsServer"],
    typePatterns: ["XcodeBuildTool", "SimulatorListTool"],
    testFilePatterns: ["**/XcodeTools*Tests.swift"],
    dependsOn: [],
    packagePath: "packages/XcodeToolsSwift"
),
```

### 5. Write tests

```swift
import Testing
import SwiftMCPTesting
@testable import SwiftMCPServer

@Suite("XcodeTools robustness")
struct XcodeToolsTests {
    @Test("Initialize handshake works")
    func handshake() async throws {
        let server = MCPServer(name: "xcode-tools", version: "1.0.0")
        try await server.register(XcodeBuildTool())
        let result = try await MCPTestHarness.performHandshake(server: server)
        #expect(result.serverName == "xcode-tools")
    }
}
```

### 6. Remove Python artifacts

Once the Swift port passes parity tests:

```bash
rm -rf Tests/MCPXcodeToolsTests/  # pytest suite
rm scripts/xcode-mcp-server.py    # Python server
rm requirements.txt               # pip deps
```

Update Claude Desktop config:
```json
{
  "mcpServers": {
    "xcode-tools": {
      "command": "/path/to/xcode-tools-swift",
      "args": []
    }
  }
}
```

## Wire format compat checklist

- [ ] `protocolVersion: "2024-11-05"` in initialize response
- [ ] `tools/list` returns same tool names (order may differ — `MCPServer` sorts alphabetically)
- [ ] `tools/call` result shape: `{ "content": [{ "type": "text", "text": "..." }] }`
- [ ] Error results: `{ "content": [...], "isError": true }` (tool-level error, not JSON-RPC error)
- [ ] Notifications return nil response (no wire output)

## Common pitfalls

**Tool ordering**: SwiftMCP sorts `tools/list` alphabetically by name. If a client assumes a specific order, it may notice the difference (though spec-compliant clients should not depend on order).

**Error shape**: Tool-level errors use `isError: true` in the result, NOT a JSON-RPC error code. JSON-RPC errors (`-32xxx`) are reserved for protocol-level failures (malformed JSON, unknown method, etc.).

**Actor isolation**: `MCPServer` is an actor. Call `await server.register(...)` (not `try server.register(...)`).
