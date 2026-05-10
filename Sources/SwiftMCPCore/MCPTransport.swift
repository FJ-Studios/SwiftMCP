import Foundation

// MARK: - MCPTransport

/// Transport strategy for MCPServer.
///
/// - `stdio`: Standard in/out pipe — the production transport for all shikki MCPs.
///   Claude Desktop / claude CLI connects via stdio.
/// - `unixSocket(path:)`: Unix domain socket — planned for shi-discovery MCP (lower latency
///   for intra-machine calls). Not implemented in Wave A; placeholder so the API surface
///   is stable when shi-discovery picks SwiftMCP up.
/// - `test(...)`: Injected AsyncStream pair for unit tests. Used by SwiftMCPTesting helpers.
///
/// Wave A ships `stdio` only. `unixSocket` and `test` are API placeholders whose
/// implementations are filled in Wave B (`test`) and a future wave (`unixSocket`).
public enum MCPTransport: Sendable {
    /// Standard in/out — the common production case.
    case stdio

    /// Unix domain socket at the given path — future use for shi-discovery.
    case unixSocket(path: String)

    /// Test-only: inject pre-canned AsyncStream<Data> pairs.
    /// Read from `input`, write to `output`.
    case test(input: AsyncStream<Data>, output: AsyncStream<Data>.Continuation)
}
