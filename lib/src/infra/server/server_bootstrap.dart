/// MCP server bootstrap (MOD-INFRA-001 / DDD-20).
///
/// `ServerBootstrap` is the reference [KernelServerHost] impl on top of
/// `package:mcp_server`. The kernel core never imports it directly —
/// hosts that want an MCP transport surface (vibe_studio's per-domain
/// endpoints, knowledge_builder, headless CLIs) supply
/// `ServerBootstrap.new` as `KernelApp.boot`'s `serverHostFactory` (or
/// import it via `package:brain_kernel/mcp_host.dart` and instantiate
/// directly).
///
/// The class translates between the kernel envelope types
/// ([KernelToolHandler] / [KernelToolResult] / [KernelResourceHandler])
/// and `mcp.Server`'s wire shape so the kernel core stays library-
/// agnostic.
library;

import 'package:mcp_server/mcp_server.dart' as mcp;

import '../../core/asset_validator.dart';
import '../../core/project.dart';
import '../../core/patch_pipeline.dart';
import '../../core/undo_redo_stack.dart';
import '../../feat/extractor/asset_extractor.dart';
import '../../feat/extractor/reviewer_queue.dart';
import '../../system/host/kernel_envelope.dart';
import '../../system/host/kernel_server_host.dart';
import '../../system/host/mcp_server_spec.dart';
import 'tool_scope.dart';
import 'transport_picker.dart';

class ServerBootstrap implements KernelServerHost {
  ServerBootstrap({
    this.name = 'knowledge_builder',
    this.version = '0.1.0',
    Project? project,
    AssetExtractor extractor = const StubAssetExtractor(),
    Set<ToolScope> visibility = const {ToolScope.external},
    bool debugMode = false,
  })  : _extractor = extractor,
        _visibility = {
          ...visibility,
          if (debugMode) ToolScope.debug,
        },
        _debugMode = debugMode,
        server = mcp.Server(
          name: name,
          version: version,
          capabilities: const mcp.ServerCapabilities(
            tools: mcp.ToolsCapability(listChanged: true),
            resources:
                mcp.ResourcesCapability(subscribe: false, listChanged: true),
            prompts: mcp.PromptsCapability(listChanged: false),
          ),
        ) {
    _setProject(project);
  }

  /// [KernelServerHostFactory]-shaped entry point. Hosts pass this to
  /// `KernelApp.boot(serverHostFactory: ServerBootstrap.factory)` so
  /// every endpoint binds an MCP-server-backed surface.
  static ServerBootstrap factory({
    required String name,
    required String version,
    Set<ToolScope> visibility = const {ToolScope.external},
    bool debugMode = false,
  }) {
    return ServerBootstrap(
      name: name,
      version: version,
      visibility: visibility,
      debugMode: debugMode,
    );
  }

  final Set<ToolScope> _visibility;
  final bool _debugMode;

  final Map<String, ToolScope> _scopes = <String, ToolScope>{};
  final Map<String, KernelToolDef> _toolDefs = <String, KernelToolDef>{};
  final Map<String, KernelToolHandler> _kernelHandlers =
      <String, KernelToolHandler>{};
  final Map<String, KernelPromptDef> _promptDefs = <String, KernelPromptDef>{};
  final Set<String> _resourceUris = <String>{};

  @override
  Map<String, ToolScope> get toolScopes => Map.unmodifiable(_scopes);

  @override
  List<KernelToolDef> get toolDefinitions =>
      List<KernelToolDef>.unmodifiable(_toolDefs.values);

  /// Populated by `startStreamableHttp` / `startSse` so consumers
  /// (Claude Code recipe, sibling hosts) can dial the live URL. Stdio
  /// transports require the host to call [setExternalStdioSpec]
  /// because the consumer needs the host's launch command / args.
  /// Cleared on [shutdown].
  McpServerSpec? _externalSpec;

  @override
  McpServerSpec? get externalSpec => _externalSpec;

  /// Publish a stdio dial-back spec. Hosts that ship the kernel as a
  /// child process (Claude Code calling vibe_studio's stdio MCP
  /// surface) call this so [externalSpec] surfaces the launch command
  /// / args / env consumers need.
  void setExternalStdioSpec({
    required String command,
    List<String> args = const <String>[],
    Map<String, String> env = const <String, String>{},
  }) {
    _externalSpec = McpServerSpec(
      name: name,
      transport: McpServerTransport.stdio,
      command: command,
      args: args,
      env: env,
    );
  }

  @override
  Set<ToolScope> get activeVisibility => Set.unmodifiable(_visibility);

  @override
  bool get debugMode => _debugMode;

  @override
  final String name;

  @override
  final String version;

  /// Active project. Tools that mutate canonical state require it; pure
  /// metadata tools tolerate `null`.
  Project? _project;
  PatchPipeline? _pipeline;
  ReviewerQueue? _queue;
  UndoRedoStack? _undoStack;
  AssetExtractor _extractor;

