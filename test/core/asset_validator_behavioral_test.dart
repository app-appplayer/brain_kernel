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
          ],
        ),
      ],
    ),
  );
}

void main() {
  const validator = AssetValidator();

  test('empty gold set produces an empty report', () async {
    final report = await validator.validateBehavioral(_bundle(), const []);
    expect(report.errors, isEmpty);
    expect(report.warnings, isEmpty);
    expect(report.infos, isEmpty);
  });

  test('passing question records a KB-BH-GOLD-PASS info', () async {
    final report = await validator.validateBehavioral(
      _bundle(),
      const [
        GoldQuestion(
          id: 'q-cats',
          question: 'cats',
          expectedChunkIds: ['a-cat'],
        ),
      ],
    );
    expect(report.warnings, isEmpty);
    expect(report.infos.single.code, 'KB-BH-GOLD-PASS');
  });

  test('missing chunk yields KB-BH-GOLD-MISS warning', () async {
    final report = await validator.validateBehavioral(
      _bundle(),
      const [
        GoldQuestion(
          id: 'q-aliens',
          question: 'aliens',
          expectedChunkIds: ['a-cat'],
        ),
      ],
    );
    expect(report.errors, isEmpty);
    expect(report.warnings.single.code, 'KB-BH-GOLD-MISS');
    expect(report.warnings.single.message, contains('q-aliens'));
  });

  test('validateAll runs schema + cross-ref + runtime + behavioral',
      () async {
    final report = await validator.validateAll(
      _bundle(),
      goldSet: const [
        GoldQuestion(
          id: 'q-cats',
          question: 'carnivorous',
          expectedChunkIds: ['a-cat'],
        ),
      ],
    );
    expect(report.errors, isEmpty);
    expect(
      report.infos.any((i) => i.code == 'KB-BH-GOLD-PASS'),
      isTrue,
    );
  });
}
