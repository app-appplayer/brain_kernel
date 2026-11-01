/// MOD-INFRA-007 — LlmPortAdapter.
///
/// Implements `mcp_bundle.LlmPort` on top of any `mcp_llm.LlmProvider`
/// (Anthropic Claude · OpenAI · Gemini · Cohere · Bedrock · Mistral ·
/// Groq · Vertex AI · custom CLI / local LLM). The adapter converts
/// mcp_bundle's request / response shape into mcp_llm's and forwards
/// to the underlying provider with the agent's pinned model.
///
/// Two construction paths:
///
/// 1. **Default** — `LlmPortAdapter(modelId, apiKey, endpoint)`. The
///    adapter creates a `mll.ClaudeProvider` lazily on first call. Same
///    signature as before — existing callers keep working.
///
/// 2. **External** — `LlmPortAdapter.fromInterface(modelId, provider)`.
///    The host instantiates any `mll.LlmProvider` (via
///    `McpLlm.registerProvider` + `McpLlm.createProvider`, or directly)
///    and hands it in. Used for non-Anthropic providers + custom LLM
///    implementations (CLI process invoke, local Ollama, etc.).
///
/// Per agent profile uses a different model id (Opus / Sonnet / Haiku
/// / gpt-5 / gemini-2.5-pro / ...), so hosts typically register one
/// adapter instance per (provider × model) pair through
/// `AgentLlmSessions`.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_llm/mcp_llm.dart' as mll;

class LlmPortAdapter extends mb.LlmPort {
  /// Default ctor — creates a `ClaudeProvider` lazily on first call.
  /// Keeps the original signature so Anthropic-only callers don't
  /// change.
  LlmPortAdapter({
    required this.modelId,
    required this.apiKey,
    this.endpoint,
    String providerName = 'anthropic',
    this.onUsage,
    this.defaultMaxTokens,
  })  : _externalProvider = null,
        _providerName = providerName;

  /// External-provider ctor — host supplies any `mll.LlmProvider`
  /// (OpenAI · Gemini · custom CLI · local Ollama · ...). The adapter
  /// uses [provider] directly and ignores `apiKey` / `endpoint`
  /// (caller already configured them when constructing [provider]).
  ///
  /// [providerName] surfaces the active provider identity on
  /// [LlmPortAdapter.providerName] so UI host can render the chat
  /// header banner / footer metadata accurately. Caller-supplied
  /// (e.g. `'openai'`, `'gemini'`, `'claude_code'`). When omitted the
  /// adapter labels itself `'external'` — accurate (kernel does not
  /// invent a provider) but generic; hosts that surface a provider
  /// banner should always pass the real id so users can see which
  /// backend their chat is dispatching through.
  LlmPortAdapter.fromInterface({
    required this.modelId,
    required mll.LlmProvider provider,
    String providerName = 'external',
    this.onUsage,
    this.defaultMaxTokens,
  })  : apiKey = '',
        endpoint = null,
        _externalProvider = provider,
        _providerName = providerName;

  /// Told the token counts of every call the provider reported them for
  /// (provider name, input, output) — a host meters cost from it.
  final void Function(String provider, int inputTokens, int outputTokens)?
      onUsage;

  /// Output limit sent when the request names none. Null leaves the choice to
  /// the provider, as before; a host that asks for long structured replies
  /// sets a roomier one (the provider's own default can cut such a reply to
  /// nothing).
  final int? defaultMaxTokens;

  /// Provider model id — matches `ModelSpec.id` on the agent profile.
  final String modelId;
  final String apiKey;
  final String? endpoint;

  /// External `LlmProvider` instance handed in via
  /// [LlmPortAdapter.fromInterface]. When non-null this is the
  /// adapter's provider and `_lazyClaude` stays null forever.
  final mll.LlmProvider? _externalProvider;

  final String _providerName;

  /// Active provider identity (`'anthropic'` for the default ctor,
  /// caller-supplied for [LlmPortAdapter.fromInterface]). UI host
  /// surfaces this on the chat panel header so the user can see
  /// which provider the manager / worker is actually dispatching
  /// through — protects against silent provider fallback the user
  /// did not opt into.
  String get providerName => _providerName;

  /// Lazily created `ClaudeProvider` for the default ctor path.
  /// Stays null when [_externalProvider] is set.
  mll.LlmProvider? _lazyClaude;

  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities(
        completion: true,
        streaming: true,
        toolCalling: true,
      );

  Future<mll.LlmProvider> _ensureProvider() async {
    final ext = _externalProvider;
    if (ext != null) return ext;
    final cached = _lazyClaude;
    if (cached != null) return cached;
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
    _lazyClaude = p;
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
      if ((req.maxTokens ?? defaultMaxTokens) != null)
        'max_tokens': req.maxTokens ?? defaultMaxTokens,
      if (req.temperature != null && _sendTemperature)
        'temperature': req.temperature,
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
    // The provider reports why it stopped in its metadata; callers that
    // check for a reply cut off at the limit read it from `finishReason`.
    final stop = r.metadata['finish_reason'] ?? r.metadata['stop_reason'];
    final input = r.metadata['input_tokens'];
    final output = r.metadata['output_tokens'];
    final usage = input is int && output is int
        ? mb.LlmUsage(inputTokens: input, outputTokens: output)
        : null;
    if (usage != null) onUsage?.call(_providerName, input as int, output as int);
    return mb.LlmResponse(
      content: r.text,
      finishReason: stop is String ? stop : null,
      usage: usage,
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

  /// False once the model has refused `temperature`; later calls omit it.
  bool _sendTemperature = true;

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async {
    final provider = await _ensureProvider();
    try {
      return _fromMllResponse(
          await provider.complete(_toMllRequest(request)));
    } catch (e) {
      // Newer models reject `temperature` outright; the same call without it
      // is valid, so retry once rather than fail the caller.
      if (!_sendTemperature ||
          request.temperature == null ||
          !e.toString().contains('`temperature` is deprecated')) {
        rethrow;
      }
      _sendTemperature = false;
      return _fromMllResponse(
          await provider.complete(_toMllRequest(request)));
    }
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
