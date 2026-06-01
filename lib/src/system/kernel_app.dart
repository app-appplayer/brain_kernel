/// MOD-SYSTEM-002 — KernelApp.
///
/// Single boot entry point for any FlowBrain app — vibe_studio,
/// flowbrain, AppPlayer, or a user's own host. The class is
/// intentionally neutral: it does not depend on any specific use
/// case, and every host-side concern (configuration loading, UI
/// resource serving, observability, bundle distribution) is delegated
/// to a host-supplied [Port].
///
/// Two-tier model:
/// - [KernelApp] owns the shared resources: [fb.KnowledgeSystem],
///   [AgentLlmSessions], [BundleActivationRegistry],
///   [KnowledgeQueryEngine], the four host ports, the active context.
/// - [KernelEndpoint] (created via [addEndpoint]) owns one
///   [ServerBootstrap] + one transport + one local tool surface.
///   Hosts add as many endpoints as their use case requires.
///
/// Knowledge-scope toggle (manager vs per-bundle):
/// - [activeBundleId] = `null` → master context (manager scope, full
///   visibility, no id prefix).
/// - [activeBundleId] = `'<bundleId>'` → domain context. [scopeIdFor]
///   auto-prefixes local ids so agents in the domain context address
///   their own namespace by default while the master agent retains
///   full visibility.
library;

import 'dart:async';

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:meta/meta.dart';

import '../core/sidecar/chat_log.dart';
import '../infra/chat/agent_chat_controller.dart';
import '../infra/flowbrain/flowbrain_wiring.dart';
import '../infra/flowbrain/llm_port_adapter.dart';
import '../infra/knowledge/bundle_registry.dart';
import '../infra/knowledge/query_engine.dart';
import '../infra/llm/agent_llm_sessions.dart';
import '../infra/server/tool_scope.dart';
import 'bundle_activation.dart';
import 'host/in_process_server_host.dart';
import 'host/kernel_client_host.dart';
import 'host/kernel_server_host.dart';
import 'host/mcp_server_spec.dart';
import 'kernel_endpoint.dart';
import 'ports/bundle_source_port.dart';
import 'ports/config_port.dart';
import 'ports/observability_port.dart';
import 'ports/ui_resource_port.dart';

/// Factory the host supplies to create one [KernelServerHost] per
/// endpoint. The reference impl `McpServerKernelHost.factory`
/// (`package:brain_kernel/mcp_host.dart`) wraps `mcp.Server` + stdio /
/// Streamable HTTP / SSE transports. Hosts that never expose a network
/// surface leave [KernelApp.boot]'s `serverHostFactory` null — the
/// kernel falls back to [InProcessKernelServerHost] for in-process
/// dispatch.
typedef KernelServerHostFactory = KernelServerHost Function({
  required String name,
  required String version,
  Set<ToolScope> visibility,
  bool debugMode,
});

class KernelApp {
  /// Internal — hosts use [KernelApp.boot].
  @internal
  KernelApp({
    required this.workspaceId,
    required FlowBrainWiring wiring,
    required this.agentLlmSessions,
    required this.bundleRegistry,
    required this.queryEngine,
    required this.config,
    required this.uiResource,
    required this.observability,
    required this.bundleSource,
    required this.chatLogDir,
    this.serverHostFactory,
    this.clientHost,
  }) : _wiring = wiring;

  /// Caller-supplied workspace identifier — propagates into the
  /// [FlowBrainWiring] and the bundle namespace defaults.
  final String workspaceId;

  final FlowBrainWiring _wiring;

  /// LLM provider pool. Keys are caller-supplied (typically the
  /// provider id `'anthropic'` / `'openai'` / `'gemini'`, or a
  /// composite `'<provider>:<model>'`).
  final AgentLlmSessions agentLlmSessions;

  /// Persistent registry of installed bundle directories — backs the
  /// BM25 [queryEngine].
  final KnowledgeBundleRegistry bundleRegistry;

  /// BM25 retrieval over installed bundles.
  final KnowledgeQueryEngine queryEngine;

  /// Host-supplied configuration source.
  final ConfigPort config;

  /// Host-supplied UI resource server.
  final UiResourcePort uiResource;

  /// Host-supplied telemetry sink.
  final ObservabilityPort observability;

