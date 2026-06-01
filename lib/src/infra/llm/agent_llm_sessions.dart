/// MOD-INFRA-003 — AgentLlmSessions.
///
/// Per-agent / model-id-keyed pool of `LlmPortAdapter` instances. The map is
/// shaped so that FlowBrain `KnowledgeSystem.withAgents` can receive it
/// directly via `InfraPorts.llmProviders` (FR-LLM-007). The host (knowledge_builder
/// / vibe / ops / domain product) decides what key shape to use — typically
/// either the FlowBrain provider id (`'anthropic'`, `'openai'`) or a
/// composite `'<provider>:<model>'` when one provider serves several pinned
/// models. The pool itself does not interpret the key.
///
/// Agent-scoping discipline (`project_flowbrain_agent_layer` memory + spec
/// FR-LLM-006): no global single `ChatSession` exists. Each agent's `ask` /
/// chat call resolves its `LlmPort` from this pool by `agent.model.provider`
/// (or whatever key the host registered) and FlowBrain feeds the agent's
/// own systemPrompt + history into that port. One agent's settings change
/// invalidates only its adapter slot — others keep their cached provider.
library;

import 'dart:collection';

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../flowbrain/llm_port_adapter.dart';

/// Pool of model-pinned `LlmPortAdapter` instances. Hosts register an
/// adapter per key (provider id, model id, or composite — host's choice)
/// and read the resulting `Map<String, LlmPort>` view through
/// [providers] when wiring `InfraPorts`.
class AgentLlmSessions {
  AgentLlmSessions({Map<String, LlmPortAdapter>? initial})
      : _adapters = Map.of(initial ?? const {}) {
    _liveView = UnmodifiableMapView<String, mb.LlmPort>(_adapters);
  }

  final Map<String, LlmPortAdapter> _adapters;

  /// Live read-only view of [_adapters], handed to host frameworks
  /// once and re-read on every lookup. Cached so callers that capture
  /// the reference (FlowBrain's `AgentRuntime._llmProviders`) see
  /// `register` / `addAll` / `rebuild` mutations immediately.
  ///
  /// We must use [UnmodifiableMapView] (live wrapper) instead of
  /// `Map.unmodifiable` — the latter copies the entries at call time,
  /// which would freeze the host's adapter map at the moment
  /// `KernelApp.boot` forwarded it. Hosts that swap adapters after
  /// boot (Claude Code's post-transport-start `forKernel` rewrite,
  /// settings → LLM key changes) need the live view; otherwise the
  /// new adapter's `mcpServers` / catalog / permission-mode never
  /// reaches the actual `agents.ask` dispatch (per-agent-scoping
  /// cascade r5 followup, 2026-05-27).
  late final UnmodifiableMapView<String, mb.LlmPort> _liveView;

  /// Read-only view shaped for `InfraPorts.llmProviders`. Keys are exactly
  /// what the host registered (FlowBrain `_resolveLlmFor` does
  /// `_llmProviders[model.provider]` lookups). Returns the same
  /// [UnmodifiableMapView] instance on every call so downstream
  /// captures stay in sync with post-boot mutations.
  Map<String, mb.LlmPort> get providers => _liveView;

  /// All registered keys, in registration order.
  Iterable<String> get keys => _adapters.keys;

  /// `true` when [key] has an adapter installed.
  bool contains(String key) => _adapters.containsKey(key);

  /// Adapter for [key], or `null` when nothing is registered.
  LlmPortAdapter? get(String key) => _adapters[key];

  /// Register or replace the adapter at [key]. Replacing implicitly
  /// invalidates the previous adapter for that key only — other keys keep
  /// their cached underlying provider (FR-LLM-004 scope).
  void register(String key, LlmPortAdapter adapter) {
    _adapters[key] = adapter;
  }

  /// Bulk register every entry of [additions]. Same semantics as
  /// calling [register] for each entry — existing keys are replaced,
  /// new keys appended. Replaces the `flowbrain.llmProviders.addAll(...)`
  /// pattern hosts used against the raw wiring Map (FR-LLM-008).
  void addAll(Map<String, LlmPortAdapter> additions) {
    _adapters.addAll(additions);
  }

  /// Remove the adapter at [key]. No-op when absent.
  void unregister(String key) {
    _adapters.remove(key);
  }

  /// Replace the adapter at [key] by running [factory] (typically rebuilt
  /// from new apiKey / endpoint settings). Convenience over register-after-
  /// unregister so callers don't briefly leave the slot empty.
  void rebuild(String key, LlmPortAdapter Function() factory) {
    _adapters[key] = factory();
  }

  /// Drop every registered adapter. Used when the host switches workspace
  /// or re-boots wiring from scratch.
  void clear() => _adapters.clear();
}
