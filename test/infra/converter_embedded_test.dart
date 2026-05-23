import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _FixedEmbeddingProvider extends EmbeddingProvider {
  _FixedEmbeddingProvider();

  @override
  final String modelId = 'stub-model';
  final int dimensions = 4;

  @override
  Future<List<double>> embed(String text) async {
    // Deterministic vector — distinguishes empty / non-empty inputs.
    final seed = text.length.toDouble();
    return List<double>.generate(dimensions, (i) => seed + i * 0.1);
  }
}

McpBundle _bundleWithChunks() {
  return McpBundle(
    manifest: BundleManifest(id: 'embed-test', name: 'embed', version: '0.0.0'),
    knowledge: KnowledgeSection(
      sources: [
        KnowledgeSource(
          id: 'default',
          name: 'default',
          type: KnowledgeSourceType.unknown,
          documents: [
            KnowledgeDocument(
              id: 'doc-1',
              title: 'doc-1',
              content: 'hello world',
              format: DocumentFormat.text,
              source: 'doc-1.md',
            ),
            KnowledgeDocument(
              id: 'doc-2',
              title: 'doc-2',
              content: 'another chunk',
              format: DocumentFormat.text,
              source: 'doc-2.md',
            ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  late Directory tmp;
  const converter = Converter();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_converter_embed_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('embedded target inlines vectors into chunk metadata', () async {
    final result = await converter.run(
      bundle: _bundleWithChunks(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.embedded},
        runValidationFirst: false,
        embedding: EmbeddingPlan(
          provider: _FixedEmbeddingProvider(),
          batchSize: 4,
        ),
      ),
    );

    expect(result.success, isTrue,
        reason: 'error: ${result.error}, warnings: ${result.warnings}');
    expect(result.artifacts.single.target, BuildTarget.embedded);

    final embeddedPath = result.artifacts.single.absolutePath;
    final json = jsonDecode(
      await File(p.join(embeddedPath, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    final reloaded = McpBundle.fromJson(json);

    final docs =
        reloaded.knowledge!.sources.first.documents!;
    for (final d in docs) {
      expect(d.metadata['embedding'], isA<List>(),
          reason: 'every chunk must carry an embedding vector');
      expect((d.metadata['embedding'] as List).length, 4);
    }
    expect(
      reloaded.knowledge!.sources.first.embedding?.model,
      'stub-model',
    );
    expect(
      reloaded.knowledge!.sources.first.embedding?.dimensions,
      4,
    );
  });

  test('embedded target without EmbeddingPlan is a warning, not a failure',
      () async {
    final result = await converter.run(
      bundle: _bundleWithChunks(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.embedded},
        runValidationFirst: false,
      ),
    );
    expect(result.success, isTrue);
    expect(result.artifacts, isEmpty);
    expect(
      result.warnings.any((w) => w.contains('embedded target requires')),
      isTrue,
    );
  });

  test('mbd + embedded run produces both artifacts', () async {
    final result = await converter.run(
      bundle: _bundleWithChunks(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.mbd, BuildTarget.embedded},
        runValidationFirst: false,
        embedding: EmbeddingPlan(provider: _FixedEmbeddingProvider()),
      ),
    );
    expect(result.success, isTrue);
    expect(
      result.artifacts.map((a) => a.target).toSet(),
      {BuildTarget.mbd, BuildTarget.embedded},
    );

    // mbd artifact has NO embedding inline; embedded artifact does.
    final mbd = result.artifacts
        .firstWhere((a) => a.target == BuildTarget.mbd)
        .absolutePath;
    final embedded = result.artifacts
        .firstWhere((a) => a.target == BuildTarget.embedded)
        .absolutePath;

    final mbdBundle = McpBundle.fromJson(
      jsonDecode(await File(p.join(mbd, 'manifest.json')).readAsString())
          as Map<String, dynamic>,
    );
    final embedBundle = McpBundle.fromJson(
      jsonDecode(
              await File(p.join(embedded, 'manifest.json')).readAsString())
          as Map<String, dynamic>,
    );

    expect(
      mbdBundle.knowledge!.sources.first.documents!.first.metadata['embedding'],
      isNull,
    );
    expect(
      embedBundle.knowledge!.sources.first.documents!.first.metadata['embedding'],
      isA<List>(),
    );
  });
}