  /// Replace the LLM-backed asset extractor at runtime — host wires
  /// the real provider once mcp_llm session is available.
  set extractor(AssetExtractor next) => _extractor = next;
  AssetExtractor get extractor => _extractor;

  Project? get project => _project;
  set project(Project? p) => _setProject(p);

  ReviewerQueue? get queue => _queue;
  PatchPipeline? get pipeline => _pipeline;

  void _setProject(Project? p) {
    _project = p;
    _undoStack = p == null ? null : UndoRedoStack();
    _pipeline = (p == null || _undoStack == null)
        ? null
        : PatchPipeline(
            canonical: p.canonical,
            validator: const AssetValidator(),
            undoStack: _undoStack!,
          );
    _queue = _pipeline == null
        ? null
        : ReviewerQueue(pipeline: _pipeline!);
  }

  /// Underlying mcp_server instance. Reference-impl detail — hosts that
  /// need to drive the raw server (e.g. attaching prompt handlers
  /// directly) reach in here. Code outside the mcp_host adapter should
  /// prefer the [KernelServerHost] surface.
  final mcp.Server server;
  mcp.ServerTransport? _transport;
  bool _registered = false;

  final List<Map<String, Object?>> _dispatchLog = <Map<String, Object?>>[];
  static const int _dispatchLogLimit = 200;

  @override
  List<Map<String, Object?>> get dispatchLog =>
      List<Map<String, Object?>>.unmodifiable(_dispatchLog);

