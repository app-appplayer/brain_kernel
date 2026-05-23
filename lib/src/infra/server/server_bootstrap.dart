/// MCP server bootstrap for knowledge_builder (MOD-INFRA-001 / DDD-20).
///
/// Wires `mcp.Server` lifecycle and registers the eight first-cut
/// `kb_*` tools — kb_status / kb_open_project / kb_save / kb_list_assets
/// / kb_get_asset / kb_query / kb_validate / kb_build. Asset proposal /
/// approval (`kb_add_*`, `kb_propose_*`, `kb_approve`, `kb_reject`) plus
/// the runtime probe wiring land in later rounds.
library;

import 'package:mcp_server/mcp_server.dart' as mcp;

import '../../core/asset_validator.dart';
import '../../core/project.dart';
import '../../core/patch_pipeline.dart';
import '../../core/undo_redo_stack.dart';
import '../../feat/extractor/asset_extractor.dart';
import '../../feat/extractor/reviewer_queue.dart';
import 'tool_scope.dart';
import 'transport_picker.dart';

class ServerBootstrap {
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
            // Prompts capability advertises the onboarding workflow
            // surface so external LLMs can discover canonical
            // bootstrap / wiring / install recipes via prompts/list +
            // prompts/get. Hosts (vibe_studio) register the actual
            // prompt bodies after boot.
            prompts: mcp.PromptsCapability(listChanged: false),
          ),
        ) {
    _setProject(project);
  }

  /// Scopes the host accepts at this launch. Defaults to `{external}` —
  /// the production setup. Hosts running a dev / debug session pass
  /// `{external}` plus `debugMode: true` to flip in `debug`-scoped
  /// tools, or pass `{external, internal}` if internal helpers should
  /// also be reachable on the local transport (rare).
  final Set<ToolScope> _visibility;
  final bool _debugMode;

  /// Tool name → declared scope. Preserved even when a tool is filtered
  /// out at register time so introspection tools (and tests) can ask
  /// which scope a name belongs to.
  final Map<String, ToolScope> _scopes = <String, ToolScope>{};

  /// Tool name → full definition (description + inputSchema + scope).
  /// Drives the meta tools (`kb_list_tools` / `kb_describe_tool`) so
  /// internal LLMs (FlowBrain agents) and Builder UX surfaces share the
  /// same catalog as external MCP clients — Extension API v1
  /// contribution point.
  final Map<String, _ToolDef> _toolDefs = <String, _ToolDef>{};

  /// Read-only view of registered tool scopes.
  Map<String, ToolScope> get toolScopes => Map.unmodifiable(_scopes);

  /// Read-only catalog of registered tools as JSON-serializable
  /// definitions — `[{name, description, inputSchema, scope}]`. Used
  /// by `BuilderToolRegistry` / Debug panel to render the full surface
  /// in-process. Includes tools whose scope is currently filtered out
  /// of the transport — UI / internal LLM may still surface them.
  List<Map<String, dynamic>> get toolDefinitions {
    return <Map<String, dynamic>>[
      for (final def in _toolDefs.values) def.toJson(),
    ];
  }

  /// Active visibility set (host-supplied + debug toggle).
  Set<ToolScope> get activeVisibility => Set.unmodifiable(_visibility);

  bool get debugMode => _debugMode;

  final String name;
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

  /// Test-visible accessors so handler tests can inspect queue state
  /// without going through MCP transport. Hosts (vibe_knowledge_builder
  /// shell) read [pipeline.undoStack.changes] for ⌘Z / ⇧⌘Z button state
  /// and call [pipeline.undo] / [pipeline.redo] for keyboard shortcuts.
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

  final mcp.Server server;
  mcp.ServerTransport? _transport;
  bool _registered = false;

  /// Ring buffer of recent (up to [_dispatchLogLimit]) tool calls.
  /// Captured by the wrapper installed in [_addTool] — every handler
  /// invocation lands here regardless of who registered the tool, so
  /// `studio.debug.dispatch_log` can surface what an external LLM
  /// agent actually called without instrumenting each handler.
  final List<Map<String, Object?>> _dispatchLog = <Map<String, Object?>>[];
  static const int _dispatchLogLimit = 200;

  /// Read-only snapshot of the most recent tool dispatches.
  List<Map<String, Object?>> get dispatchLog =>
      List<Map<String, Object?>>.unmodifiable(_dispatchLog);

  /// Wrapper over `server.addTool` that records the tool's [scope] and
  /// only forwards to the underlying mcp.Server when the scope falls
  /// into the active [_visibility] set. Tools outside the visibility
  /// are still tracked in [_scopes] for introspection but never reach
  /// any transport — the surface stays minimal for the launch profile
  /// the host chose.
  void _addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required mcp.ToolHandler handler,
    ToolScope scope = ToolScope.external,
  }) {
    _scopes[name] = scope;
    _toolDefs[name] = _ToolDef(
      name: name,
      description: description,
      inputSchema: inputSchema,
      scope: scope,
    );
    if (!_visibility.contains(scope)) return;
    server.addTool(
      name: name,
      description: description,
      inputSchema: inputSchema,
      handler: (args) => _dispatchWithLog(name, args, handler),
    );
  }

  /// Run [handler] with [args] and record the call + outcome into
  /// [_dispatchLog]. Captures duration, error flag, and a short
  /// preview of args / result text. The buffer is capped at
  /// [_dispatchLogLimit] entries (oldest dropped on overflow).
  Future<mcp.CallToolResult> _dispatchWithLog(
    String name,
    Map<String, dynamic> args,
    mcp.ToolHandler handler,
  ) async {
    final start = DateTime.now();
    final sw = Stopwatch()..start();
    bool isError = false;
    String? resultPreview;
    mcp.CallToolResult result;
    try {
      result = await handler(args);
      isError = result.isError ?? false;
      if (result.content.isNotEmpty) {
        final c = result.content.first;
        if (c is mcp.TextContent) {
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
    return result;
  }

  void _appendDispatchLog(Map<String, Object?> entry) {
    _dispatchLog.add(entry);
    while (_dispatchLog.length > _dispatchLogLimit) {
      _dispatchLog.removeAt(0);
    }
  }

  /// Idempotent tool registration. Call once before connecting a
  /// transport. Kernel itself ships zero tools — hosts wire their own
  /// surface through [addTool] (base register*Tools / domain bundle
  /// activation paths). Kept for backwards compat with hosts that
  /// already call `boot..register()`.
  void register() {
    if (_registered) return;
    _registered = true;
  }

  /// Public entry-point for hosts that ship their own MCP tools (vibe's
  /// runtime errors / layout snapshot, kb_flutter's UI hooks, etc.).
  /// Tools registered through this path go through the same scope
  /// filter as the kernel's built-ins — pass `scope: ToolScope.debug`
  /// for tools that should only surface when the host launches with
  /// `debugMode: true`. FR-SRV-007.
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required mcp.ToolHandler handler,
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

  /// Remove a tool previously registered via [addTool]. Used by the
  /// universal-host activation lifecycle — when a domain bundle's tab
  /// closes, the host calls [removeTool] for every prefixed tool the
  /// bundle declared, so the next `tools/list` no longer surfaces
  /// orphan entries pointing at a torn-down dispatch path.
  ///
  /// Returns true when an entry was removed, false when no tool with
  /// that name was tracked. Idempotent — calling twice is safe.
  bool removeTool(String name) {
    final hadDef = _toolDefs.remove(name) != null;
    final hadScope = _scopes.remove(name) != null;
    if (!hadDef && !hadScope) return false;
    server.removeTool(name);
    return true;
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
  }) async {
    register();
    final t = mcp.StreamableHttpServerTransport(
      config: mcp.StreamableHttpServerConfig(host: host, port: port),
    );
    await t.start();
    _transport = t;
    server.connect(t);
  }

  Future<void> startSse({
    String host = '127.0.0.1',
    int port = 7821,
  }) async {
    register();
    final t = mcp.SseServerTransport(
      endpoint: '/sse',
      messagesEndpoint: '/message',
      host: host,
      port: port,
    );
    _transport = t;
    server.connect(t);
  }

  /// Dispatch the chosen [transport] to the matching `startX` method.
  Future<void> start(
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

  Future<void> shutdown() async {
    final t = _transport;
    if (t != null) t.close();
    _transport = null;
  }
}

class _ToolDef {
  const _ToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.scope,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final ToolScope scope;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'scope': scope.name,
      };
}
