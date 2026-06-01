/// `BundleActivation` — canonical asset registration standard inside
/// the kernel.
///
/// Takes a single bundle manifest (`McpBundle`) and registers the
/// six asset categories (skill / profile / philosophy / fact / flow
/// / agent — tools belong to the host MCP surface and are excluded)
/// into the `KnowledgeSystem` facades in one call.
///
/// Single standard API every host uses — vibe_studio · AppPlayer ·
/// any future host. Same path for seed bundles, user-tab activation,
/// external bundle install, and AppPlayer bundle-app install.
///
/// **Per-bundle isolation** — each instance owns a private catalog
/// (`_registered*Ids`). Lookup methods (`ownsX(id)`) only see the
/// instance's own ids → cross-bundle access is blocked. The global
/// facade registry is shared by all bundles, but a single
/// BundleActivation view scopes to its own namespace.
///
/// Registration policy:
/// - Every asset id is prefixed with `<bundleId>.<asset.id>` to
///   avoid collisions across bundles.
/// - mb.* (bundle schema) → kernel facade type conversion (toJson /
///   fromJson where compatible, manual adapters where the shapes
///   diverge).
/// - Per-entry try/catch — a single failing asset does not abort
///   the rest of the activation.
///
/// Dependencies:
/// - `KnowledgeSystem` — facade pool (facts / skill / profile /
///   philosophy / agents / ethosStore / opsRuntime).
/// - `KernelServerHost` — needed when a registered flow's
///   `toolDispatcher` closure has to call `boot.callTool`.
library;

import 'dart:convert';

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_knowledge_ops/mcp_knowledge_ops.dart' as ops;

import '../infra/flowbrain/flow_definition_workflow.dart';
import 'host/kernel_envelope.dart';
import 'host/kernel_server_host.dart';

/// Result of an `activate` call — per-category counts plus per-entry
/// error messages collected during the run.
class BundleActivationResult {
  BundleActivationResult({required this.bundleId});

  final String bundleId;
  int skills = 0;
  int profiles = 0;
  int philosophies = 0;
  int facts = 0;
  int flows = 0;
  int agents = 0;
  int behaviors = 0;
  final List<String> errors = <String>[];

  int get totalRegistered =>
      skills + profiles + philosophies + facts + flows + agents + behaviors;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bundleId': bundleId,
        'skills': skills,
        'profiles': profiles,
        'philosophies': philosophies,
        'facts': facts,
        'flows': flows,
        'agents': agents,
        'errors': errors,
      };
}

/// Per-bundle activation: activate / catalog / tear-down standard.
class BundleActivation {
  BundleActivation({
    required this.system,
    required this.bundleId,
    this.boot,
    this.behaviorStore,
  });

  /// Optional shared state store for activated behavior definitions. When a
  /// host injects a durable store (e.g. KV-backed), suspended behavior runs
  /// survive restarts (the runbook profile). Defaults to a per-behavior
  /// in-memory store (the ephemeral/flow profile).
  final ops.StateStore? behaviorStore;

  /// Asset registration target — the kernel's KnowledgeSystem.
  final fb.KnowledgeSystem system;

  /// Bundle namespace prefix. Every registered asset id is
  /// `<bundleId>.<id>`.
  final String bundleId;

  /// Used by FlowDefinitionWorkflow closures (`toolDispatcher`,
  /// `skillRunner`, ...). When null, flow registration still works
  /// but action/api steps throw at run time.
  final KernelServerHost? boot;

  // ── Per-bundle catalog ────────────────────────────────────────
  final List<String> _registeredSkills = <String>[];
  final List<String> _registeredProfiles = <String>[];
  final List<String> _registeredPhilosophies = <String>[];
  final List<String> _registeredFacts = <String>[];
  final List<String> _registeredFlows = <String>[];
  final List<String> _registeredAgents = <String>[];
  final List<String> _registeredBehaviors = <String>[];

  List<String> get registeredSkills => List.unmodifiable(_registeredSkills);
  List<String> get registeredProfiles =>
      List.unmodifiable(_registeredProfiles);
  List<String> get registeredPhilosophies =>
      List.unmodifiable(_registeredPhilosophies);
  List<String> get registeredFacts => List.unmodifiable(_registeredFacts);
  List<String> get registeredFlows => List.unmodifiable(_registeredFlows);
  List<String> get registeredAgents => List.unmodifiable(_registeredAgents);
  List<String> get registeredBehaviors =>
      List.unmodifiable(_registeredBehaviors);

