/// Kernel sub-barrel for outbound MCP client usage.
///
/// `mcp_client` is exposed through a dedicated entry point (rather than
/// the main `brain_kernel.dart` barrel) because its model classes
/// — `Content` / `TextContent` / `ImageContent` / `CallToolResult` /
/// transport configs — collide pervasively with `mcp_server`'s
/// same-named classes. Rolling them into the main barrel forces every
/// domain consumer to disambiguate. Splitting the surfaces keeps the
/// main barrel clean for the typical builder usage (server-side MCP +
/// bundle + LLM) while still letting tools that genuinely need
/// outbound clients (inspector probes, cross-server wiring) reach the
/// types through the kernel.
///
/// Usage:
///
/// ```dart
/// import 'package:brain_kernel/mcp_client.dart';
///
/// final result = await McpClient.createAndConnect(
///   config: const McpClientConfig(...),
/// );
/// if (result.content.first is TextContent) { ... }
/// ```
///
/// Domain code that imports both `brain_kernel.dart` (for the
/// server / bundle types) and this file should use a prefix on one of
/// them to silence the expected collisions on `Content` / etc.
library;

export 'package:mcp_client/mcp_client.dart';
