/// MOD-SYSTEM-HOST-005 — McpServerSpec.
///
/// External endpoint description that downstream consumers (CLI
/// providers, sibling hosts, debug tooling) need in order to dial back
/// into a `KernelServerHost`'s MCP surface. Models the connection
/// shape the way Claude Code's `--mcp-config` and the MCP server
/// catalog spec describe it (`mcpServers` map entry), so a host can
/// expose its own server identity and a recipe / sibling host can
/// turn that into a working transport without re-encoding wire
/// details.
///
/// Hosts that never expose an external transport (in-process default)
/// publish `null` from `KernelApp.hostMcpServerSpec`. Hosts that bind
/// a transport surface this spec so per-agent scoping (see
/// `specs/platform/10-agent-scoping.md`) carries through the mode A
/// path (Claude Code CLI absorbing the host catalog via mcp-config).
library;

enum McpServerTransport {
  /// `stdio` — the consumer launches `command` + `args` as a child
  /// process and speaks JSON-RPC over its stdin / stdout.
  stdio,

  /// Streamable HTTP — the consumer POSTs JSON-RPC envelopes to [url].
  http,

  /// Server-Sent Events — legacy MCP transport reading SSE from [url].
  sse,
}

class McpServerSpec {
  const McpServerSpec({
    required this.name,
    required this.transport,
    this.command,
    this.args = const <String>[],
    this.url,
    this.headers = const <String, String>{},
    this.env = const <String, String>{},
  });

  /// Logical name. Becomes the key under `mcpServers` in the
  /// generated `--mcp-config` file.
  final String name;

  final McpServerTransport transport;

  /// Process command (stdio transport). Ignored for HTTP / SSE.
  final String? command;

  /// Process args (stdio transport). Ignored for HTTP / SSE.
  final List<String> args;

  /// Endpoint URL (HTTP / SSE transport). Ignored for stdio.
  final String? url;

  /// Auth / context headers attached to the HTTP / SSE request.
  final Map<String, String> headers;

  /// Environment overrides handed to the child process (stdio
  /// transport).
  final Map<String, String> env;

  /// Render as a single `mcpServers` map entry suitable for
  /// `--mcp-config` consumption.
  Map<String, dynamic> toMcpConfigEntry() {
    switch (transport) {
      case McpServerTransport.stdio:
        return <String, dynamic>{
          if (command != null) 'command': command,
          if (args.isNotEmpty) 'args': args,
          if (env.isNotEmpty) 'env': env,
        };
      case McpServerTransport.http:
      case McpServerTransport.sse:
        return <String, dynamic>{
          'type': transport == McpServerTransport.http ? 'http' : 'sse',
          if (url != null) 'url': url,
          if (headers.isNotEmpty) 'headers': headers,
        };
    }
  }

  /// Render the full `mcpServers` block holding only this entry.
  Map<String, dynamic> toMcpServersBlock() => <String, dynamic>{
        'mcpServers': <String, dynamic>{name: toMcpConfigEntry()},
      };
}