  /// Host-supplied bundle origin.
  final BundleSourcePort bundleSource;

  /// Directory the per-agent `<chatLogDir>/<agentId>.jsonl` files
  /// live under. Hosts that do not persist chat pass any temporary
  /// directory.
  final String chatLogDir;

  /// Host-supplied [KernelServerHost] factory. When null, every
  /// [addEndpoint] call creates an [InProcessKernelServerHost] — the
  /// AppPlayer / headless / tests profile that needs no network
  /// transport. Hosts that bind MCP transports thread
  /// `McpServerKernelHost.factory` from
  /// `package:brain_kernel/mcp_host.dart` here.
  final KernelServerHostFactory? serverHostFactory;

  /// Host-supplied outbound MCP client surface. Optional — hosts that
  /// never call remote servers leave it null.
  final KernelClientHost? clientHost;

  fb.KnowledgeSystem get system => _wiring.system;

  BundleActivationRegistry get activationRegistry =>
      BundleActivationRegistry.instance;

  final Map<String, KernelEndpoint> _endpoints = <String, KernelEndpoint>{};
  final Map<String, AgentChatController> _chats =
      <String, AgentChatController>{};
  String? _activeBundleId;
  bool _disposed = false;

  // ── Boot ────────────────────────────────────────────────────────

  /// Standard boot — all FlowBrain apps converge here. Returns a
  /// fully wired [KernelApp]; hosts then attach endpoints / activate
  /// bundles / dispatch chat as the use case requires.
  static Future<KernelApp> boot({
    required String workspaceId,
    required mb.KvStoragePort kvStorage,
    Map<String, LlmPortAdapter> llmProviders = const <String, LlmPortAdapter>{},
    mb.LlmPort? fallbackLlm,
    fb.OpsRuntime? opsRuntime,
    String? bundleRegistryStorageDir,
    String chatLogDir = '.',
    ConfigPort config = NullConfig.instance,
    UiResourcePort uiResource = NullUiResource.instance,
    ObservabilityPort observability = NullObservability.instance,
    BundleSourcePort bundleSource = const InMemoryBundleSource(),
    KernelServerHostFactory? serverHostFactory,
    KernelClientHost? clientHost,
  }) async {
    final sessions = AgentLlmSessions(initial: llmProviders);
    final wiring = FlowBrainWiring(
      workspaceId: workspaceId,
      kvStoragePort: kvStorage,
      llmProviders: sessions.providers,
      fallbackLlm: fallbackLlm,
      opsRuntime: opsRuntime,
    );
    await wiring.boot();
    final registry = KnowledgeBundleRegistry(
      storageDir: bundleRegistryStorageDir ?? '.',
    );
    if (bundleRegistryStorageDir != null) {
      await registry.load();
    }
    final engine = KnowledgeQueryEngine(registry: registry);
    return KernelApp(
      workspaceId: workspaceId,
      wiring: wiring,
      agentLlmSessions: sessions,
      bundleRegistry: registry,
      queryEngine: engine,
      config: config,
      uiResource: uiResource,
      observability: observability,
      bundleSource: bundleSource,
      chatLogDir: chatLogDir,
      serverHostFactory: serverHostFactory,
      clientHost: clientHost,
    );
  }

  // ── Endpoint management ─────────────────────────────────────────

  /// Register a new endpoint. Idempotent on duplicate [label] —
  /// the existing instance is returned.
  KernelEndpoint addEndpoint({
    required String label,
    String? appName,
    String appVersion = '0.1.0',
    Set<ToolScope> visibility = const {ToolScope.external},
    bool debugMode = false,
  }) {
    final existing = _endpoints[label];
    if (existing != null) return existing;
    final factory = serverHostFactory;
    final host = factory != null
        ? factory(
            name: appName ?? label,
            version: appVersion,
            visibility: visibility,
            debugMode: debugMode,
          )
        : InProcessKernelServerHost(
            name: appName ?? label,
            version: appVersion,
            visibility: visibility,
            debugMode: debugMode,
          );
    final endpoint = KernelEndpoint(
      label: label,
      server: host,
      system: system,
    );
    _endpoints[label] = endpoint;
    return endpoint;
  }

