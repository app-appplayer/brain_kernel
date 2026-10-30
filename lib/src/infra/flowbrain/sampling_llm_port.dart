/// The model a skill's `llm` step uses when the host has no provider of its
/// own: the connected MCP client's, through `sampling/createMessage`
/// (platform spec 30 §8).
///
/// A provider the host configured comes first, looked up on every call so one
/// set after boot is used. With none, the client's model answers. With neither
/// the step fails — it does not answer with an empty string.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

/// Asks the connected client for one completion; throws [StateError] when no
/// client offers sampling.
typedef KernelSampling = Future<String> Function({
  required String prompt,
  String? systemPrompt,
  double? temperature,
  int maxTokens,
});

class SamplingLlmPort extends mb.LlmPort {
  SamplingLlmPort({
    required mb.LlmPort? Function() internal,
    required KernelSampling sampling,
  })  : _internal = internal,
        _sampling = sampling;

  final mb.LlmPort? Function() _internal;
  final KernelSampling _sampling;

  @override
  mb.LlmCapabilities get capabilities =>
      _internal()?.capabilities ?? const mb.LlmCapabilities.minimal();

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async {
    final internal = _internal();
    if (internal != null) return internal.complete(request);
    final system = request.systemPrompt ??
        request.messages
            ?.where((m) => m.role == 'system')
            .map((m) => m.content)
            .join('\n');
    final user = request.prompt ??
        request.messages
            ?.where((m) => m.role != 'system')
            .map((m) => m.content)
            .join('\n') ??
        '';
    final text = await _sampling(
      prompt: user,
      systemPrompt: (system == null || system.isEmpty) ? null : system,
      temperature: request.temperature,
      maxTokens: request.maxTokens ?? 2000,
    );
    return mb.LlmResponse(content: text, metadata: const {'source': 'sampling'});
  }

  @override
  Future<List<double>> embed(String text) {
    final internal = _internal();
    if (internal == null) {
      throw UnsupportedError('embeddings need a provider the host configured');
    }
    return internal.embed(text);
  }

  @override
  Future<double> similarity(String text1, String text2) {
    final internal = _internal();
    if (internal == null) {
      throw UnsupportedError('similarity needs a provider the host configured');
    }
    return internal.similarity(text1, text2);
  }
}
