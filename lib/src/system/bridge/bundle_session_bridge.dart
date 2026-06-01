/// `BundleSessionBridge` — single entry point hosts use to drive
/// bundle activation through the unified session / dispatch / resource
/// model.
///
/// Layer mapping (Knowledge-operations §14):
///
/// ```
///   host chrome
///        ↓ uses
///   BundleSessionBridge  ← this layer
///        ↓ uses
///   kernel BundleActivation / facade pool
/// ```
///
/// The bridge owns:
/// - session lifecycle (open / runScoped / close)
/// - tool dispatch wrap (callTool, with `scopeId` auto-applied)
/// - resource read (kb:// URI scheme, scopeId auto-applied)
/// - UI mount + subscription bookkeeping
///
/// Hosts (vibe_studio chrome · AppPlayer chrome · future chromes)
/// supply:
/// - a [BridgeToolHandler] callable — the bridge is backend-agnostic.
///   vibe_studio threads its in-process `ServerBootstrap.server.callTool`;
///   AppPlayer (a player + client by default) threads its `mcp_client`
///   or a direct facade dispatch. A server in the host is optional, not
///   required by the bridge.
/// - activation timing (when to open / close — tab close, launcher
///   off, dashboard exit)
/// - foreground tracking (chrome decides which session is "visible";
///   the bridge only tracks it for the fallback singleton path)
///
/// The bridge MUST NOT import host-specific modules (ChromeBridge,
/// studio_workspace, tab models). Self-contained — depends only on
/// brain_kernel + dart:async + package:meta.
library;

import 'dart:async';

import 'package:flowbrain_core/flowbrain_core.dart' as fb;

import '../bundle_activation.dart';
import '../host/kernel_envelope.dart';

import 'dispatch_context.dart';
import 'dispatch_session.dart';
import 'resource_uri.dart';
import 'session_registry.dart';

/// Tool handler signature. The bridge keeps its own in-process
/// registry of these — no specific MCP server library required to
/// dispatch in-process. Hosts that also expose an external endpoint
/// (stdio / streamable HTTP / SSE) thread a server adapter on top of
/// this registry; everyone else just uses the bridge directly.
typedef BridgeToolHandler = Future<KernelToolResult> Function(
  Map<String, dynamic> args,
);

/// Optional resource handler. Returns the resource content for the
/// given URI; the bridge wraps the call in the current session's
/// Zone so `scopeId` is applied where relevant.
typedef BridgeResourceHandler = Future<Object?> Function(String uri);

/// Optional server-side adapter. Hosts that also expose an external
/// MCP endpoint (vibe_studio's `ServerBootstrap.addTool`) thread this
/// so every tool the bridge registers also lands on the external
/// transport's tools/list + dispatch path. Hosts that don't expose an
/// endpoint (AppPlayer's client-default mode, headless probes, tests)
/// leave it null and dispatch in-process via the bridge only.
typedef BridgeServerAdapter = void Function(BridgeToolDef def);

/// Resource counterpart to [BridgeServerAdapter]. Lets the host
/// mirror every `registerResource` onto an external MCP endpoint's
/// resources/list. Called with (uri, name, description, mimeType,
/// handler).
typedef BridgeResourceServerAdapter = void Function(
  String uri,
  String? name,
  String? description,
  String? mimeType,
  BridgeResourceHandler handler,
);

/// Tool definition retained in the bridge's in-process registry —
/// the handler is the runtime callable; description + inputSchema
/// are what an external MCP endpoint (when one is wired) reports to
/// `tools/list`. Self-describing so hosts can enumerate without a
/// separate metadata table.
class BridgeToolDef {
  const BridgeToolDef({
    required this.name,
    required this.handler,
    this.description,
    this.inputSchema,
  });

  final String name;
  final BridgeToolHandler handler;
  final String? description;
  final Map<String, dynamic>? inputSchema;

  /// Project to the same `{name, description, inputSchema}` shape
  /// `ServerBootstrap.toolDefinitions` produces, so callers that
  /// were reading the server's tool list can switch to the bridge
  /// without changing field access patterns.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (description != null) 'description': description,
        if (inputSchema != null) 'inputSchema': inputSchema,
      };
}

class BundleSessionBridge {
  BundleSessionBridge({
    this.systemResolver,
    this.serverAdapter,
    this.serverAdapterRemove,
    this.resourceServerAdapter,
    this.resourceServerAdapterRemove,
    SessionRegistry? registry,
    DispatchContext? context,
  })  : registry = registry ?? SessionRegistry.instance,
        context = context ?? DispatchContext.instance;

  /// Lazy kernel system resolver — used by `readResource` for kb://
  /// URI lookups (8-facade pool). Independent of the in-process
  /// registry below. Hosts that don't ship knowledge resources can
  /// leave it null.
  final fb.KnowledgeSystem? Function()? systemResolver;