  KernelEndpoint? endpoint(String label) => _endpoints[label];

  Iterable<KernelEndpoint> get endpoints => _endpoints.values;

  /// External dial-back spec for a transport-binding endpoint.
  ///
  /// - [endpointLabel] supplied → returns only that endpoint's spec
  ///   (or `null` when the label is unknown or its server publishes
  ///   no external surface). Pass the label whenever the host runs
  ///   multiple transport-binding endpoints (vibe_studio's multi-
  ///   domain pool, sibling-host multi-transport setups) so the
  ///   consumer dials the intended surface — picking the first
  ///   non-null spec in a multi-endpoint pool is ambiguous and
  ///   violates the no-fallback rule.
  /// - [endpointLabel] omitted → returns the first endpoint with a
  ///   non-null spec. Convenient for single-endpoint hosts (the
  ///   AppPlayer / headless / probe default) but **not safe** in
  ///   multi-endpoint pools.
  ///
  /// Returns `null` when no transport-binding endpoint exists (every
  /// endpoint is in-process). Recipes / sibling hosts use the result
  /// to dial the kernel's MCP surface (e.g. Claude Code's
  /// `--mcp-config` consumes [McpServerSpec.toMcpServersBlock]).
  McpServerSpec? hostMcpServerSpec({String? endpointLabel}) {
    if (endpointLabel != null) {
      return _endpoints[endpointLabel]?.server.externalSpec;
    }
    for (final ep in _endpoints.values) {
      final spec = ep.server.externalSpec;
      if (spec != null) return spec;
    }
    return null;
  }

  // ── Per-agent tool catalog (per-agent scoping) ──────────────────

  /// Build the `LlmTool` catalog handed to [agentId]'s
  /// `AgentChatController` / `AgentFacade.ask`. The catalog is the
  /// role-default subset of every endpoint's
  /// [KernelServerHost.toolDefinitions] (master view for `manager` /
  /// `reviewer`, the agent's `<bundleId>.*` slice for `worker`),
  /// overridden by [explicitAllowlist] when the manifest's
  /// `agents[i].tools` field is set.
  ///
  /// See `specs/platform/10-agent-scoping.md` for the sourcing thesis
  /// — agents that receive the whole catalog collapse back into a
  /// monolithic LLM, so this helper enforces the role-default
  /// boundary at the helper layer (hosts may still call it with a
  /// custom allowlist).
  ///
  /// Patterns in [explicitAllowlist] accept a trailing star
  /// (`bk.fact.*`, `<bundle>.editor.*`) and exact names.
  List<mb.LlmTool> toolsForAgent(
    String agentId, {
    required fb.AgentRole role,
    List<String>? explicitAllowlist,
    String? bundleId,
  }) {
    final allDefs = <KernelToolDef>[];
    for (final ep in _endpoints.values) {
      allDefs.addAll(ep.server.toolDefinitions);
    }
    bool matches(String name) {
      // Explicit allowlist wins.
      if (explicitAllowlist != null) {
        for (final pat in explicitAllowlist) {
          if (_globMatches(name, pat)) return true;
        }
        return false;
      }
      // Role-default subset.
      switch (role) {
        case fb.AgentRole.manager:
          // Delegation + inventory + read — NOT the full master view.
          // The manager's job is to coordinate (delegate to worker
          // siblings, inspect knowledge, surface host inventory); the
          // actual mutation / dispatch lives on the workers. Returning
          // the whole catalog here would (1) match the anti-pattern
          // spelled out in `specs/platform/10-agent-scoping.md`
          // (manager = monolithic LLM), (2) blow the token budget for
          // any non-trivial host (vibe_studio's full surface ≈ 578
          // tools), and (3) overwhelm the in-CLI LLM's tool-selection
          // accuracy. Hosts that genuinely need a wider surface pass
          // [explicitAllowlist] for the override (matching the
          // manifest's `agents[i].tools` allowlist path).
          return _managerDefaultPatterns.any((p) => _globMatches(name, p));
        case fb.AgentRole.worker:
          if (bundleId == null || bundleId.isEmpty) {
            // No bundle scope supplied → only the `bk.<bundleId>.*`
            // alias namespace is meaningful, but without a bundle we
            // expose nothing rather than leaking master-view tools.
            return false;
          }
          final domainPrefix = '$bundleId.';
          final aliasPrefix = 'bk.$bundleId.';
          return name.startsWith(domainPrefix) ||
              name.startsWith(aliasPrefix);
        case fb.AgentRole.reviewer:
          // Read-friendly subset — knowledge queries + agent history
          // surface. Excludes delegation / mutation paths so reviewers
          // do not edit the artefacts they audit.
          return name.startsWith('bk.fact.') &&
                  (name.endsWith('.query') ||
                      name.endsWith('.get') ||
                      name.endsWith('.entity.get')) ||
              name == 'bk.skill.list' ||
              name == 'bk.skill.get' ||
              name == 'bk.profile.list' ||
              name == 'bk.profile.get' ||
              name == 'bk.philosophy.list' ||
              name == 'bk.philosophy.get' ||
              name == 'bk.philosophy.get_active_id' ||
              name == 'bk.workflow.list' ||
              name == 'bk.workflow.get_run' ||
              name == 'bk.pipeline.get_run' ||
              name == 'bk.runbook.list' ||
              name == 'bk.agent.list' ||
              name == 'bk.agent.get' ||
              name == 'bk.agent.history' ||
              name == 'bk.knowledge.query';
      }
    }

    // Dedupe by name — multiple endpoints may register the same tool.
    final seen = <String>{};
    final out = <mb.LlmTool>[];
    for (final def in allDefs) {
      if (!seen.add(def.name)) continue;
      if (!matches(def.name)) continue;
      out.add(mb.LlmTool(
        name: def.name,
        description: def.description,
        parameters: def.inputSchema,
      ));
    }
    return out;
  }

