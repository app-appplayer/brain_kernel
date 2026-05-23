import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

McpBundle _bundleWithChunks(List<({String id, String content})> chunks) {
  return McpBundle(
    manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
    knowledge: KnowledgeSection(
      sources: [
        KnowledgeSource(
          id: 'default',
          name: 'default',
          type: KnowledgeSourceType.unknown,
          documents: [
            for (final c in chunks)
              KnowledgeDocument(
                id: c.id,
                title: c.id,
                content: c.content,
                format: DocumentFormat.text,
                source: '${c.id}.md',
              ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  test('empty index returns empty hits', () {
    final index = BmIndex.fromBundle(McpBundle(
      manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
    ));
    expect(index.query('anything'), isEmpty);
    expect(index.stats()['docCount'], 0);
  });

  test('ranks the most relevant chunk first', () {
    final bundle = _bundleWithChunks([
      (id: 'about-cats', content: 'cats are small carnivorous mammals'),
      (id: 'about-dogs', content: 'dogs are loyal companions'),
      (id: 'about-fish', content: 'fish swim in water'),
    ]);
    final index = BmIndex.fromBundle(bundle);
    final hits = index.query('carnivorous cats');
    expect(hits, isNotEmpty);
    expect(hits.first.chunkId, 'about-cats');
    expect(hits.first.rank, 0);
    expect(hits.first.score, greaterThan(0));
  });

  test('snippet bolds matched query tokens', () {
    final bundle = _bundleWithChunks([
      (
        id: 'doc',
        content: 'the quick brown fox jumps over the lazy dog repeatedly',
      ),
    ]);
    final index = BmIndex.fromBundle(bundle);
    final hits = index.query('brown fox');
    expect(hits, hasLength(1));
    expect(hits.single.snippet, contains('**brown**'));
    expect(hits.single.snippet, contains('**fox**'));
  });

  test('rebuild reflects latest bundle', () {
    final first = _bundleWithChunks([
      (id: 'a', content: 'alpha'),
    ]);
    final index = BmIndex.fromBundle(first);
    expect(index.query('alpha'), isNotEmpty);

    final second = _bundleWithChunks([
      (id: 'b', content: 'beta'),
    ]);
    index.rebuild(second);
    expect(index.query('alpha'), isEmpty);
    expect(index.query('beta').single.chunkId, 'b');
  });

  test('handles unicode tokens (Korean)', () {
    // Whitespace-separated tokens — the simple unicode-word tokenizer
    // treats the Hangul runs between spaces as atoms; morphological
    // segmentation is out of scope for the first cut.
    final bundle = _bundleWithChunks([
      (id: 'k1', content: '지식 빌더 자산'),
      (id: 'k2', content: '에이전트 운영 entity'),
    ]);
    final index = BmIndex.fromBundle(bundle);
    final hits = index.query('자산');
    expect(hits.first.chunkId, 'k1');
  });
}