  // ── Activate ──────────────────────────────────────────────────

  Future<BundleActivationResult> activate(mb.McpBundle bundle) async {
    final result = BundleActivationResult(bundleId: bundleId);

    for (final s in bundle.skills?.modules ?? const <mb.SkillModule>[]) {
      try {
        final id = await registerSkill(s);
        _registeredSkills.add(id);
        result.skills++;
      } catch (e) {
        result.errors.add('skill ${s.id}: $e');
      }
    }
    for (final p in bundle.profiles?.profiles ??
        const <mb.ProfileDefinition>[]) {
      try {
        final id = registerProfile(p);
        _registeredProfiles.add(id);
        result.profiles++;
      } catch (e) {
        result.errors.add('profile ${p.id}: $e');
      }
    }
    for (final ph
        in bundle.philosophy?.philosophies ?? const <mb.Philosophy>[]) {
      try {
        final id = await registerPhilosophy(ph);
        _registeredPhilosophies.add(id);
        result.philosophies++;
      } catch (e) {
        result.errors.add('philosophy ${ph.id}: $e');
      }
    }
    for (final f in bundle.facts?.facts ?? const <mb.Fact>[]) {
      try {
        final id = await registerFact(f);
        _registeredFacts.add(id);
        result.facts++;
      } catch (e) {
        result.errors.add('fact ${f.id ?? "(no-id)"}: $e');
      }
    }
    for (final fl in bundle.flow?.flows ?? const <mb.FlowDefinition>[]) {
      try {
        final id = registerFlow(fl);
        _registeredFlows.add(id);
        result.flows++;
      } catch (e) {
        result.errors.add('flow ${fl.id}: $e');
      }
    }
    for (final ag
        in bundle.agents?.agents ?? const <mb.AgentDefinition>[]) {
      try {
        final id = await registerAgent(ag);
        _registeredAgents.add(id);
        result.agents++;
      } catch (e) {
        result.errors.add('agent ${ag.id}: $e');
      }
    }
    for (final def in bundle.behavior?.definitions ??
        const <mb.BehaviorDefinition>[]) {
      try {
        final id = registerBehavior(def);
        _registeredBehaviors.add(id);
        result.behaviors++;
      } catch (e) {
        result.errors.add('behavior ${def.id}: $e');
      }
    }
    return result;
  }

  // ── Per-bundle lookup (isolation) ────────────────────────────
  //
  // The facade's global registry is shared, but this instance's
  // ownership view only contains ids it itself registered. Hosts
  // dispatching through a specific BundleActivation get isolation
  // by construction.

  bool ownsSkill(String exposedId) => _registeredSkills.contains(exposedId);
  bool ownsProfile(String exposedId) =>
      _registeredProfiles.contains(exposedId);
  bool ownsPhilosophy(String exposedId) =>
      _registeredPhilosophies.contains(exposedId);
  bool ownsFact(String exposedId) => _registeredFacts.contains(exposedId);
  bool ownsFlow(String exposedId) => _registeredFlows.contains(exposedId);
  bool ownsAgent(String exposedId) => _registeredAgents.contains(exposedId);
  bool ownsBehavior(String exposedId) =>
      _registeredBehaviors.contains(exposedId);

  // ── Tear-down ─────────────────────────────────────────────────

  Future<void> unregisterAll() async {
    for (final id in _registeredProfiles) {
      try {
        system.profile.unregister(id);
      } catch (_) {/* best-effort */}
    }
    final skillRuntime = system.skillRuntime;
    if (skillRuntime != null) {
      for (final id in _registeredSkills) {
        try {
          await skillRuntime.registry.unregisterSkill(id);
        } catch (_) {/* best-effort */}
      }
    }
    final opsRuntime = system.opsRuntime;
    if (opsRuntime != null) {
      for (final id in _registeredFlows) {
        opsRuntime.workflowRegistry.remove(id);
      }
      for (final id in _registeredBehaviors) {
        opsRuntime.behaviorRegistry.remove(id);
      }
    }
    if (_registeredFacts.isNotEmpty) {
      try {
        await system.facts.deleteFacts(_registeredFacts);
      } catch (_) {/* best-effort */}
    }
    // EthosStorePort has no delete API — drop tracking only.
    // Agent tear-down is the host's job (AgentHost.shared lives in
    // base; kernel has no handle to it).
    _registeredSkills.clear();
    _registeredProfiles.clear();
    _registeredPhilosophies.clear();
    _registeredFacts.clear();
    _registeredFlows.clear();
    _registeredAgents.clear();
    _registeredBehaviors.clear();
  }

