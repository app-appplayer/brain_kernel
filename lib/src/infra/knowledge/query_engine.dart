/// MOD-FEAT-009 — KnowledgeQueryEngine.
///
/// BM25 retrieval over installed knowledge bundles. Two ingestion
/// paths, both routed through `mcp_bundle`'s typed accessors so raw
/// `dart:io` file plumbing stays out of the engine:
///
///   (1) Inline corpus — `manifest.knowledge.sources[].documents[].content`
///       (legacy path; documents authored directly inside the manifest).
///   (2) Folder corpus — every text file under the reserved folders
///       carrying corpus-bearing content (`knowledge/`, `facts/`,
///       `workflows/`, `pipelines/`, `runbooks/`, `skills/`,
///       `profiles/`, `philosophy/`). Each file becomes one chunk;
///       `sourceId` is the folder name, `source` is the relative path.
///
/// Zero internal-LLM dependency: the engine performs only local string
/// arithmetic. The MCP client (Claude Desktop, Inspector, or any other
/// host) is the LLM that actually consumes the returned chunks.
///
/// Engine state — chunks are materialised lazily on each query and
/// cached in memory for the lifetime of the process. Re-install (via
/// `vibe_install_knowledge_bundle`) invalidates the cache.
library;

import 'dart:math' show log;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import 'bundle_registry.dart';

class KnowledgeQueryHit {
  const KnowledgeQueryHit({
    required this.score,
    required this.text,
    required this.source,
    required this.namespace,
    required this.sourceId,
    this.title,
    this.chunkId,
  });

  final double score;
  final String text;

  /// Originating relative path inside the bundle (e.g. `widgets/interaction.md`).
  final String source;

  /// Bundle namespace from the registry (typically the `.mbd/` basename).
  final String namespace;

  /// `KnowledgeSource.id` the chunk lives under (e.g. `widgets`).
  final String sourceId;

  final String? title;
  final String? chunkId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'score': score,
        'text': text,
        'source': source,
        'namespace': namespace,
        'sourceId': sourceId,
        if (title != null) 'title': title,
        if (chunkId != null) 'chunkId': chunkId,
      };
}

class _IndexedChunk {
  _IndexedChunk({
    required this.namespace,
    required this.sourceId,
    required this.source,
    required this.text,
    required this.tokens,
    this.title,
    this.chunkId,
  });
  final String namespace;
  final String sourceId;
  final String source;
  final String text;
  final List<String> tokens;
  final String? title;
  final String? chunkId;
}

class KnowledgeQueryEngine {
  KnowledgeQueryEngine({required this.registry});

  final KnowledgeBundleRegistry registry;

  // BM25 standard params.
  static const double _k1 = 1.5;
  static const double _b = 0.75;

  List<_IndexedChunk>? _cache;

  /// Drop the in-memory chunk cache. Call after install / uninstall so
  /// the next query re-reads bundles.
  void invalidate() {
    _cache = null;
  }

