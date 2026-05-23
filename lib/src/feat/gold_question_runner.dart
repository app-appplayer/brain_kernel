/// Behavioural validation backbone (MOD-CORE-007).
///
/// Runs a list of "gold" questions against the current bundle's BM25
/// index and reports which expected chunks landed in the top-K. Used by
/// `AssetValidator.validateBehavioral` (DDD-05 §5).
library;

import 'package:mcp_bundle/mcp_bundle.dart';

import 'bm_index.dart';

/// One expected-output question. The bundle "passes" the question when
/// every `expectedChunkId` appears in the top-K BM25 hits for `question`,
/// optionally above [minRank].
class GoldQuestion {
  const GoldQuestion({
    required this.id,
    required this.question,
    required this.expectedChunkIds,
    this.topK = 5,
    this.minRank,
  });

  factory GoldQuestion.fromJson(Map<String, dynamic> json) {
    return GoldQuestion(
      id: json['id'] as String? ?? '',
      question: json['question'] as String? ?? '',
      expectedChunkIds:
          (json['expectedChunkIds'] as List?)?.cast<String>() ?? const [],
      topK: json['topK'] as int? ?? 5,
      minRank: json['minRank'] as int?,
    );
  }

  final String id;
  final String question;
  final List<String> expectedChunkIds;
  final int topK;

  /// `null` — any rank within `topK` counts. Otherwise the matched
  /// chunk must land at rank ≤ [minRank] (0-based).
  final int? minRank;

  Map<String, dynamic> toJson() => {
        'id': id,
        'question': question,
        'expectedChunkIds': expectedChunkIds,
        if (topK != 5) 'topK': topK,
        if (minRank != null) 'minRank': minRank,
      };
}

/// Per-question result.
class GoldVerdict {
  const GoldVerdict({
    required this.question,
    required this.passed,
    required this.hits,
    this.reason,
  });

  final GoldQuestion question;
  final bool passed;
  final List<BmHit> hits;
  final String? reason;
}

/// Stateless runner — owns no bundle reference; each call rebuilds the
/// BM25 index. A later round will let callers pass a shared [BmIndex] to
/// avoid the rebuild cost when LiveQueryPreview already keeps one warm.
class GoldQuestionRunner {
  const GoldQuestionRunner({this.config = const BmConfig()});

  final BmConfig config;

  Future<GoldVerdict> run(McpBundle bundle, GoldQuestion q) async {
    final index = BmIndex.fromBundle(bundle, config: config);
    final hits = index.query(q.question, topK: q.topK);
    return _verdict(q, hits);
  }

  Future<List<GoldVerdict>> runAll(
    McpBundle bundle,
    List<GoldQuestion> set,
  ) async {
    if (set.isEmpty) return const [];
    final index = BmIndex.fromBundle(bundle, config: config);
    return [
      for (final q in set) _verdict(q, index.query(q.question, topK: q.topK)),
    ];
  }

  GoldVerdict _verdict(GoldQuestion q, List<BmHit> hits) {
    final ranks = <String, int>{};
    for (final h in hits) {
      ranks[h.chunkId] = h.rank;
    }

    final missing = <String>[];
    final outOfRank = <String>[];
    for (final expected in q.expectedChunkIds) {
      final r = ranks[expected];
      if (r == null) {
        missing.add(expected);
      } else if (q.minRank != null && r > q.minRank!) {
        outOfRank.add('$expected@$r');
      }
    }

    final passed = missing.isEmpty && outOfRank.isEmpty;
    String? reason;
    if (!passed) {
      final parts = <String>[
        if (missing.isNotEmpty) 'missing: ${missing.join(', ')}',
        if (outOfRank.isNotEmpty)
          'out of rank: ${outOfRank.join(', ')}',
      ];
      reason = parts.join(' | ');
    }
    return GoldVerdict(
      question: q,
      passed: passed,
      hits: hits,
      reason: reason,
    );
  }
}
