/// Reference [KernelClientHost] impl on top of `package:mcp_client`.
///
/// Hosts that need outbound MCP calls (workflow `api`-step dispatch,
/// debug probes, cross-server fan-out) wire this through
/// `KernelApp.boot(clientHost: McpClientKernelHost())`. Hosts that
/// never call remote servers leave the parameter null.
library;

import 'package:mcp_client/mcp_client.dart' as cli;

import '../kernel_client_host.dart';
import '../kernel_envelope.dart';
import 'extension_transport_connect.dart';

class McpClientKernelHost
    implements KernelClientHost, ExtensionTransportConnect {
  McpClientKernelHost({
    this.name = 'brain_kernel',
    this.version = '0.1.0',
  });

  final String name;
  final String version;

  final Map<String, _McpClientConnection> _connections =
      <String, _McpClientConnection>{};

  @override
  Iterable<KernelClientConnection> get connections =>
      List<KernelClientConnection>.unmodifiable(_connections.values);

  @override
  Future<KernelClientConnection> connect({
    required String id,
    required KernelTransportKind transport,
    String? endpoint,
    Map<String, dynamic>? options,
  }) async {
    final existing = _connections[id];
    if (existing != null && existing.isConnected) return existing;

    final client = cli.Client(
      name: name,
      version: version,
      capabilities: const cli.ClientCapabilities(),
    );

    final cli.ClientTransport wire = await _openTransport(
      transport: transport,
      endpoint: endpoint,
      options: options ?? const <String, dynamic>{},
    );
    await client.connect(wire);

    final conn = _McpClientConnection(id: id, client: client);
    _connections[id] = conn;
    return conn;
  }

  /// Open a connection over a host-supplied **extension transport**
  /// (serial / usb / ble / ws / tcp / custom), built outside the kernel and
  /// injected here. The kernel never depends on the transport's platform
  /// libraries — the host owns that (e.g. mcp_bridge's FFI transports). This
  /// is the injection seam described in `specs/platform/08-extension.md` §4:
  /// the seam lives in the kernel (pure, no FFI), the impl in the host.
  ///
  /// Formalized by the [ExtensionTransportConnect] capability interface so
  /// hosts can probe the seam off the abstract [KernelClientHost].
  @override
  Future<KernelClientConnection> connectWith({
    required String id,
    required cli.ClientTransport transport,
  }) async {
    final existing = _connections[id];
    if (existing != null && existing.isConnected) return existing;

    final client = cli.Client(
      name: name,
      version: version,
      capabilities: const cli.ClientCapabilities(),
    );
    await client.connect(transport);

    final conn = _McpClientConnection(id: id, client: client);
    _connections[id] = conn;
    return conn;
  }

  Future<cli.ClientTransport> _openTransport({
    required KernelTransportKind transport,
    String? endpoint,
    required Map<String, dynamic> options,
  }) async {
    switch (transport) {
      case KernelTransportKind.inProcess:
        throw StateError(
          'McpClientKernelHost cannot drive an inProcess transport — '
          'use a real stdio / http / sse target',
        );
      case KernelTransportKind.stdio:
        final command = options['command'] as String?;
        if (command == null) {
          throw ArgumentError('stdio transport requires options.command');
        }
        final args = (options['args'] as List?)?.cast<String>() ??
            const <String>[];
        return cli.StdioClientTransport.create(
          command: command,
          arguments: args,
        );
      case KernelTransportKind.streamableHttp:
        if (endpoint == null) {
          throw ArgumentError('streamableHttp transport requires endpoint');
        }
        return cli.StreamableHttpClientTransport.create(baseUrl: endpoint);
      case KernelTransportKind.sse:
        if (endpoint == null) {
          throw ArgumentError('sse transport requires endpoint');
        }
        return cli.SseClientTransport.create(serverUrl: endpoint);
    }
  }

  @override
  Future<void> shutdown() async {
    for (final conn in List<_McpClientConnection>.from(_connections.values)) {
      try {
        await conn.close();
      } catch (_) {/* best-effort */}
    }
    _connections.clear();
  }
}

class _McpClientConnection implements KernelClientConnection {
  _McpClientConnection({required this.id, required this.client});

  @override
  final String id;

  final cli.Client client;

  @override
  bool get isConnected => client.isConnected;

  @override
  Future<KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final r = await client.callTool(name, args);
    return _fromCliToolResult(r);
  }

  @override
  Future<KernelReadResourceResult> readResource(String uri) async {
    final r = await client.readResource(uri);
    return _fromCliReadResource(r);
  }

  @override
  Future<List<KernelToolDescriptor>> listTools() async {
    final tools = await client.listTools();
    return <KernelToolDescriptor>[
      for (final t in tools)
        KernelToolDescriptor(
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema,
        ),
    ];
  }

  @override
  Future<List<KernelResourceDescriptor>> listResources() async {
    final resources = await client.listResources();
    return <KernelResourceDescriptor>[
      for (final r in resources)
        KernelResourceDescriptor(
          uri: r.uri,
          name: r.name,
          description: r.description,
          mimeType: r.mimeType,
        ),
    ];
  }

  @override
  Future<void> close() async {
    client.disconnect();
  }
}

KernelToolResult _fromCliToolResult(cli.CallToolResult r) {
  return KernelToolResult(
    content: <KernelContent>[
      for (final c in r.content) _fromCliContent(c),
    ],
    isError: r.isError,
  );
}

KernelContent _fromCliContent(cli.Content c) {
  if (c is cli.TextContent) {
    return KernelTextContent(text: c.text);
  }
  if (c is cli.ImageContent) {
    return KernelImageContent(
      data: c.data ?? '',
      mimeType: c.mimeType,
    );
  }
  // Unknown content kind — degrade to a text envelope so callers can
  // still inspect the wire payload.
  return KernelTextContent(text: c.toJson().toString());
}

KernelReadResourceResult _fromCliReadResource(cli.ReadResourceResult r) {
  return KernelReadResourceResult(
    contents: <KernelResourceContent>[
      for (final e in r.contents)
        KernelResourceContent(
          uri: e.uri,
          text: e.text,
          blob: e.blob,
          mimeType: e.mimeType,
        ),
    ],
  );
}