  Future<List<KnowledgeQueryHit>> query(
    String text, {
    int topK = 5,
    String? namespace,
    String? sourceId,
  }) async {
    if (text.trim().isEmpty) return const <KnowledgeQueryHit>[];
    final all = await _loadAll();
    if (all.isEmpty) return const <KnowledgeQueryHit>[];

    final filtered = all.where((c) {
      if (namespace != null && c.namespace != namespace) return false;
      if (sourceId != null && c.sourceId != sourceId) return false;
      return true;
    }).toList();
    if (filtered.isEmpty) return const <KnowledgeQueryHit>[];

    final queryTokens = _tokenize(text);
    if (queryTokens.isEmpty) return const <KnowledgeQueryHit>[];

    final n = filtered.length;
    // Per-term IDF over the *filtered* set so namespace / source filters
    // don't bleed in irrelevant rarity stats.
    final docFreq = <String, int>{};
    for (final c in filtered) {
      final seen = <String>{};
      for (final t in c.tokens) {
        if (seen.add(t)) {
          docFreq[t] = (docFreq[t] ?? 0) + 1;
        }
      }
    }
    final idf = <String, double>{
      for (final term in queryTokens.toSet())
        term: log(((n - (docFreq[term] ?? 0) + 0.5) /
                ((docFreq[term] ?? 0) + 0.5)) +
            1.0),
    };

    // Doc length avg over filtered.
    var totalLen = 0;
    for (final c in filtered) {
      totalLen += c.tokens.length;
    }
    final avgdl = totalLen / n;

    final scored = <KnowledgeQueryHit>[];
    for (final c in filtered) {
      final score = _bm25(
        queryTokens: queryTokens,
        chunk: c,
        idf: idf,
        avgdl: avgdl,
      );
      if (score <= 0) continue;
      scored.add(KnowledgeQueryHit(
        score: score,
        text: c.text,
        source: c.source,
        namespace: c.namespace,
        sourceId: c.sourceId,
        title: c.title,
        chunkId: c.chunkId,
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.length > topK) {
      return scored.sublist(0, topK);
    }
    return scored;
  }

  double _bm25({
    required List<String> queryTokens,
    required _IndexedChunk chunk,
    required Map<String, double> idf,
    required double avgdl,
  }) {
    if (chunk.tokens.isEmpty) return 0;
    final tf = <String, int>{};
    for (final t in chunk.tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
    final docLen = chunk.tokens.length.toDouble();
    var score = 0.0;
    for (final term in queryTokens.toSet()) {
      final freq = tf[term] ?? 0;
      if (freq == 0) continue;
      final termIdf = idf[term] ?? 0;
      final numerator = freq * (_k1 + 1);
      final denominator =
          freq + _k1 * (1 - _b + _b * (docLen / (avgdl <= 0 ? 1 : avgdl)));
      score += termIdf * (numerator / denominator);
    }
    return score;
  }

  /// Reserved folders whose plain-text payload joins the BM25 corpus.
  /// `ui/`, `assets/`, `agents/`, and `tools/` are intentionally
  /// excluded — they're either UI / binary surfaces or wired through
  /// dedicated host machinery (seed_agent_loader,
  /// host_bundle_activation) that doesn't want the files re-indexed
  /// as searchable text.
  static const List<mb.BundleFolder> _corpusFolders = <mb.BundleFolder>[
    mb.BundleFolder.knowledge,
    mb.BundleFolder.facts,
    mb.BundleFolder.workflows,
    mb.BundleFolder.pipelines,
    mb.BundleFolder.runbooks,
    mb.BundleFolder.skills,
    mb.BundleFolder.profiles,
    mb.BundleFolder.philosophy,
  ];

  /// Text-shaped file extensions the BM25 tokenizer can usefully chew
  /// on. Everything else (PNG, MP4, …) is skipped so binary blobs
  /// don't pollute the index.
  static bool _isIndexableFile(String relPath) {
    final lower = relPath.toLowerCase();
    return lower.endsWith('.md') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml');
  }

  Future<List<_IndexedChunk>> _loadAll() async {
    final cached = _cache;
    if (cached != null) return cached;
    final entries = await registry.list();
    final out = <_IndexedChunk>[];
    for (final entry in entries) {
      mb.McpBundle bundle;
      try {
        // Lenient: studio seed manifests don't carry `schemaVersion`,
        // and we'd rather index what's there than skip the bundle
        // entirely over a missing strict-mode field.
        bundle = await mb.McpBundleLoader.loadDirectory(
          entry.mbdPath,
          options: const mb.McpLoaderOptions.lenient(),
        );
      } catch (_) {
        continue; // malformed bundle — skip, keep going
      }

      // (1) Inline corpus — manifest.knowledge.sources[].documents[].
      final manifestJson = bundle.toJson();
      final knowledge = manifestJson['knowledge'] as Map<String, dynamic>?;
      if (knowledge != null) {
        final sources = knowledge['sources'] as List<dynamic>?;
        if (sources != null) {
          for (final s in sources) {
            if (s is! Map<String, dynamic>) continue;
            final sourceId = s['id'] as String? ?? '';
            final docs = s['documents'] as List<dynamic>?;
            if (docs == null) continue;
            for (final d in docs) {
              if (d is! Map<String, dynamic>) continue;
              final content = (d['content'] as String?) ?? '';
              if (content.trim().isEmpty) continue;
              out.add(_IndexedChunk(
                namespace: entry.namespace,
                sourceId: sourceId,
                source: (d['source'] as String?) ?? sourceId,
                text: content,
                tokens: _tokenize(content),
                title: d['title'] as String?,
                chunkId: d['id'] as String?,
              ));
            }
          }
        }
      }

      // (2) Folder corpus — text files under reserved folders.
      for (final folder in _corpusFolders) {
        final res = bundle.resources(folder);
        List<String> files;
        try {
          files = await res.list();
        } catch (_) {
          continue;
        }
        for (final relPath in files) {
          if (!_isIndexableFile(relPath)) continue;
          String content;
          try {
            content = await res.read(relPath);
          } catch (_) {
            continue;
          }
          if (content.trim().isEmpty) continue;
          out.add(_IndexedChunk(
            namespace: entry.namespace,
            sourceId: folder.name,
            source: relPath,
            text: content,
            tokens: _tokenize(content),
          ));
        }
      }
    }
    _cache = out;
    return out;
  }

  /// Lowercase + split on non-word characters. Keeps ASCII identifiers
  /// (`set_property`) usable. CJK falls into per-char tokenisation
  /// implicitly via the regex (each non-ascii word boundary keeps
  /// glyphs together).
  static List<String> _tokenize(String text) {
    final lower = text.toLowerCase();
    final out = <String>[];
    final re = RegExp(r'[a-z0-9_]+|[^\sa-z0-9_]');
    for (final m in re.allMatches(lower)) {
      final tok = m.group(0)!;
      if (tok.length < 2 && tok.codeUnitAt(0) < 0x80) {
        // Drop single-char ASCII tokens (`a`, `i`); keep CJK glyphs.
        continue;
      }
      out.add(tok);
    }
    return out;
  }
}
