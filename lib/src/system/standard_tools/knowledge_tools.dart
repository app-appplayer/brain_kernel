/// `bk.knowledge.*` — BM25 retrieval wrappers over the
/// [KnowledgeQueryEngine] (`query` + namespace-scoped `test`).
/// `bk.knowledge.validate` is host-specific (filesystem-based
/// manifest validation) and lands in a follow-up round once the
/// host validator port is in place.
library;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, InProcessToolHandler> buildKnowledgeTools(KernelApp app) {
  Future<Object?> query(Map<String, dynamic> p) async {
    final text = p['text'];
    if (text is! String || text.trim().isEmpty) {
      return stdErr('text required');
    }
    final topK = (p['topK'] as num?)?.toInt() ?? 5;
    // Auto-scope to the active bundle's namespace when the caller
    // does not pass one explicitly. Master context resolves to null
    // (union view across all bundles).
    final namespace = (p['namespace'] as String?) ?? app.activeBundleId;
    final sourceId = p['sourceId'] as String?;
    try {
      final hits = await app.queryEngine.query(
        text,
        topK: topK,
        namespace: namespace,
        sourceId: sourceId,
      );
      return <String, dynamic>{
        'ok': true,
        'hits': hits
            .map((h) => <String, dynamic>{
                  'score': h.score,
                  'text': h.text,
                  'source': h.source,
                  if (h.title != null) 'title': h.title,
                  'namespace': h.namespace,
                  'sourceId': h.sourceId,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('query failed: $e');
    }
  }

  Future<Object?> test(Map<String, dynamic> p) async {
    final mbd = p['mbdPath'];
    final text = p['query'];
    if (mbd is! String ||
        mbd.isEmpty ||
        text is! String ||
        text.trim().isEmpty) {
      return stdErr('mbdPath + query required');
    }
    final entries = await app.bundleRegistry.list();
    final match = entries.where((e) => e.mbdPath == mbd).toList();
    if (match.isEmpty) {
      return stdErr(
        'bundle not registered — activate the bundle first to register it',
      );
    }
    final namespace = match.first.namespace;
    final topK = (p['topK'] as num?)?.toInt() ?? 5;
    final sourceId = p['sourceId'] as String?;
    try {
      final hits = await app.queryEngine.query(
        text,
        topK: topK,
        namespace: namespace,
        sourceId: sourceId,
      );
      return <String, dynamic>{
        'ok': true,
        'bundle': <String, dynamic>{
          'namespace': namespace,
          'mbdPath': mbd,
        },
        'hits': hits
            .map((h) => <String, dynamic>{
                  'score': h.score,
                  'text': h.text,
                  'source': h.source,
                  if (h.title != null) 'title': h.title,
                  'namespace': h.namespace,
                  'sourceId': h.sourceId,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('test failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.knowledge.query': query,
    'bk.knowledge.test': test,
  };
}
