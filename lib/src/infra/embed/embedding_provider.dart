/// Embedding provider — turns text into a vector. Backed by mcp_llm's
/// existing provider implementations (OpenAI / Cohere / Gemini /
/// Bedrock). Anthropic does NOT yet expose an embedding API; for
/// Anthropic-aligned embeddings, point an OpenAI-compatible provider
/// at Voyage AI's gateway via [openAiCompatibleEndpoint].
library;

import 'package:mcp_llm/mcp_llm.dart' as mll;

abstract class EmbeddingProvider {
  const EmbeddingProvider();

  /// Single-text embedding. Returns a fixed-dimension float vector.
  /// `dimensions` (when known after the first call) is exposed so the
  /// caller can record it once in the bundle's `EmbeddingConfig`.
  Future<List<double>> embed(String text);

  /// Batch embedding. Default implementation runs [embed] one-by-one;
  /// concrete providers can override with a real batch endpoint when
  /// available.
  Future<List<List<double>>> embedBatch(List<String> texts) async {
    final out = <List<double>>[];
    for (final t in texts) {
      out.add(await embed(t));
    }
    return out;
  }

  /// Identifier surfaced in the bundle's manifest (`EmbeddingConfig.model`).
  String get modelId;
}

/// Built-in providers we know how to construct from `mcp_llm`. Voyage
/// AI does not have a first-class mcp_llm provider; it works through
/// the OpenAI-compatible variant if you point [openAiCompatibleEndpoint]
/// at `https://api.voyageai.com/v1`.
enum EmbeddingProviderKind {
  openai,
  cohere,
  gemini,
  voyage; // alias for openai-compatible @ voyage's endpoint

  static EmbeddingProviderKind fromString(String s) =>
      EmbeddingProviderKind.values.firstWhere(
        (e) => e.name == s,
        orElse: () => throw ArgumentError(
          'unknown embedding provider: $s '
          '(supported: ${EmbeddingProviderKind.values.map((e) => e.name).join(', ')})',
        ),
      );
}

class _McpLlmEmbeddingProvider extends EmbeddingProvider {
  _McpLlmEmbeddingProvider({
    required this.provider,
    required String model,
  }) : modelId = model;

  final mll.LlmProvider provider;

  @override
  final String modelId;

  @override
  Future<List<double>> embed(String text) => provider.getEmbeddings(text);
}

/// Build an [EmbeddingProvider] from a provider kind + credentials.
///
/// [endpoint] overrides the provider's default base URL — use this to
/// route the OpenAI-compatible client at Voyage / Together / Groq /
/// other gateways exposing OpenAI-shaped /embeddings.
EmbeddingProvider createEmbeddingProvider({
  required EmbeddingProviderKind kind,
  required String model,
  required String apiKey,
  String? endpoint,
}) {
  final config = mll.LlmConfiguration(
    apiKey: apiKey,
    model: model,
    baseUrl: endpoint,
  );
  late final mll.LlmProvider impl;
  switch (kind) {
    case EmbeddingProviderKind.openai:
    case EmbeddingProviderKind.voyage:
      impl = mll.OpenAiProvider(
        apiKey: apiKey,
        model: model,
        baseUrl: endpoint ??
            (kind == EmbeddingProviderKind.voyage
                ? 'https://api.voyageai.com'
                : null),
        config: config,
      );
      break;
    case EmbeddingProviderKind.cohere:
      impl = mll.CohereProvider(
        apiKey: apiKey,
        model: model,
        baseUrl: endpoint,
        config: config,
      );
      break;
    case EmbeddingProviderKind.gemini:
      impl = mll.GeminiProvider(
        apiKey: apiKey,
        model: model,
        baseUrl: endpoint,
        config: config,
      );
      break;
  }
  return _McpLlmEmbeddingProvider(provider: impl, model: model);
}