  /// Default tool patterns surfaced to `manager` agents. Scoped to
  /// the framework-guaranteed `bk.*` namespace (the standard tool
  /// surface every kernel host registers via `addStandardTools`) —
  /// covers sibling delegation, knowledge read, and ops status
  /// without leaking mutation / dispatch verbs. Mutation verbs and
  /// host-specific inventory (`studio.*` for vibe_studio, `app.*`
  /// for AppPlayer, arbitrary prefixes for user hosts) are NOT
  /// included by design: the kernel cannot know which prefix a host
  /// chose. Hosts that need their manager to see those tools pass
  /// `explicitAllowlist` (e.g. `['studio.bundle.list', 'studio.search.*']`)
  /// or set the manifest's `agents[i].tools` allowlist on the bundle
  /// side.
  static const List<String> _managerDefaultPatterns = <String>[
    // Sibling delegation
    'bk.agent.list',
    'bk.agent.get',
    'bk.agent.ask',
    'bk.agent.history',
    // Knowledge read
    'bk.fact.query',
    'bk.fact.get',
    'bk.fact.entity.get',
    'bk.skill.list',
    'bk.skill.get',
    'bk.profile.list',
    'bk.profile.get',
    'bk.philosophy.list',
    'bk.philosophy.get',
    'bk.philosophy.get_active_id',
    'bk.knowledge.query',
    // Ops status (read-only)
    'bk.workflow.list',
    'bk.workflow.get_run',
    'bk.pipeline.get_run',
    'bk.runbook.list',
  ];

  static bool _globMatches(String name, String pattern) {
    if (pattern == name) return true;
    if (pattern.endsWith('.*')) {
      final prefix = pattern.substring(0, pattern.length - 1); // keep dot
      return name.startsWith(prefix);
    }
    if (pattern == '*') return true;
    return false;
  }

  // ── Activation (KernelApp-level — no endpoint binding) ──────────

  /// Activate a bundle at KernelApp scope. Registers assets in the
  /// shared [fb.KnowledgeSystem] but does NOT bind any endpoint's
  /// flow `toolDispatcher`. Use this for in-process hosts (the
  /// AppPlayer use case) that do not expose an MCP transport. Hosts
  /// that want flow steps wired to a specific endpoint use
  /// [KernelEndpoint.activate] instead.
  Future<BundleActivationResult> activate(
    mb.McpBundle bundle, {
    String? bundleIdOverride,
  }) async {
    final bundleId = bundleIdOverride ?? _resolveBundleId(bundle);
    final existing = BundleActivationRegistry.instance.get(bundleId);
    if (existing != null) {
      return BundleActivationResult(bundleId: bundleId);
    }
    final activation = BundleActivation(
      system: system,
      bundleId: bundleId,
    );
    BundleActivationRegistry.instance.register(activation);
    final result = await activation.activate(bundle);
    // Register the BM25 corpus when the bundle was loaded from disk.
    final dir = bundle.directory;
    if (dir != null) {
      try {
        await bundleRegistry.upsert(mbdPath: dir, namespace: bundleId);
        queryEngine.invalidate();
      } catch (_) {/* best-effort */}
    }
    return result;
  }

