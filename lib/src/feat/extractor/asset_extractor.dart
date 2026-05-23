/// LLM-backed asset extractor (MOD-FEAT-004 / DDD-11).
///
/// Translates a user intent ("derive personas from these chunks", "find
/// duplicate facts", …) into a list of [AssetProposal]s. The first cut
/// ships only the abstract interface plus a stub implementation; the
/// real `LlmAssetExtractor` lands once `mcp_llm` provider wiring
/// (LlmSessionWiring) is in.
library;

import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;

import '../../core/types.dart';
import 'reviewer_queue.dart';

/// Result of one extractor run — proposals plus an optional human-
/// readable note (e.g. "LLM not configured", "no candidates found").
class ExtractorRun {
  const ExtractorRun({
    required this.proposals,
    this.notes = const [],
  });

  final List<AssetProposal> proposals;
  final List<String> notes;

  bool get isEmpty => proposals.isEmpty;
}

/// Common surface for every asset extractor — host wires the concrete
/// implementation (`StubAssetExtractor` for now, `LlmAssetExtractor`
/// later) into [KbServerBootstrap].
abstract class AssetExtractor {
  const AssetExtractor();

  /// Propose new [category] assets from the current [bundle], optionally
  /// guided by a free-form [intent] (the user's chat turn / MCP arg).
  Future<ExtractorRun> proposeFromIntent({
    required McpBundle bundle,
    required AssetCategory category,
    String? intent,
  });
}

/// No-op default. Surfaces a clear "not configured" note so the chat /
/// MCP tool can tell the caller the LLM path isn't available yet — the
/// reviewer queue stays untouched.
class StubAssetExtractor extends AssetExtractor {
  const StubAssetExtractor();

  @override
  Future<ExtractorRun> proposeFromIntent({
    required McpBundle bundle,
    required AssetCategory category,
    String? intent,
  }) async {
    return const ExtractorRun(
      proposals: [],
      notes: <String>[
        'AssetExtractor is unconfigured — pass a real implementation '
            'to KbServerBootstrap.extractor before calling kb_propose_*. '
            'Use kb_add_<category> with a hand-crafted asset payload in '
            'the meantime.',
      ],
    );
  }
}
