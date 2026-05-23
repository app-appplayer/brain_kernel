/// In-memory BM25 ranker — backbone shared by `LiveQueryPreview` and
/// `GoldQuestionRunner`. Operates over the chunks held by a bundle's
/// [KnowledgeSection]; other assets (skill descriptions, philosophy
/// statements, ...) are out of scope for this first cut.
///
/// Implements the search surface described in DDD-14 §2.
library;

import 'dart:math' as math;

import 'package:mcp_bundle/mcp_bundle.dart';

/// Tunable parameters of the BM25 scoring function.
class BmConfig {
  const BmConfig({
    this.k1 = 1.5,
    this.b = 0.75,
    this.snippetWindow = 8,
    this.snippetBoldOpen = '**',
    this.snippetBoldClose = '**',
  });

  final double k1;
  final double b;
  final int snippetWindow;
  final String snippetBoldOpen;
  final String snippetBoldClose;
}

/// One ranked search hit.
class BmHit {
  const BmHit({
    required this.chunkId,
    required this.sourceId,
    required this.score,
    required this.rank,
    required this.snippet,
    required this.metadata,
  });

  final String chunkId;
  final String sourceId;
  final double score;
  final int rank;
  final String snippet;
  final Map<String, dynamic> metadata;
}

/// One indexed document — internal storage.
class _IndexedDoc {
  _IndexedDoc({
    required this.chunkId,
    required this.sourceId,
    required this.tokens,
    required this.text,
    required this.metadata,
  });

  final String chunkId;
  final String sourceId;
  final List<String> tokens;
  final String text;
  final Map<String, dynamic> metadata;

  late final Map<String, int> termFreq = _buildTermFreq();

  Map<String, int> _buildTermFreq() {
    final out = <String, int>{};
    for (final t in tokens) {
      out[t] = (out[t] ?? 0) + 1;
    }
    return out;
  }
}

/// In-memory BM25 index.
class BmIndex {
  BmIndex._({
    required List<_IndexedDoc> docs,
    required Map<String, int> docFreq,
    required double avgDocLen,
    required BmConfig config,
  })  : _docs = docs,
        _docFreq = docFreq,
        _avgDocLen = avgDocLen,
        _config = config;

  /// Build a fresh index from [bundle]'s `KnowledgeSection`.
  factory BmIndex.fromBundle(
    McpBundle bundle, {
    BmConfig config = const BmConfig(),
  }) {
    final docs = _collectDocs(bundle);
    return BmIndex._(
      docs: docs,
      docFreq: _buildDocFreq(docs),
      avgDocLen: _avgLen(docs),
      config: config,
    );
  }

  List<_IndexedDoc> _docs;
  Map<String, int> _docFreq;
  double _avgDocLen;
  final BmConfig _config;

  /// Discard the current corpus and rebuild from [bundle]. Cheap enough
  /// to run on every canonical change for project-sized corpora; a more
  /// granular incremental update is left for later rounds.
  void rebuild(McpBundle bundle) {
    _docs = _collectDocs(bundle);
    _docFreq = _buildDocFreq(_docs);
    _avgDocLen = _avgLen(_docs);
  }

  /// Run [text] against the index and return up to [topK] hits ordered
  /// by descending score.
  List<BmHit> query(String text, {int topK = 5}) {
    if (_docs.isEmpty) return const [];
    final qTokens = _tokenize(text);
    if (qTokens.isEmpty) return const [];

    final scored = <(double score, _IndexedDoc doc)>[];
    for (final doc in _docs) {
      final score = _score(qTokens, doc);
      if (score > 0) scored.add((score, doc));
    }
    scored.sort((a, b) => b.$1.compareTo(a.$1));

    final hits = <BmHit>[];
    for (var i = 0; i < scored.length && i < topK; i++) {
      final (score, doc) = scored[i];
      hits.add(BmHit(
        chunkId: doc.chunkId,
        sourceId: doc.sourceId,
        score: score,
        rank: i,
        snippet: _buildSnippet(qTokens, doc),
        metadata: doc.metadata,
      ));
    }
    return hits;
  }

