/// Reference [KernelClientHost] impl on top of `package:mcp_client`.
///
/// Hosts that need outbound MCP calls (workflow `api`-step dispatch,
/// debug probes, cross-server fan-out) wire this through
/// `KernelApp.boot(clientHost: McpClientKernelHost())`. Hosts that
/// never call remote servers leave the parameter null.
library;

import 'dart:async';

import 'package:mcp_client/mcp_client.dart' as cli;

import '../kernel_client_host.dart';
import '../kernel_envelope.dart';
import 'extension_transport_connect.dart';
import 'shared_notifications.dart';
import 'shared_subscriptions.dart';

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
  /// is the injection seam:
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

  @override
  Future<KernelClientConnection> adoptClient({
    required String id,
    required cli.Client client,
  }) async {
    final existing = _connections[id];
    if (existing != null && existing.isConnected) return existing;
    final conn = _McpClientConnection(id: id, client: client, owned: false);
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
        return cli.StreamableHttpClientTransport.create(
          baseUrl: endpoint,
          headers: _credentialHeaders(options),
        );
      case KernelTransportKind.sse:
        if (endpoint == null) {
          throw ArgumentError('sse transport requires endpoint');
        }
        return cli.SseClientTransport.create(
          serverUrl: endpoint,
          headers: _credentialHeaders(options),
        );
    }
  }

  /// Credential wiring for network transports. `options.accessToken` rides
  /// the MCP-standard `Authorization: Bearer` header; `options.headers`
  /// passes through verbatim for servers with a bespoke scheme, and an
  /// explicit header wins over the derived one. Dropping the token here was
  /// the marketplace service-connect `-32001 Authentication required`
  /// (same defect/fix shape as appplayer core `transport_factory`).
  Map<String, String>? _credentialHeaders(Map<String, dynamic> options) {
    final accessToken = options['accessToken'] as String?;
    final extra =
        (options['headers'] as Map<dynamic, dynamic>?)?.cast<String, String>();
    final headers = <String, String>{
      if (accessToken != null) 'Authorization': 'Bearer $accessToken',
      ...?extra,
    };
    return headers.isEmpty ? null : headers;
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
  _McpClientConnection({
    required this.id,
    required this.client,
    this.owned = true,
  }) {
    // Through the fan-out, not `client.onResourceUpdated`: that keeps ONE
    // handler per method, so on a client shared with the device's own screen
    // whichever registered last took the slot and the other stopped receiving
    // updates entirely — with the subscription still live and the socket still
    // up, so nothing anywhere reported a problem.
    _removeListener = SharedClientNotifications.add(
      client,
      'notifications/resources/updated',
      (params) async {
        final uri = params['uri'];
        if (uri is String && !_updates.isClosed) _updates.add(uri);
      },
    );
  }

  void Function()? _removeListener;

  /// Broadcast because several views may watch the same device — a
  /// single-subscription stream would hand the value to whichever listened
  /// first and leave the rest empty.
  final StreamController<String> _updates =
      StreamController<String>.broadcast();

  @override
  final String id;

  final cli.Client client;

  /// False when the client was adopted from the host (see
  /// `ExtensionTransportConnect.adoptClient`). An adopted client is shared —
  /// the host's own screens may be using the same link — so [close] must
  /// deregister without ending it.
  final bool owned;


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
  Future<void> subscribeResource(String uri) =>
      SharedResourceSubscriptions.subscribe(client, uri);

  @override
  Future<void> unsubscribeResource(String uri) =>
      SharedResourceSubscriptions.unsubscribe(client, uri);

  @override
  Stream<String> get resourceUpdates => _updates.stream;

  @override
  Future<void> close() async {
    _removeListener?.call();
    _removeListener = null;
    await _updates.close();
    if (owned) client.disconnect();
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