  // ── Per-category registration (public — host wrappers call these) ─

  /// mb.SkillModule → SkillBundle (manifest + best-effort sequential
  /// procedures). mb's graph-shaped steps (`step.next[]`) are
  /// flattened to mcp_skill's sequential `order` since the runtime
  /// model is sequential.
  Future<String> registerSkill(mb.SkillModule s) async {
    final runtime = system.skillRuntime;
    if (runtime == null) {
      throw StateError('SkillRuntime not configured');
    }
    final exposedId = '$bundleId.${s.id}';
    final manifest = fb.SkillManifest(
      id: exposedId,
      name: s.name,
      version: s.version,
      provider: s.provider ?? bundleId,
      description: s.description,
      capabilities: s.capabilities.isEmpty ? null : s.capabilities,
    );
    final procedures = <fb.Procedure>[];
    for (final proc in s.procedures) {
      try {
        final stepJson = <Map<String, dynamic>>[];
        for (var i = 0; i < proc.steps.length; i++) {
          final st = proc.steps[i];
          stepJson.add(<String, dynamic>{
            'id': st.id,
            'order': i + 1,
            'name': st.id,
            'action': st.action.toJson(),
            if (st.condition != null) 'condition': st.condition,
          });
        }
        procedures.add(fb.Procedure.fromJson(<String, dynamic>{
          'id': proc.id,
          'name': proc.name,
          'description': proc.description,
          'steps': stepJson,
        }));
      } catch (_) {/* skip per-procedure failure */}
    }
    final bundle = fb.SkillBundle(
      schemaVersion: '0.1.0',
      manifest: manifest,
      procedures: procedures,
    );
    await runtime.registry.registerSkill(bundle);
    return exposedId;
  }

  /// mb.ProfileDefinition → kernel Profile via toJson/fromJson (the
  /// two schemas share id / name / description / version / sections /
  /// capabilities / metadata).
  String registerProfile(mb.ProfileDefinition p) {
    final exposedId = '$bundleId.${p.id}';
    final json = p.toJson();
    json['id'] = exposedId;
    final kernelProfile = fb.Profile.fromJson(json);
    system.profile.register(kernelProfile);
    return exposedId;
  }

  /// mb.Philosophy → EthosRecord. The runtime fields (statement /
  /// rationale / examples / ...) are stuffed into the EthosRecord
  /// `payload` since EthosRecord keeps that opaque.
  Future<String> registerPhilosophy(mb.Philosophy ph) async {
    final store = system.ethosStore;
    if (store == null) throw StateError('EthosStorePort not wired');
    final exposedId = '$bundleId.${ph.id}';
    final record = mb.EthosRecord(
      id: exposedId,
      name: ph.name,
      version: '1.0.0',
      payload: <String, dynamic>{
        'statement': ph.statement,
        if (ph.rationale != null) 'rationale': ph.rationale,
        if (ph.examples.isNotEmpty) 'examples': ph.examples,
        if (ph.counterexamples.isNotEmpty)
          'counterexamples': ph.counterexamples,
        if (ph.school != null) 'school': ph.school,
        if (ph.confidence != null) 'confidence': ph.confidence,
        if (ph.metadata.isNotEmpty) 'metadata': ph.metadata,
      },
      createdAt: DateTime.now(),
    );
    await store.putEthos(record);
    return exposedId;
  }

  /// mb.Fact (SVO triple) → FactRecord. The bundle's
  /// subject/predicate/object goes into FactRecord `content` so the
  /// triple semantics survive `FactFacade.queryFacts`; `entityId =
  /// subject` so entity-scoped queries work without a hop.
  Future<String> registerFact(mb.Fact f) async {
    final factId = f.id?.trim().isNotEmpty == true
        ? f.id!
        : '${f.subject}_${f.predicate}_${f.object}'.replaceAll(' ', '_');
    final exposedId = '$bundleId.$factId';
    final record = mb.FactRecord(
      id: exposedId,
      workspaceId: bundleId,
      type: f.predicate,
      entityId: f.subject,
      content: <String, dynamic>{
        'subject': f.subject,
        'predicate': f.predicate,
        'object': f.object,
        if (f.source != null) 'source': f.source,
      },
      confidence: f.confidence,
      createdAt: DateTime.now(),
    );
    await system.facts.writeFacts(<mb.FactRecord>[record]);
    return exposedId;
  }