  /// Index statistics — handy for the LiveQueryPreview footer.
  Map<String, dynamic> stats() => {
        'docCount': _docs.length,
        'avgDocLen': _avgDocLen,
        'vocabSize': _docFreq.length,
      };

  // ── BM25 scoring ────────────────────────────────────────────────────

  double _score(List<String> qTokens, _IndexedDoc doc) {
    final n = _docs.length;
    final dl = doc.tokens.length.toDouble();
    final norm = 1 - _config.b + _config.b * (dl / (_avgDocLen == 0 ? 1 : _avgDocLen));
    var total = 0.0;
    for (final t in qTokens) {
      final df = _docFreq[t] ?? 0;
      if (df == 0) continue;
      final idf = math.log(((n - df + 0.5) / (df + 0.5)) + 1);
      final tf = doc.termFreq[t] ?? 0;
      if (tf == 0) continue;
      total += idf * ((tf * (_config.k1 + 1)) / (tf + _config.k1 * norm));
    }
    return total;
  }

  String _buildSnippet(List<String> qTokens, _IndexedDoc doc) {
    final qSet = qTokens.toSet();
    final words = _splitText(doc.text);
    if (words.isEmpty) return '';

    var matchIdx = -1;
    for (var i = 0; i < words.length; i++) {
      if (qSet.contains(words[i].toLowerCase())) {
        matchIdx = i;
        break;
      }
    }
    final centre = matchIdx >= 0 ? matchIdx : 0;
    final start = math.max(0, centre - _config.snippetWindow);
    final end = math.min(words.length, centre + _config.snippetWindow + 1);

    final buffer = StringBuffer();
    for (var i = start; i < end; i++) {
      if (i > start) buffer.write(' ');
      final w = words[i];
      if (qSet.contains(w.toLowerCase())) {
        buffer
          ..write(_config.snippetBoldOpen)
          ..write(w)
          ..write(_config.snippetBoldClose);
      } else {
        buffer.write(w);
      }
    }
    return buffer.toString();
  }

  // ── Static builders ─────────────────────────────────────────────────

  static List<_IndexedDoc> _collectDocs(McpBundle bundle) {
    final out = <_IndexedDoc>[];
    for (final src in bundle.knowledge?.sources ?? const []) {
      for (final doc in src.documents) {
        out.add(_IndexedDoc(
          chunkId: doc.id,
          sourceId: src.id,
          tokens: _tokenize(doc.content),
          text: doc.content,
          metadata: Map<String, dynamic>.from(doc.metadata),
        ));
      }
    }
    return out;
  }

  static Map<String, int> _buildDocFreq(List<_IndexedDoc> docs) {
    final out = <String, int>{};
    for (final doc in docs) {
      for (final term in doc.termFreq.keys) {
        out[term] = (out[term] ?? 0) + 1;
      }
    }
    return out;
  }

  static double _avgLen(List<_IndexedDoc> docs) {
    if (docs.isEmpty) return 0;
    var total = 0;
    for (final d in docs) {
      total += d.tokens.length;
    }
    return total / docs.length;
  }
}

/// Lowercase unicode-word tokenizer. Picks runs of letters / digits /
/// underscores from any script (Hangul, Latin, code symbols, …) so the
/// same index handles mixed-content chunks.
List<String> _tokenize(String text) {
  final pattern = RegExp(r'[\p{L}\p{N}_]+', unicode: true);
  final out = <String>[];
  for (final match in pattern.allMatches(text)) {
    out.add(match.group(0)!.toLowerCase());
  }
  return out;
}

/// Same regex but preserves original casing — used for snippet rendering.
List<String> _splitText(String text) {
  final pattern = RegExp(r'[\p{L}\p{N}_]+', unicode: true);
  final out = <String>[];
  for (final match in pattern.allMatches(text)) {
    out.add(match.group(0)!);
  }
  return out;
}
