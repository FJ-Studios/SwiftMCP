// swift-tools-version: 6.0

import PackageDescription

// NOTE: Official Swift MCP SDK exists at https://github.com/modelcontextprotocol/swift-sdk
// Decision: SwiftMCP is built self-contained (NOT depending on the official SDK) for two reasons:
//   1. Wire-format compatibility — ShikkiMCP uses protocolVersion "2024-11-05"; official SDK uses "2025-11-25"
//   2. Zero-dependency footprint — tools like shi-discovery benefit from a minimal runtime
// See packages/SwiftMCP/README.md for the full rationale.

let package = Package(
    name: "SwiftMCP",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "SwiftMCPCore", targets: ["SwiftMCPCore"]),
        .library(name: "SwiftMCPServer", targets: ["SwiftMCPServer"]),
        .library(name: "SwiftMCPTesting", targets: ["SwiftMCPTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        // MARK: - SwiftMCPCore
        // JSON-RPC envelope types, MCP protocol structs, MCPTool protocol,
        // JSONValue, JSONSchema (manual dict approach — Codable generation deferred).
        .target(
            name: "SwiftMCPCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - SwiftMCPServer
        // MCPServer actor: stdio transport + tool registry + dispatch + robustness.
        .target(
            name: "SwiftMCPServer",
            dependencies: [
                "SwiftMCPCore",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - SwiftMCPTesting
        // Test helpers: synthetic stdin/stdout pipes, fixture loaders, timeout assertions.
        .target(
            name: "SwiftMCPTesting",
            dependencies: [
                "SwiftMCPCore",
                "SwiftMCPServer",
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SwiftMCPCoreTests",
            dependencies: ["SwiftMCPCore"]
        ),
        .testTarget(
            name: "SwiftMCPServerTests",
            dependencies: [
                "SwiftMCPCore",
                "SwiftMCPServer",
                "SwiftMCPTesting",
            ]
        ),
        .testTarget(
            name: "SwiftMCPTestingTests",
            dependencies: [
                "SwiftMCPCore",
                "SwiftMCPServer",
                "SwiftMCPTesting",
            ]
        ),
    ]
)