  /// mb.FlowDefinition → FlowDefinitionWorkflow factory inserted into
  /// `OpsRuntime.workflowRegistry`. Step execution wires through
  /// `boot.server.callTool` / `SkillFacade.execute` / LlmPort /
  /// recursive `OpsFacade.runWorkflow`.
  String registerFlow(mb.FlowDefinition fl) {
    final opsRuntime = system.opsRuntime;
    if (opsRuntime is! ops.OpsRuntime) {
      throw StateError('OpsRuntime not configured');
    }
    final exposedId = '$bundleId.${fl.id}';
    final namespacedFlow = mb.FlowDefinition(
      id: exposedId,
      name: fl.name,
      description: fl.description,
      trigger: fl.trigger,
      steps: fl.steps,
      inputs: fl.inputs,
      output: fl.output,
      timeoutMs: fl.timeoutMs,
      retry: fl.retry,
    );
    final b = boot;
    opsRuntime.workflowRegistry[exposedId] = () => FlowDefinitionWorkflow(
          namespacedFlow,
          toolDispatcher: b == null
              ? null
              : (tool, args) => b.callTool(tool, args),
          skillRunner: (skillId, inputs) async {
            final result = await system.skill.execute(skillId, inputs);
            return result;
          },
          subFlowRunner: (flowId, subInput) async {
            final handle =
                await system.ops.runWorkflow(flowId, subInput);
            return <String, dynamic>{
              'runId': handle.runId,
              'status': handle.status,
              if (handle.output != null) 'output': handle.output,
              if (handle.error != null) 'error': handle.error,
            };
          },
        );
    return exposedId;
  }

  /// mb.BehaviorDefinition → unified behavior engine, registered in
  /// `OpsRuntime.behaviorRegistry`. The bundle's declarative steps map to
  /// engine steps; the action dispatcher routes `tool` invocations through
  /// the host endpoint (`boot.callTool`) and `skill` invocations through
  /// `SkillFacade.execute` — mirroring how flow steps dispatch. Uses an
  /// ephemeral state store; a durable store is the runbook profile.
  String registerBehavior(mb.BehaviorDefinition def) {
    final opsRuntime = system.opsRuntime;
    if (opsRuntime is! ops.OpsRuntime) {
      throw StateError('OpsRuntime not configured');
    }
    final exposedId = '$bundleId.${def.id}';
    final steps = def.steps
        .map((s) => ops.BehaviorStep(
              id: s.id,
              action: s.action != null
                  ? ops.BehaviorAction.fromJson(s.action!)
                  : null,
              when: s.when,
              then: s.then,
              dependsOn: s.dependsOn,
              onFailure: s.onFailure,
            ))
        .toList();
    final b = boot;
    // One shared store per registered behavior so run + resume across
    // separate tool calls see the same suspended run.
    final store = behaviorStore ?? ops.EphemeralStateStore();
    opsRuntime.behaviorRegistry[exposedId] = () => ops.BehaviorRunnable(
          ops.BehaviorEngine(
            store: store,
            dispatch: (action, state) async {
              if (action.kind == 'skill') {
                final dynamic r =
                    await system.skill.execute(action.ref, action.args);
                // A Map result merges into state so later guards can read its
                // keys; anything else is parked under `result`.
                return r is Map
                    ? Map<String, dynamic>.from(r)
                    : <String, dynamic>{'result': r};
              }
              if (b == null) {
                throw StateError('tool dispatch not wired (${action.ref})');
              }
              final r = await b.callTool(action.ref, action.args);
              return _behaviorToolOutput(r);
            },
          ),
          steps,
        );
    return exposedId;
  }

  /// mb.AgentDefinition → `KnowledgeSystem.agents.createAgent`.
  Future<String> registerAgent(mb.AgentDefinition a) async {
    final exposedId = '$bundleId.${a.id}';
    await system.agents.createAgent(
      id: exposedId,
      displayName: a.name.isNotEmpty ? a.name : exposedId,
      role: _agentRoleFromString(a.role),
      model: fb.ModelSpec(
        provider: a.model?.provider ?? 'anthropic',
        model: a.model?.model ?? 'claude-haiku-4-5-20251001',
      ),
      workspaceId: bundleId,
      systemPrompt: a.systemPrompt ?? '',
    );
    return exposedId;
  }

