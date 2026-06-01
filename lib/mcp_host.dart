/// Kernel sub-barrel for the reference MCP host adapters.
///
/// Hosts that want a `mcp_server` + `mcp_client` backed surface import
/// this barrel in addition to `package:brain_kernel/brain_kernel.dart`.
/// The main barrel exposes only the [KernelServerHost] /
/// [KernelClientHost] abstracts; this barrel surfaces the reference
/// impls (`ServerBootstrap` aka `McpServerKernelHost`,
/// `McpClientKernelHost`) plus the raw `mcp_server` / `mcp_client`
/// types so hosts can reach out to wire-shape APIs (custom prompts,
/// resource subscriptions, OAuth, etc).
///
/// Usage:
///
/// ```dart
/// import 'package:brain_kernel/brain_kernel.dart';
/// import 'package:brain_kernel/mcp_host.dart';
///
/// final app = await KernelApp.boot(
///   workspaceId: 'studio',
///   kvStorage: kv,
///   serverHostFactory: ServerBootstrap.factory,  // MCP server-backed
///   clientHost: McpClientKernelHost(),           // outbound calls
/// );
/// ```
///
/// Hosts that never expose a server transport omit `serverHostFactory`
/// (kernel falls back to in-process). Hosts that never make outbound
/// calls omit `clientHost`.
library;

// Reference impl wrapping `mcp.Server` + transports.
export 'src/infra/server/server_bootstrap.dart';
// Reference impl wrapping `mcp_client.Client` + transports.
export 'src/system/host/mcp/mcp_client_kernel_host.dart';

// Re-export the wire packages so hosts that import this sub-barrel get
// the raw `mcp.*` types in one place. Conflict policy mirrors the main
// barrel (kernel's own ValidationIssue stays primary, etc.).
export 'package:mcp_server/mcp_server.dart';
export 'package:mcp_client/mcp_client.dart'
    show
        Client,
        StdioClientTransport,
        SseClientTransport,
        StreamableHttpClientTransport;