  /// Mirror writes onto an external transport's tool table. See
  /// [BridgeServerAdapter]. Optional — leave null for client-only
  /// hosts.
  final BridgeServerAdapter? serverAdapter;

  /// Mirror tool removal onto the external transport. Pairs with
  /// [serverAdapter].
  final void Function(String name)? serverAdapterRemove;

  /// Mirror writes onto the external transport's resource table.
  final BridgeResourceServerAdapter? resourceServerAdapter;

  /// Mirror resource removal onto the external transport.
  final void Function(String uri)? resourceServerAdapterRemove;

  /// In-process tool registry. `<toolName, BridgeToolDef>` map.
  /// Bridge owns this directly — no MCP server library needed for
  /// in-process dispatch. External transport adapters (server lib)
  /// read this same map to populate tools/list responses.
  final Map<String, BridgeToolDef> _tools = <String, BridgeToolDef>{};

  /// In-process resource registry. `<uri, handler>` map for non-kb
  /// URIs. kb:// resolves through the kernel facade pool instead
  /// (see `readResource`).
  final Map<String, BridgeResourceHandler> _resources =
      <String, BridgeResourceHandler>{};

  /// Per-session external-endpoint alias names published via
  /// [serverAdapter] when a session opens. Tracked here so
  /// `closeSession` can call [serverAdapterRemove] for each.
  /// `<sessionId, [aliasName, ...]>`.
  final Map<String, List<String>> _sessionAliases =
      <String, List<String>>{};

  /// Tools whose name starts with this prefix are mirrored as
  /// `bk.<bundleId>.<rest>` on the external endpoint when a session
  /// is open. The in-process registry stays under the canonical
  /// `bk.<facade>.<verb>` name — alias is external-only so the
  /// external LLM can tell which bundle a `bk.fact.write` call
  /// is for.
  static const String _aliasablePrefix = 'bk.';

  /// Suffix used to build the alias name. Public so tests / debug
  /// surfaces can format expected names. Yields `bk.<bundleId>.<rest>`.
  String _aliasNameFor(String bundleId, String canonical) {
    final rest = canonical.substring(_aliasablePrefix.length);
    return '$_aliasablePrefix$bundleId.$rest';
  }

  final SessionRegistry registry;
  final DispatchContext context;

  int _sessionSeq = 0;

  String _nextSessionId(String bundleId) {
    _sessionSeq++;
    return '$bundleId#$_sessionSeq';
  }

  // ── Session lifecycle ──────────────────────────────────────────

  /// Open a session for [activation]. The host calls this once when
  /// the bundle becomes active (tab open / launcher click /
  /// dashboard enter). [master] is true for the host's own home
  /// surface so dispatch sees full union catalog.
  DispatchSession openSession(
    BundleActivation activation, {
    bool master = false,
  }) {
    final session = DispatchSession(
      sessionId: _nextSessionId(activation.bundleId),
      bundleId: activation.bundleId,
      activation: activation,
      master: master,
    );
    registry.register(session);
    // Publish per-session external aliases for every `bk.*` tool
    // already registered. Master sessions skip alias publication —
    // their dispatch already sees full union via runAsMaster, and
    // the canonical `bk.<facade>.<verb>` name covers them on the
    // external endpoint.
    if (!master) _publishAliasesFor(session);
    return session;
  }

  /// Open a master / host-level session that's not bound to a single
  /// BundleActivation. Used for the host home tab, sudo paths, and
  /// admin surfaces that need union catalog access. `bundleId` is a
  /// marker (e.g. 'host') that surfaces in diagnostics; `scopeId`
  /// itself short-circuits on `master` before reading it.
  DispatchSession openMasterSession({String bundleId = 'host'}) {
    final session = DispatchSession(
      sessionId: _nextSessionId(bundleId),
      bundleId: bundleId,
      master: true,
    );
    registry.register(session);
    return session;
  }

  /// Close a session. Tears down every attached handle (UI mounts,
  /// subscriptions, scratch resources) and unregisters from the
  /// session registry. Does NOT touch the kernel activation —
  /// that's the host's call (the same BundleActivation may still
  /// be wanted by other sessions).
  Future<void> closeSession(DispatchSession session) async {
    _unpublishAliasesFor(session);
    await session.closeAttached();
    registry.remove(session.sessionId);
  }

  /// Run [body] inside [session]'s zone. Every nested `callTool`
  /// / `readResource` / `scopeId` inside [body] sees the session,
  /// no matter how many async hops away.
  Future<T> runScoped<T>(
    DispatchSession session,
    Future<T> Function() body,
  ) {
    if (session.isClosed) {
      return Future<T>.error(
        StateError('Session ${session.sessionId} already closed'),
      );
    }
    return context.runScoped(session, body);
  }

