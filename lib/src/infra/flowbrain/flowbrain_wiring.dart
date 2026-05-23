/// MOD-RUNTIME-002 — knowledge_builder side FlowBrain lifecycle.
///
/// Phase 0 scaffold. The current chunk → write pipeline does not need
/// FlowBrain — this wiring exists so the next iteration (4-axis
/// extraction, agent-driven knowledge composition, OpsFacade-backed
/// bundle round-tripping) can plug in without re-engineering the
/// dependency graph.
///
/// Mirrors the vibe wiring (MOD-INFRA-006) shape: holds one
/// `KnowledgeSystem`, exposes the curated facade getters, and stays
/// idempotent on re-boot. The two tools deliberately keep their own
/// copies — coupling them through a shared library would force every
/// future API drift to ripple twice.
library;

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

class FlowBrainWiring {
  FlowBrainWiring({
    required this.workspaceId,
    required this.kvStoragePort,
    this.llmProviders = const <String, mb.LlmPort>{},
    this.fallbackLlm,
    this.opsRuntime,
  });

  /// Workspace identifier — typically `'knowledge_builder'` or a
  /// per-build scratch id. Surfaced to the agent registry if any
  /// future agent path needs it.
  final String workspaceId;

  final mb.KvStoragePort kvStoragePort;

  /// Optional — knowledge_builder runs without LLM in the current
  /// chunk-only flow. Leave empty until embedding / extraction agents
  /// land.
  final Map<String, mb.LlmPort> llmProviders;
  final mb.LlmPort? fallbackLlm;

  /// Optional OpsRuntime for bundle round-tripping (load-validate-export
  /// cycles). Leave null until the bundle ops flow is wired.
  final fb.OpsRuntime? opsRuntime;

  fb.KnowledgeSystem? _system;
  bool _booted = false;

  fb.KnowledgeSystem get system {
    final s = _system;
    if (s == null) {
      throw StateError(
        'FlowBrainWiring not booted — call boot() first',
      );
    }
    return s;
  }

  bool get isBooted => _booted;

  Future<void> boot() async {
    if (_booted) return;

    // Single KvEthosStoreAdapter shared between PhilosophyEngine
    // (initialize / runtime read path) and `KnowledgeSystem.ethosStore`
    // (HostBundleActivationContext.registerPhilosophy write path).
    // Same instance so both reads/writes hit the same KV state.
    final ethosStore = fb.KvEthosStoreAdapter(storage: kvStoragePort);

    final infra = fb.InfraPorts(
      knowledgePorts: const fb.KnowledgePorts().copyWith(
        kvStorage: kvStoragePort,
        ethosStore: ethosStore,
      ),
      llmProviders: llmProviders,
    );

    // L1 SkillRuntime — memory-backed registry with stub LlmPort /
    // McpPort. Required so `system.skill.execute` works + bundle
    // activation can register skills through `SkillRuntime.registry`.
    // The skill registry stays separate from the LLM call layer —
    // host `flowbrain.llmProviders` continues to drive agent dispatch;
    // SkillPorts only handles in-skill LLM steps (which can be stubbed
    // until a real adapter is wired).
    final skillFallbackLlm = fallbackLlm ??
        (llmProviders.isNotEmpty
            ? llmProviders.values.first
            : mb.StubLlmPort());
    final skillRegistry = fb.MemorySkillRegistry();
    final skillRuntime = fb.SkillRuntime(
      registry: skillRegistry,
      ports: fb.SkillPorts(
        llm: skillFallbackLlm,
        mcp: mb.StubMcpPort(),
      ),
    );

    // L2 ProfileRuntime — registry-backed pool with stub engines.
    // Required so `system.profile.register / list / getProfile` work
    // (otherwise `Bad state: ProfileRuntime not configured`).
    final profileRegistry = fb.ProfileRegistry();
    final profileRuntime = fb.ProfileRuntime(
      registry: profileRegistry,
      engines: fb.EnginePorts.stub(),
    );

    // L3 PhilosophyEngine — KV-backed ethos store on the shared
    // KvStoragePort. `initialize()` seeds stock ethos when empty
    // (autoSeedEthos: true is default).
    final philosophyEngine = fb.PhilosophyEngine(
      ethosStore: ethosStore,
    );
    await philosophyEngine.initialize();

    // Default OpsRuntime — stub ports across the board (facts /
    // claims / skill / appraisal / decision / metrics / mcp / llm /
    // philosophy) + shared KvStoragePort. Built-in workflows
    // (skill_build / profile_build / bundle_build) and pipelines
    // (ingest / curation / summary_refresh / pattern_mining /
    // index_rebuild) auto-register from `OpsRuntime.fromConsumedPorts`.
    // Hosts that wire real ports (production data path) override by
    // passing their own `opsRuntime` to FlowBrainWiring's ctor.
    final effectiveOpsRuntime = opsRuntime ??
        fb.OpsRuntime.fromConsumedPorts(
          fb.ConsumedOpsPorts(
            facts: mb.StubFactsPort(),
            claims: mb.StubClaimsPort(),
            skillRuntime: mb.StubSkillRuntimePort(),
            appraisal: mb.StubAppraisalPort(),
            decision: mb.StubDecisionPort(),
            metrics: mb.StubMetricsPort(),
            mcp: mb.StubMcpPort(),
            llm: mb.StubLlmPort(),
            philosophy: mb.StubPhilosophyPort(),
            kvStorage: kvStoragePort,
          ),
        );

    _system = fb.KnowledgeSystem.withAgents(
      infraPorts: infra,
      llm: fallbackLlm ??
          (llmProviders.isNotEmpty ? llmProviders.values.first : null),
      llmProviders: llmProviders,
      skillRuntime: skillRuntime,
      profileRuntime: profileRuntime,
      philosophyEngine: philosophyEngine,
      opsRuntime: effectiveOpsRuntime,
    );
    _booted = true;
  }

  Future<void> dispose() async {
    if (!_booted) return;
    try {
      await _system?.shutdown();
    } catch (_) {/* best-effort */}
    _system = null;
    _booted = false;
  }

  // Curated facade getters (mirror vibe).
  fb.AgentFacade get agents => system.agents;
  fb.FactFacade get facts => system.facts;
  fb.SkillFacade get skill => system.skill;
  fb.ProfileFacade get profile => system.profile;
  fb.PhilosophyFacade get philosophy => system.philosophy;
  fb.OpsFacade get ops => system.ops;
}