  Future<void> deactivate(String bundleId) async {
    await BundleActivationRegistry.instance.remove(bundleId);
    queryEngine.invalidate();
  }

  // ── Active context (manager vs per-domain) ──────────────────────

  /// Current active bundle id. `null` represents the master context —
  /// the manager agent has full namespace visibility and ids are not
  /// auto-prefixed.
  String? get activeBundleId => _activeBundleId;

  /// Update the active context. Hosts call this when their chrome's
  /// active selection changes. Passing `null` represents the master
  /// context (manager scope).
  void setActiveBundle(String? bundleId) {
    if (_activeBundleId == bundleId) return;
    _activeBundleId = bundleId;
  }

  /// Compose the active context's bundle prefix onto a local id.
  /// - Master context (`activeBundleId == null`) → pass-through.
  /// - Already prefixed (`<activeBundleId>.<rest>`) → pass-through.
  /// - Already qualified (`<other>.<rest>`) → pass-through (caller
  ///   addressed a different namespace explicitly).
  /// - Otherwise → `<activeBundleId>.<localId>`.
  String scopeIdFor(String localId) {
    final active = _activeBundleId;
    if (active == null) return localId;
    if (localId.startsWith('$active.')) return localId;
    if (localId.contains('.')) return localId;
    return '$active.$localId';
  }

  // ── Knowledge query (BM25) ──────────────────────────────────────

  Future<List<KnowledgeQueryHit>> query(
    String text, {
    int topK = 5,
    String? namespace,
    String? sourceId,
  }) {
    return queryEngine.query(
      text,
      topK: topK,
      namespace: namespace,
      sourceId: sourceId,
    );
  }

  // ── Chat per agent (KernelApp-level, endpoint-independent) ──────

  /// Per-agent chat controller. The controller is cached per
  /// [agentId] — the same id returns the same controller regardless
  /// of which endpoint the call originated from. Agent ids that
  /// follow the `<bundleId>.<localId>` convention naturally produce
  /// per-domain chats; ids without a prefix (e.g. `'manager'`) act
  /// as master-context chats.
  AgentChatController chat(
    String agentId, {
    SystemPromptResolver? resolver,
    List<mb.LlmTool>? tools,
    int turnLimit = 8,
  }) {
    final cached = _chats[agentId];
    if (cached != null) return cached;
    final chatLog = ChatLog.attachAgent(chatLogDir, agentId);
    final controller = AgentChatController(
      agentId: agentId,
      system: system,
      chatLog: chatLog,
      tools: tools,
      turnLimit: turnLimit,
      systemPromptResolver: resolver,
    );
    _chats[agentId] = controller;
    return controller;
  }

  Future<void> disposeChat(String agentId) async {
    final controller = _chats.remove(agentId);
    if (controller != null) await controller.dispose();
  }

  // ── Shutdown ────────────────────────────────────────────────────

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    for (final controller in _chats.values) {
      try {
        await controller.dispose();
      } catch (_) {/* best-effort */}
    }
    _chats.clear();
    for (final endpoint in List<KernelEndpoint>.from(_endpoints.values)) {
      try {
        await endpoint.shutdown();
      } catch (_) {/* best-effort */}
    }
    _endpoints.clear();
    for (final id
        in List<String>.from(BundleActivationRegistry.instance.bundleIds)) {
      try {
        await BundleActivationRegistry.instance.remove(id);
      } catch (_) {/* best-effort */}
    }
    final ch = clientHost;
    if (ch != null) {
      try {
        await ch.shutdown();
      } catch (_) {/* best-effort */}
    }
    await _wiring.dispose();
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