  /// Run [body] as a master-context call. For host home tab /
  /// admin / sudo paths that need union access. No session = no
  /// per-bundle handle bookkeeping, so attach is a no-op here.
  Future<T> runAsMaster<T>(Future<T> Function() body) =>
      context.runAsMaster(body);

  // ── Tool registry — knowledge-wrapping path only ──────────────

  /// Register a knowledge tool wrapper. The name MUST start with
  /// `_aliasablePrefix` (`bk.`) — bridge's sole purpose is to wrap
  /// knowledge tools so domains can call them by canonical name from
  /// their own context (scopeId auto-applied) and external clients
  /// reach them through a `bk.<bundleId>.<rest>` alias for
  /// bundle-level isolation.
  ///
  /// **General tools (host menus, domain logic from `manifest.tools.tools[]`,
  /// custom-namespace utilities) do NOT belong here** — they should be
  /// registered through `HostToolRegistry.registerExposed` (or the
  /// host's own dispatcher + endpoint wiring), which adds the
  /// `<bundleId>.<rawName>` prefix once and stops, with no aliasing /
  /// scopeId machinery.
  ///
  /// Idempotent — re-registering the same name replaces the handler.
  /// Throws [ArgumentError] when [name] does not start with `bk.`.
  void registerTool({
    required String name,
    required BridgeToolHandler handler,
    String? description,
    Map<String, dynamic>? inputSchema,
  }) {
    if (!name.startsWith(_aliasablePrefix)) {
      throw ArgumentError(
        'BundleSessionBridge.registerTool only accepts knowledge tools '
        '(name must start with "$_aliasablePrefix"). Got: "$name". '
        'General domain or host tools go through HostToolRegistry or '
        'direct dispatcher + endpoint wiring.',
      );
    }
    final def = BridgeToolDef(
      name: name,
      handler: handler,
      description: description,
      inputSchema: inputSchema,
    );
    _tools[name] = def;
    // Publish bundleId-prefixed aliases on the external endpoint for
    // every active non-master session. The canonical name is NOT
    // mirrored — two domains can register the same knowledge tool
    // (e.g. `bk.fact.write`) and the endpoint resolves each by its
    // own alias, never by the bare canonical.
    for (final s in registry.all) {
      if (s.master) continue;
      _publishAliasFor(s, def);
    }
  }

  /// Remove a knowledge tool. Returns true when the name was
  /// registered. The bridge withdraws both the canonical entry from
  /// its in-process registry and every per-session alias on the
  /// external endpoint.
  bool unregisterTool(String name) {
    final removed = _tools.remove(name) != null;
    if (!removed) return false;
    if (name.startsWith(_aliasablePrefix)) {
      for (final s in registry.all) {
        final aliasName = _aliasNameFor(s.bundleId, name);
        _sessionAliases[s.sessionId]?.remove(aliasName);
        serverAdapterRemove?.call(aliasName);
      }
    }
    return true;
  }

  // ── External-endpoint alias publication ───────────────────────

  void _publishAliasesFor(DispatchSession session) {
    if (serverAdapter == null) return;
    for (final def in _tools.values) {
      if (!def.name.startsWith(_aliasablePrefix)) continue;
      _publishAliasFor(session, def);
    }
  }

  void _publishAliasFor(DispatchSession session, BridgeToolDef def) {
    if (serverAdapter == null) return;
    final aliasName = _aliasNameFor(session.bundleId, def.name);
    Future<KernelToolResult> aliasHandler(Map<String, dynamic> args) =>
        callTool(session, def.name, args);
    final aliasDef = BridgeToolDef(
      name: aliasName,
      handler: aliasHandler,
      description:
          '[${session.bundleId} context] ${def.description ?? ''}'.trim(),
      inputSchema: def.inputSchema,
    );
    serverAdapter!.call(aliasDef);
    (_sessionAliases[session.sessionId] ??= <String>[]).add(aliasName);
  }

  void _unpublishAliasesFor(DispatchSession session) {
    final names = _sessionAliases.remove(session.sessionId);
    if (names == null) return;
    for (final n in names) {
      serverAdapterRemove?.call(n);
    }
  }

  /// Whether a tool name is registered.
  bool hasTool(String name) => _tools.containsKey(name);

  /// Snapshot of registered tool names.
  List<String> listTools() => List<String>.unmodifiable(_tools.keys);

  /// Snapshot of registered tool definitions. Used by external
  /// transport adapters that need the full meta (description +
  /// inputSchema) to answer tools/list.
  List<BridgeToolDef> listToolDefinitions() =>
      List<BridgeToolDef>.unmodifiable(_tools.values);

