/// Run an [EmbeddingProvider] over chunked KnowledgeDocuments and
/// attach the resulting vector to each document's metadata. Returns
/// the augmented document list plus the [EmbeddingConfig] to record
/// in the bundle's KnowledgeSection.
library;

import 'package:mcp_bundle/mcp_bundle.dart'
    show EmbeddingConfig, KnowledgeDocument;

import 'embedding_provider.dart';

/// Bundle of provider + batch size used by [EmbeddingRunner] and the
/// CLI / Converter wiring. Lives here so callers don't have to
/// reach into the CLI layer.
class EmbeddingPlan {
  const EmbeddingPlan({
    required this.provider,
    this.batchSize = 16,
  });
  final EmbeddingProvider provider;
  final int batchSize;
}

class EmbeddingRunResult {
  const EmbeddingRunResult({
    required this.documents,
    required this.config,
    required this.embeddedCount,
  });

  /// Documents with `metadata['embedding'] = List<double>` attached.
  final List<KnowledgeDocument> documents;

  /// `EmbeddingConfig` (model, dimensions, batchSize) suitable for
  /// recording at the KnowledgeSource / KnowledgeSection level.
  final EmbeddingConfig config;

  /// Count of documents that received an embedding (skipped on empty
  /// content — those keep their original metadata).
  final int embeddedCount;
}

class EmbeddingRunner {
  EmbeddingRunner({
    required this.provider,
    this.batchSize = 16,
  }) : assert(batchSize > 0, 'batchSize must be positive');

  final EmbeddingProvider provider;

  /// Number of texts handed to a single [EmbeddingProvider.embedBatch]
  /// call. Bound this for providers that limit per-request batches and
  /// for memory.
  final int batchSize;

  Future<EmbeddingRunResult> run(List<KnowledgeDocument> docs) async {
    if (docs.isEmpty) {
      return EmbeddingRunResult(
        documents: const <KnowledgeDocument>[],
        config: EmbeddingConfig(
          model: provider.modelId,
          batchSize: batchSize,
        ),
        embeddedCount: 0,
      );
    }
    // Track which input indexes are non-empty so we only call the
    // provider on real content; empty chunks (e.g. blank prelude) keep
    // their original metadata so the caller can still trace them.
    final eligibleIdx = <int>[];
    final eligibleText = <String>[];
    for (var i = 0; i < docs.length; i++) {
      final t = docs[i].content;
      if (t.trim().isNotEmpty) {
        eligibleIdx.add(i);
        eligibleText.add(t);
      }
    }
    final out = List<KnowledgeDocument>.of(docs);
    int? dims;
    var embedded = 0;
    for (var batchStart = 0;
        batchStart < eligibleText.length;
        batchStart += batchSize) {
      final end = (batchStart + batchSize).clamp(0, eligibleText.length);
      final slice = eligibleText.sublist(batchStart, end);
      final vectors = await provider.embedBatch(slice);
      if (vectors.length != slice.length) {
        throw StateError(
          'embedding provider returned ${vectors.length} vectors '
          'for ${slice.length} inputs',
        );
      }
      for (var k = 0; k < slice.length; k++) {
        final docIdx = eligibleIdx[batchStart + k];
        final vec = vectors[k];
        dims ??= vec.length;
        out[docIdx] = _withEmbedding(out[docIdx], vec);
        embedded++;
      }
    }
    return EmbeddingRunResult(
      documents: out,
      config: EmbeddingConfig(
        model: provider.modelId,
        dimensions: dims,
        batchSize: batchSize,
      ),
      embeddedCount: embedded,
    );
  }

  static KnowledgeDocument _withEmbedding(
    KnowledgeDocument src,
    List<double> vec,
  ) {
    final newMeta = <String, dynamic>{
      ...src.metadata,
      'embedding': vec,
    };
    return KnowledgeDocument(
      id: src.id,
      title: src.title,
      content: src.content,
      format: src.format,
      source: src.source,
      metadata: newMeta,
    );
  }
}