  void _addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required KernelToolHandler handler,
    ToolScope scope = ToolScope.external,
  }) {
    _scopes[name] = scope;
    _toolDefs[name] = KernelToolDef(
      name: name,
      description: description,
      inputSchema: inputSchema,
      scope: scope,
    );
    _kernelHandlers[name] = handler;
    if (!_visibility.contains(scope)) return;
    server.addTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      handler: (args) => _dispatchWithLog(name, args, handler),
    );
  }

  Future<mcp.CallToolResult> _dispatchWithLog(
    String name,
    Map<String, dynamic> args,
    KernelToolHandler handler,
  ) async {
    final start = DateTime.now();
    final sw = Stopwatch()..start();
    bool isError = false;
    String? resultPreview;
    KernelToolResult kernelResult;
    try {
      kernelResult = await handler(args);
      isError = kernelResult.isError ?? false;
      if (kernelResult.content.isNotEmpty) {
        final c = kernelResult.content.first;
        if (c is KernelTextContent) {
          final t = c.text;
          resultPreview = t.length > 240 ? '${t.substring(0, 240)}…' : t;
        }
      }
    } catch (e) {
      sw.stop();
      _appendDispatchLog(<String, Object?>{
        'ts': start.toUtc().toIso8601String(),
        'tool': name,
        'durationMs': sw.elapsedMilliseconds,
        'isError': true,
        'thrown': e.toString(),
        'args': args,
      });
      rethrow;
    }
    sw.stop();
    _appendDispatchLog(<String, Object?>{
      'ts': start.toUtc().toIso8601String(),
      'tool': name,
      'durationMs': sw.elapsedMilliseconds,
      'isError': isError,
      'args': args,
      if (resultPreview != null) 'resultPreview': resultPreview,
    });
    return _toMcpToolResult(kernelResult);
  }

  void _appendDispatchLog(Map<String, Object?> entry) {
    _dispatchLog.add(entry);
    while (_dispatchLog.length > _dispatchLogLimit) {
      _dispatchLog.removeAt(0);
    }
  }

  /// Idempotent tool registration. Call once before connecting a
  /// transport.
  @override
  void register() {
    if (_registered) return;
    _registered = true;
  }

  @override
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required KernelToolHandler handler,
    ToolScope scope = ToolScope.external,
  }) {
    _addTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      handler: handler,
      scope: scope,
    );
  }

  @override
  bool removeTool(String name) {
    final hadDef = _toolDefs.remove(name) != null;
    final hadScope = _scopes.remove(name) != null;
    _kernelHandlers.remove(name);
    if (!hadDef && !hadScope) return false;
    server.removeTool(name);
    return true;
  }

  @override
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
      handler: (u, params) async {
        final result = await handler(u, params);
        return _toMcpReadResourceResult(result);
      },
    );
    _resourceUris.add(uri);
  }

  @override
  List<String> get resourceUris => List<String>.unmodifiable(_resourceUris);

  @override
  bool removeResource(String uri) {
    try {
      server.removeResource(uri);
      _resourceUris.remove(uri);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void addPrompt({
    required String name,
    required String description,
    required List<KernelPromptArgument> arguments,
    required KernelPromptHandler handler,
  }) {
    _promptDefs[name] = KernelPromptDef(
      name: name,
      description: description,
      arguments: List<KernelPromptArgument>.unmodifiable(arguments),
    );
    server.addPrompt(
      name: name,
      description: description,
      arguments: <mcp.PromptArgument>[
        for (final a in arguments)
          mcp.PromptArgument(
            name: a.name,
            description: a.description ?? '',
            required: a.required,
          ),
      ],
      handler: (Map<String, dynamic> args) async {
        final result = await handler(args);
        return _toMcpGetPromptResult(result);
      },
    );
  }

  @override
  bool removePrompt(String name) {
    final removed = _promptDefs.remove(name) != null;
    try {
      server.removePrompt(name);
    } catch (_) {/* ignore — mcp_server raises when name is absent */}
    return removed;
  }

  @override
  List<KernelPromptDef> get promptDefinitions =>
      List<KernelPromptDef>.unmodifiable(_promptDefs.values);

  @override
  Future<KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final handler = _kernelHandlers[name];
    if (handler == null) {
      return KernelToolResult(
        isError: true,
        content: <KernelContent>[
          KernelTextContent(text: 'Tool not registered: $name'),
        ],
      );
    }
    return handler(args);
  }

  // ── Transport lifecycle ────────────────────────────────────────

  Future<void> startStdio() async {
    register();
    final t = mcp.StdioServerTransport();
    _transport = t;
    server.connect(t);
    await t.onClose;
  }

  Future<void> startStreamableHttp({
    String host = '127.0.0.1',
    int port = 7820,
    String endpoint = '/mcp',
  }) async {
    register();
    // Single source of truth — the config carries host/port/endpoint
    // and both the transport (which listens) and the spec (which the
    // recipe surfaces to consumers like Claude Code's --mcp-config)
    // read the path off the same object. Hosts that need a custom
    // path (e.g. `/api/mcp`, `/v2/mcp`) override [endpoint] here.
    final config = mcp.StreamableHttpServerConfig(
      host: host,
      port: port,
      endpoint: endpoint,
    );
    final t = mcp.StreamableHttpServerTransport(config: config);
    await t.start();
    _transport = t;
    server.connect(t);
    _externalSpec = McpServerSpec(
      name: name,
      transport: McpServerTransport.http,
      url: 'http://${config.host}:${config.port}${config.endpoint}',
    );
  }

  Future<void> startSse({
    String host = '127.0.0.1',
    int port = 7821,
    String endpoint = '/sse',
    String messagesEndpoint = '/message',
  }) async {
    register();
    final t = mcp.SseServerTransport(
      endpoint: endpoint,
      messagesEndpoint: messagesEndpoint,
      host: host,
      port: port,
    );
    _transport = t;
    server.connect(t);
    _externalSpec = McpServerSpec(
      name: name,
      transport: McpServerTransport.sse,
      url: 'http://$host:$port$endpoint',
    );
  }

  /// Dispatch the chosen [transport] to the matching `startX` method.
  @override
  Future<void> start(
    KernelTransportKind transport, {
    String host = '127.0.0.1',
    int port = 7820,
  }) {
    switch (transport) {
      case KernelTransportKind.inProcess:
        register();
        return Future.value();
      case KernelTransportKind.stdio:
        return startStdio();
      case KernelTransportKind.streamableHttp:
        return startStreamableHttp(host: host, port: port);
      case KernelTransportKind.sse:
        return startSse(host: host, port: port);
    }
  }

  /// Legacy entry point — accepts the `infra/server` [TransportType]
  /// enum used by older callers (`transport_picker.pickTransport`).
  Future<void> startTransport(
    TransportType transport, {
    String host = '127.0.0.1',
    int port = 7820,
  }) {
    switch (transport) {
      case TransportType.stdio:
        return startStdio();
      case TransportType.streamableHttp:
        return startStreamableHttp(host: host, port: port);
      case TransportType.sse:
        return startSse(host: host, port: port);
    }
  }

  @override
  Future<void> shutdown() async {
    final t = _transport;
    if (t != null) t.close();
    _transport = null;
    _externalSpec = null;
  }
}

mcp.CallToolResult _toMcpToolResult(KernelToolResult r) {
  return mcp.CallToolResult(
    content: <mcp.Content>[
      for (final c in r.content) _toMcpContent(c),
    ],
    isError: r.isError,
  );
}

mcp.GetPromptResult _toMcpGetPromptResult(KernelGetPromptResult r) {
  return mcp.GetPromptResult(
    description: r.description ?? '',
    messages: <mcp.Message>[
      for (final m in r.messages)
        mcp.Message(role: m.role, content: _toMcpContent(m.content)),
    ],
  );
}

mcp.Content _toMcpContent(KernelContent c) {
  switch (c) {
    case KernelTextContent t:
      return mcp.TextContent(text: t.text);
    case KernelImageContent i:
      return mcp.ImageContent(data: i.data, mimeType: i.mimeType);
  }
}

mcp.ReadResourceResult _toMcpReadResourceResult(KernelReadResourceResult r) {
  return mcp.ReadResourceResult(
    contents: <mcp.ResourceContentInfo>[
      for (final e in r.contents)
        mcp.ResourceContentInfo(
          uri: e.uri,
          text: e.text,
          blob: e.blob,
          mimeType: e.mimeType,
        ),
    ],
  );
}