  /// Look up a single tool definition (or null when unregistered).
  BridgeToolDef? getToolDef(String name) => _tools[name];

  // ── Tool dispatch ──────────────────────────────────────────────

  /// Dispatch a tool from the bridge's own registry. Wraps the
  /// handler call in `runScoped(session, ...)` so nested
  /// `DispatchContext.scopeId` calls see the right caller. Returns
  /// a [KernelToolResult] with `isError: true` when the name isn't
  /// registered.
  Future<KernelToolResult> callTool(
    DispatchSession session,
    String name,
    Map<String, dynamic> args,
  ) {
    return runScoped(session, () => _dispatchTool(name, args));
  }

  /// Dispatch as master (no session). Host home tab / admin / sudo.
  Future<KernelToolResult> callToolAsMaster(
    String name,
    Map<String, dynamic> args,
  ) {
    return runAsMaster(() => _dispatchTool(name, args));
  }

  Future<KernelToolResult> _dispatchTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final def = _tools[name];
    if (def == null) {
      return KernelToolResult(
        isError: true,
        content: <KernelContent>[
          KernelTextContent(text: 'Tool not registered: $name'),
        ],
      );
    }
    return def.handler(args);
  }

  // ── Resource registry ─────────────────────────────────────────

  /// Register a custom (non-kb) resource handler. kb:// URIs are
  /// resolved against the kernel facade pool by [readResource]
  /// regardless of what's registered here. When a host wires a
  /// [resourceServerAdapter] the same registration also lands on
  /// the external transport's resources/list (so external LLMs see
  /// the resource).
  void registerResource(
    String uri,
    BridgeResourceHandler handler, {
    String? name,
    String? description,
    String? mimeType,
  }) {
    _resources[uri] = handler;
    resourceServerAdapter?.call(uri, name, description, mimeType, handler);
  }

  bool unregisterResource(String uri) {
    final removed = _resources.remove(uri) != null;
    if (removed) resourceServerAdapterRemove?.call(uri);
    return removed;
  }

  List<String> listResources() =>
      List<String>.unmodifiable(_resources.keys);

  // ── Resource read ──────────────────────────────────────────────

  /// Read a `kb://<facade>/<id>` resource against [system]. The id
  /// segment is auto-scoped via [DispatchContext.scopeId] when
  /// called inside `runScoped(session, ...)` — bundles writing
  /// `kb://fact/foo` resolve to `kb://fact/<bundleId>.foo`.
  /// Returns null when [system] is unwired, the URI doesn't parse,
  /// or the underlying facade hasn't booted its runtime.
  Future<Object?> readResource(String uri) async {
    // Custom (non-kb) URI registered via registerResource takes
    // precedence — hosts can override or extend the kb:// scheme
    // by registering a handler for the exact URI.
    final custom = _resources[uri];
    if (custom != null) return custom(uri);
    final s = systemResolver?.call();
    if (s == null) return null;
    final ref = KbResourceRef.parse(uri);
    if (ref == null) return null;
    final scopedId = context.scopeId(ref.id);
    switch (ref.facade) {
      case KbFacade.fact:
        return s.facts.getFact(scopedId);
      case KbFacade.skill:
        final rt = s.skillRuntime;
        if (rt == null) return null;
        return rt.registry.getSkill(scopedId);
      case KbFacade.profile:
        return s.profile.get(scopedId);
      case KbFacade.philosophy:
        return s.ethosStore?.getEthos(scopedId);
      case KbFacade.workflow:
        // Ops registries store factories; a read-style lookup
        // surfaces presence + the id so callers can `studio.workflow.run`
        // with confidence. Building the workflow here would side-effect.
        final ops = s.opsRuntime;
        if (ops == null) return null;
        return ops.workflowRegistry.containsKey(scopedId)
            ? <String, dynamic>{'id': scopedId, 'present': true}
            : null;
      case KbFacade.pipeline:
        final ops = s.opsRuntime;
        if (ops == null) return null;
        return ops.pipelineRegistry.containsKey(scopedId)
            ? <String, dynamic>{'id': scopedId, 'present': true}
            : null;
      case KbFacade.runbook:
        final ops = s.opsRuntime;
        if (ops == null) return null;
        return ops.runbookRegistry.containsKey(scopedId)
            ? <String, dynamic>{'id': scopedId, 'present': true}
            : null;
      case KbFacade.agent:
        return s.agents.getAgent(scopedId);
    }
  }

  // ── Handle attachment ──────────────────────────────────────────

  /// Attach a UI mount / subscription / scratch resource to the
  /// session so `closeSession` cleans it up.
  void attach(DispatchSession session, SessionHandle handle) {
    session.attach(handle);
  }
}