  static fb.AgentRole _agentRoleFromString(String? role) {
    switch (role) {
      case 'manager':
        return fb.AgentRole.manager;
      case 'worker':
        return fb.AgentRole.worker;
      case 'reviewer':
        return fb.AgentRole.reviewer;
      default:
        return fb.AgentRole.worker;
    }
  }
}

/// Surface a tool result into behavior-engine state: parse the first text
/// content as JSON and, if it is a map, merge its keys so a later step's
/// `when` guard can read them (e.g. `hasHardViolation` from
/// `bk.philosophy.check`). Non-JSON / non-map results park under `result`.
Map<String, dynamic> _behaviorToolOutput(KernelToolResult r) {
  for (final c in r.content) {
    if (c is KernelTextContent) {
      try {
        final decoded = jsonDecode(c.text);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {/* not JSON — fall through */}
    }
  }
  return <String, dynamic>{'result': r};
}

/// Process-singleton multi-instance hub.
///
/// Holds every active `BundleActivation` — host, built-ins, external
/// bundles. All instances stay alive so background workflows
/// (scheduler / processes / agents) keep running regardless of which
/// tab the chrome currently shows.
///
/// "UI focus" / "active tab" is a chrome/base concern, not a kernel
/// concern — the kernel only provides per-bundle isolation
/// (`register` / `get` / `remove`) and union/lookup views
/// (`all*` / `findOwnerOf*`). Whoever wants "the currently-visible
/// bundle's catalog" must resolve `bundleId` themselves (via
/// `tab.chatAgentId` prefix or a base-side map) and call
/// `registry.get(bundleId)`.
///
/// Usage paths:
/// - Host activation: `BundleActivationRegistry.instance.register(...)`.
/// - Tab close: `await BundleActivationRegistry.instance.remove(bundleId)`.
/// - Per-bundle lookup: `registry.get(bundleId)` (chat dispatch / etc.).
/// - Host-wide lookup: iterate `registry.all` (admin / debug view).
class BundleActivationRegistry {
  BundleActivationRegistry._();

  static final BundleActivationRegistry instance =
      BundleActivationRegistry._();

  final Map<String, BundleActivation> _activations =
      <String, BundleActivation>{};

  /// Every active instance (multi).
  Iterable<BundleActivation> get all => _activations.values;

  /// Registered bundle ids.
  List<String> get bundleIds => List.unmodifiable(_activations.keys);

  BundleActivation? get(String bundleId) => _activations[bundleId];

  /// Register a new BundleActivation. Returns the existing instance
  /// when the same bundleId is already registered (idempotent — the
  /// multi-tab case where the same bundle is opened twice).
  BundleActivation register(BundleActivation activation) {
    final existing = _activations[activation.bundleId];
    if (existing != null) return existing;
    _activations[activation.bundleId] = activation;
    return activation;
  }

  /// Remove an instance and tear it down.
  Future<void> remove(String bundleId) async {
    final a = _activations.remove(bundleId);
    if (a != null) {
      try {
        await a.unregisterAll();
      } catch (_) {/* best-effort */}
    }
  }

  /// Admin / host view — union of every BundleActivation's catalog.
  /// Used by the host chat panel where the full pool is in scope.
  List<String> get allSkills => <String>[
        for (final a in _activations.values) ...a.registeredSkills,
      ];
  List<String> get allProfiles => <String>[
        for (final a in _activations.values) ...a.registeredProfiles,
      ];
  List<String> get allPhilosophies => <String>[
        for (final a in _activations.values) ...a.registeredPhilosophies,
      ];
  List<String> get allFacts => <String>[
        for (final a in _activations.values) ...a.registeredFacts,
      ];
  List<String> get allFlows => <String>[
        for (final a in _activations.values) ...a.registeredFlows,
      ];
  List<String> get allAgents => <String>[
        for (final a in _activations.values) ...a.registeredAgents,
      ];

  /// Find which BundleActivation registered the given exposed id.
  /// Useful to detect cross-bundle isolation violations.
  BundleActivation? findOwnerOfSkill(String exposedId) {
    for (final a in _activations.values) {
      if (a.ownsSkill(exposedId)) return a;
    }
    return null;
  }

  BundleActivation? findOwnerOfAgent(String exposedId) {
    for (final a in _activations.values) {
      if (a.ownsAgent(exposedId)) return a;
    }
    return null;
  }
}
