/// MOD-SYSTEM-003 — KernelEndpoint.
///
/// One [KernelServerHost] + one MCP transport + one local tool surface.
/// A [KernelApp] may carry any number of endpoints — vibe_studio runs
/// N endpoints (one per builder domain), flowbrain runs one, AppPlayer
/// runs an in-process endpoint with no transport. Tools registered on
/// one endpoint do not leak to others.
///
/// Endpoints share the KernelApp's [KnowledgeSystem], [AgentLlmSessions],
/// [BundleActivationRegistry], and the four host-side ports — only the
/// MCP tool surface and transport are endpoint-scoped.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:meta/meta.dart';

import '../infra/server/tool_scope.dart';
import 'bundle_activation.dart';
import 'host/kernel_envelope.dart';
import 'host/kernel_server_host.dart';
import 'kernel_app.dart';
import 'standard_tools/standard_tools.dart';

class KernelEndpoint {
  /// Construction is internal — hosts use [KernelApp.addEndpoint].
  @internal
  KernelEndpoint({
    required this.label,
    required this.server,
    required fb.KnowledgeSystem system,
  }) : _system = system;

  /// Endpoint label — caller-supplied (kernel does not interpret it).
  final String label;

  /// Underlying server host (transport + tool registry). Default impl
  /// is `InProcessKernelServerHost`; hosts that bind an external MCP
  /// transport supply an `McpServerKernelHost` via
  /// [KernelApp.boot]'s `serverHostFactory`.
  final KernelServerHost server;

  final fb.KnowledgeSystem _system;
  final List<String> _ownedBundleIds = <String>[];
  bool _started = false;

  /// Bundle ids activated through this endpoint — the flow
  /// `toolDispatcher` for these bundles is wired to this endpoint's
  /// server.
  List<String> get ownedBundleIds => List.unmodifiable(_ownedBundleIds);

  /// `true` once [start] has bound a transport (or completed the
  /// in-process registration when `transport == null`).
  bool get isStarted => _started;

  /// Register a tool with this endpoint's server. Tools registered
  /// here are not visible to other endpoints.
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required KernelToolHandler handler,
    ToolScope scope = ToolScope.external,
  }) {
    server.addTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      handler: handler,
      scope: scope,
    );
  }

  bool removeTool(String name) => server.removeTool(name);

  /// Register an MCP resource on this endpoint's server. The handler
  /// returns the [KernelReadResourceResult]; resources have their own
  /// response shape distinct from tool results so `wrapInProcess` is
  /// not applied. FR-EP-007.
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    required KernelResourceHandler handler,
  }) {
    server.addResource(
      uri: uri,
      name: name,
      description: description,
      mimeType: mimeType,
      handler: handler,
    );
  }

  /// Remove a previously registered resource by URI. Returns `true`
  /// when the underlying server accepted the call; idempotent on
  /// missing URIs. FR-EP-007.
  bool removeResource(String uri) => server.removeResource(uri);

  /// Register every standard tool (`bk.<facade>.<verb>`) onto this
  /// endpoint's server. Wraps the in-process handler so the raw JSON
  /// return value becomes a [KernelToolResult]. The host can override
  /// individual tools afterwards via [addTool] / [removeTool].
  void addStandardTools(KernelApp app, {
    ToolScope scope = ToolScope.external,
  }) {
    for (final entry in standardTools(app).entries) {
      server.addTool(
        name: entry.key,
        description: 'Standard kernel tool: ${entry.key}',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'additionalProperties': true,
        },
        handler: wrapInProcess(entry.value),
        scope: scope,
      );
    }
  }

  /// Activate a bundle through this endpoint. The flow
  /// `toolDispatcher` is wired to this endpoint's [KernelServerHost]
  /// so `action`/`api` flow steps dispatch through the local tool
  /// surface.
  Future<BundleActivationResult> activate(
    mb.McpBundle bundle, {
    String? bundleIdOverride,
  }) async {
    final bundleId = bundleIdOverride ?? _resolveBundleId(bundle);
    final existing = BundleActivationRegistry.instance.get(bundleId);
    if (existing != null) {
      if (!_ownedBundleIds.contains(bundleId)) {
        _ownedBundleIds.add(bundleId);
      }
      return BundleActivationResult(bundleId: bundleId);
    }
    final activation = BundleActivation(
      system: _system,
      bundleId: bundleId,
      boot: server,
    );
    BundleActivationRegistry.instance.register(activation);
    _ownedBundleIds.add(bundleId);
    final result = await activation.activate(bundle);

    // MCP Serving 1.0 (specs/mcp_serving/spec/1.0) — expose the bundle
    // document on this endpoint's server so a remote AppPlayer-class client
    // can `resources/read bundle://manifest.json`, reconstruct the McpBundle,
    // and run it identically (the cross-process counterpart of the in-process
    // bridge registration). Additive; tools / kb:// serving is unchanged. A
    // single-bundle endpoint serves its own document; on a multi-bundle
    // endpoint the most recently activated bundle's document is exposed,
    // matching `bundle://`'s "currently loaded bundle" semantics.
    addResource(
      uri: 'bundle://manifest.json',
      name: bundle.manifest.name,
      description: 'Bundle document — manifest metadata and sections',
      mimeType: 'application/json',
      handler: (uri, params) async => KernelReadResourceResult(
        contents: <KernelResourceContent>[
          KernelResourceContent(
            uri: uri,
            text: jsonEncode(bundle.toJson()),
            mimeType: 'application/json',
          ),
        ],
      ),
    );

    return result;
  }

  Future<void> deactivate(String bundleId) async {
    _ownedBundleIds.remove(bundleId);
    await BundleActivationRegistry.instance.remove(bundleId);
  }

  /// Bind a transport. Pass [KernelTransportKind.inProcess] (or `null`)
  /// for an in-process endpoint that never exposes a network surface
  /// (the AppPlayer-style use case where the kernel runs alongside the
  /// host UI in one process).
  Future<void> start(
    KernelTransportKind? transport, {
    String host = '127.0.0.1',
    int port = 7820,
  }) async {
    if (_started) return;
    if (transport == null || transport == KernelTransportKind.inProcess) {
      server.register();
      _started = true;
      return;
    }
    await server.start(transport, host: host, port: port);
    _started = true;
  }

  Future<void> shutdown() async {
    for (final id in List<String>.from(_ownedBundleIds)) {
      try {
        await BundleActivationRegistry.instance.remove(id);
      } catch (_) {/* best-effort */}
    }
    _ownedBundleIds.clear();
    await server.shutdown();
    _started = false;
  }

  static String _resolveBundleId(mb.McpBundle bundle) {
    final json = bundle.toJson();
    final manifest = json['manifest'];
    if (manifest is Map<String, dynamic>) {
      final id = manifest['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    throw StateError(
      'McpBundle has no manifest.id — bundleIdOverride required',
    );
  }
}
