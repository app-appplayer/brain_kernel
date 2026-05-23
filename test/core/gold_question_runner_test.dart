import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

McpBundle _bundle() {
  return McpBundle(
    manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
    knowledge: KnowledgeSection(
      sources: [
        KnowledgeSource(
          id: 'default',
          name: 'default',
          type: KnowledgeSourceType.unknown,
          documents: [
            KnowledgeDocument(
              id: 'a-cat',
              title: 'cats',
              content: 'cats are small carnivorous mammals',
              format: DocumentFormat.text,
              source: 'cat.md',
            ),
            KnowledgeDocument(
              id: 'b-dog',
              title: 'dogs',
              content: 'dogs are loyal companions',
              format: DocumentFormat.text,
              source: 'dog.md',
            ),
            KnowledgeDocument(
              id: 'c-fish',
              title: 'fish',
              content: 'fish swim in water',
              format: DocumentFormat.text,
              source: 'fish.md',
            ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  const runner = GoldQuestionRunner();

  test('passes when expected chunk lands in top-K', () async {
    final v = await runner.run(
      _bundle(),
      const GoldQuestion(
        id: 'q1',
        question: 'carnivorous cats',
        expectedChunkIds: ['a-cat'],
      ),
    );
    expect(v.passed, isTrue);
    expect(v.reason, isNull);
    expect(v.hits.first.chunkId, 'a-cat');
  });

  test('misses when query yields nothing', () async {
    final v = await runner.run(
      _bundle(),
      const GoldQuestion(
        id: 'q2',
        question: 'spaceships',
        expectedChunkIds: ['a-cat'],
      ),
    );
    expect(v.passed, isFalse);
    expect(v.reason, contains('missing'));
  });

  test('flags out-of-rank when minRank is exceeded', () async {
    final v = await runner.run(
      _bundle(),
      const GoldQuestion(
        id: 'q3',
        question: 'companions',
        expectedChunkIds: ['b-dog'],
        topK: 5,
        minRank: 0,
      ),
    );
    // expectedChunkIds[b-dog] is at rank 0 — should pass.
    expect(v.passed, isTrue);

    final stricter = await runner.run(
      _bundle(),
      const GoldQuestion(
        id: 'q4',
        question: 'water',
        expectedChunkIds: ['a-cat'], // not actually about water
        topK: 5,
      ),
    );
    expect(stricter.passed, isFalse);
  });

  test('runAll returns one verdict per question in order', () async {
    final verdicts = await runner.runAll(_bundle(), const [
      GoldQuestion(
        id: 'q1',
        question: 'cats',
        expectedChunkIds: ['a-cat'],
      ),
      GoldQuestion(
        id: 'q2',
        question: 'companions',
        expectedChunkIds: ['b-dog'],
      ),
    ]);
    expect(verdicts, hasLength(2));
    expect(verdicts.every((v) => v.passed), isTrue);
  });
}
