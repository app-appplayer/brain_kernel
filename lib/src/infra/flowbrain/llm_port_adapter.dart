/// MOD-INFRA-007 — LlmPortAdapter.
///
/// Implements `mcp_bundle.LlmPort` on top of `mcp_llm.ClaudeProvider`.
/// FlowBrain `AgentRuntime` calls `LlmPort.complete(LlmRequest)` when an
/// agent's `ask` resolves; this adapter converts mcp_bundle's request /
/// response shape into mcp_llm's and forwards to the underlying
/// provider with the agent's pinned model.
///
/// Per agent profile uses a different model id (Opus / Sonnet / Haiku),
/// so vibe boots one adapter instance per model and exposes them through
/// `InfraPorts.llmProviders` keyed by model id.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_llm/mcp_llm.dart' as mll;

class LlmPortAdapter extends mb.LlmPort {
  LlmPortAdapter({
    required this.modelId,
    required this.apiKey,
    this.endpoint,
  });

  /// Provider model id — matches `ModelSpec.id` on the agent profile.
  final String modelId;
  final String apiKey;
  final String? endpoint;

  mll.ClaudeProvider? _provider;

  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities(
        completion: true,
        streaming: true,
        toolCalling: true,
      );

  Future<mll.ClaudeProvider> _ensureProvider() async {
    if (_provider != null) return _provider!;
    final config = mll.LlmConfiguration(
      apiKey: apiKey,
      model: modelId,
      baseUrl: endpoint == null || endpoint!.isEmpty ? null : endpoint,
    );
    final p = mll.ClaudeProvider(
      apiKey: apiKey,
      model: modelId,
      baseUrl: endpoint == null || endpoint!.isEmpty ? null : endpoint,
      config: config,
    );
    await p.initialize(config);
    _provider = p;
    return p;
  }

  /// Translate mcp_bundle's split-field request into mcp_llm's
  /// (prompt + history + parameters) form.
  mll.LlmRequest _toMllRequest(mb.LlmRequest req) {
    final prompt = req.effectivePrompt;
    // History = all messages BEFORE the trailing user prompt. The
    // effective prompt is already extracted as `prompt`, so prior
    // turns become the history list.
    final List<mll.LlmMessage> history;
    if (req.messages != null) {
      // Drop the last user message (it's the prompt). Map remaining.
      final all = req.messages!;
      final lastUserIdx = all.lastIndexWhere((m) => m.role == 'user');
      final priors =
          lastUserIdx < 0 ? all : <mb.LlmMessage>[...all]..removeAt(lastUserIdx);
      history = priors
          .map((m) => mll.LlmMessage(role: m.role, content: m.content))
          .toList(growable: false);
    } else {
      history = const <mll.LlmMessage>[];
    }
    final params = <String, dynamic>{
      if (req.systemPrompt != null) 'system': req.systemPrompt,
      if (req.maxTokens != null) 'max_tokens': req.maxTokens,
      if (req.temperature != null) 'temperature': req.temperature,
      if (req.tools != null && req.tools!.isNotEmpty)
        'tools': <Map<String, dynamic>>[
          for (final t in req.tools!)
            <String, dynamic>{
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
        ],
      if (req.options != null) ...req.options!,
    };
    return mll.LlmRequest(
      prompt: prompt,
      history: history,
      parameters: params,
    );
  }

  /// Translate mcp_llm's response back into mcp_bundle's shape, with
  /// per-call type conversion of LlmToolCall (different classes,
  /// same shape).
  mb.LlmResponse _fromMllResponse(mll.LlmResponse r) {
    final tc = r.toolCalls;
    return mb.LlmResponse(
      content: r.text,
      metadata: r.metadata,
      toolCalls: tc == null
          ? null
          : <mb.LlmToolCall>[
              for (final c in tc)
                mb.LlmToolCall(
                  id: '',
                  name: c.name,
                  arguments: c.arguments,
                ),
            ],
    );
  }

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async {
    final provider = await _ensureProvider();
    final mllRequest = _toMllRequest(request);
    final mllResponse = await provider.complete(mllRequest);
    return _fromMllResponse(mllResponse);
  }

  @override
  Stream<mb.LlmChunk> completeStream(mb.LlmRequest request) async* {
    final provider = await _ensureProvider();
    final mllRequest = _toMllRequest(request);
    await for (final chunk in provider.streamComplete(mllRequest)) {
      yield mb.LlmChunk(
        content: chunk.textChunk,
        isDone: chunk.isDone,
        toolCall: (chunk.toolCalls != null && chunk.toolCalls!.isNotEmpty)
            ? mb.LlmToolCall(
                id: '',
                name: chunk.toolCalls!.first.name,
                arguments: chunk.toolCalls!.first.arguments,
              )
            : null,
      );
    }
  }
}
