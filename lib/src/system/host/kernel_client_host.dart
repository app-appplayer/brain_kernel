/// `KernelClientHost` — abstract outbound MCP client surface used by
/// the kernel.
///
/// The kernel core does not directly drive client connections — that
/// is the host's job (AppPlayer's connection_manager, vibe_studio's
/// debug probes, the user's own driver code). This abstract exists so
/// adapters that *do* need to call outbound MCP servers (workflow
/// `api`-step tool dispatch, the bundle bridge's optional external
/// fan-out) can run library-agnostic.
///
/// Default impl `McpClientKernelHost` (in
/// `package:brain_kernel/mcp_host.dart`) wraps `mcp_client.Client` +
/// stdio / Streamable HTTP / SSE transports. Hosts that never make
/// outbound calls leave [KernelApp.boot] with no [KernelClientHost].
library;

import 'kernel_envelope.dart';

/// A configured outbound connection. Hosts surface one of these per
/// remote server the kernel has been pointed at.
abstract class KernelClientConnection {
  /// Host-assigned identifier (URL, label, etc).
  String get id;

  /// `true` when the underlying transport is currently attached.
  bool get isConnected;

  Future<KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  );

  Future<KernelReadResourceResult> readResource(String uri);

  Future<List<KernelToolDescriptor>> listTools();

  Future<List<KernelResourceDescriptor>> listResources();

  Future<void> close();
}

/// Tool descriptor returned by `tools/list` on a remote server.
class KernelToolDescriptor {
  const KernelToolDescriptor({
    required this.name,
    required this.description,
    this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic>? inputSchema;
}

/// Resource descriptor returned by `resources/list` on a remote server.
class KernelResourceDescriptor {
  const KernelResourceDescriptor({
    required this.uri,
    required this.name,
    this.description,
    this.mimeType,
  });

  final String uri;
  final String name;
  final String? description;
  final String? mimeType;
}

abstract class KernelClientHost {
  /// Open a connection to a remote MCP server. The connection is
  /// identified by [id] (host-assigned URL, label, or other handle).
  Future<KernelClientConnection> connect({
    required String id,
    required KernelTransportKind transport,
    String? endpoint,
    Map<String, dynamic>? options,
  });

  /// Currently open connections.
  Iterable<KernelClientConnection> get connections;

  /// Tear every connection down.
  Future<void> shutdown();
}
