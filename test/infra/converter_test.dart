import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

McpBundle _bundle({String id = 'test-bundle'}) {
  return McpBundle(
    manifest: BundleManifest(id: id, name: id, version: '0.0.0'),
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
    tmp = await Directory.systemTemp.createTemp('kb_converter_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('mbd target writes a directory that round-trips', () async {
    final result = await converter.run(
      bundle: _bundle(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.mbd},
        runValidationFirst: false,
      ),
    );

    expect(result.success, isTrue,
        reason: 'errors: ${result.validationReport?.errors.map((e) => "${e.code}: ${e.message}").join("; ") ?? "(no report)"}, build error: ${result.error}');
    expect(result.artifacts, hasLength(1));
    expect(result.artifacts.single.target, BuildTarget.mbd);

    final manifestFile =
        File(p.join(result.artifacts.single.absolutePath, 'manifest.json'));
    expect(manifestFile.existsSync(), isTrue);

    final json = jsonDecode(await manifestFile.readAsString())
        as Map<String, dynamic>;
    final reloaded = McpBundle.fromJson(json);
    expect(reloaded.manifest.id, 'test-bundle');
    expect(reloaded.knowledge?.sources.first.documents?.first.id, 'doc-1');
  });

  test('mcpb target produces a zip archive', () async {
    final result = await converter.run(
      bundle: _bundle(id: 'pkg'),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.mcpb},
        runValidationFirst: false,
      ),
    );

    expect(result.success, isTrue);
    expect(result.artifacts.single.target, BuildTarget.mcpb);
    expect(
      result.artifacts.single.absolutePath,
      endsWith('mcpb${Platform.pathSeparator}pkg.mcpb'),
    );
    expect(File(result.artifacts.single.absolutePath).lengthSync(),
        greaterThan(0));
  });

  test('mbd + mcpb in one run reuses the mbd directory', () async {
    final outDir = p.join(tmp.path, 'out');
    final result = await converter.run(
      bundle: _bundle(),
      request: BuildRequest(
        outDir: outDir,
        targets: const {BuildTarget.mbd, BuildTarget.mcpb},
        runValidationFirst: false,
      ),
    );

    expect(result.success, isTrue);
    expect(result.artifacts.map((a) => a.target).toSet(),
        {BuildTarget.mbd, BuildTarget.mcpb});
    expect(Directory(p.join(outDir, 'mbd')).existsSync(), isTrue);
    expect(File(p.join(outDir, 'mcpb', 'test-bundle.mcpb')).existsSync(),
        isTrue);
  });

  test('validation errors abort with no artifacts', () async {
    final broken = McpBundle(
      manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
      agents: const AgentsSection(
        agents: [
          AgentDefinition(
            id: 'a1',
            name: 'A',
            role: 'worker',
            profileIds: ['missing'],
          ),
        ],
      ),
    );

    final result = await converter.run(
      bundle: broken,
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.mbd},
      ),
    );

    expect(result.success, isFalse);
    expect(result.artifacts, isEmpty);
    expect(result.validationReport, isNotNull);
    expect(
      result.validationReport!.errors
          .any((e) => e.code == 'KB-CR-AGENT-PROFILE-MISSING'),
      isTrue,
    );
    expect(Directory(p.join(tmp.path, 'out')).existsSync(), isFalse,
        reason: 'aborted before any disk write');
  });

  test(
      'embedded without plan warns; consumerPack runs with default variant',
      () async {
    final result = await converter.run(
      bundle: _bundle(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {
          BuildTarget.embedded,
          BuildTarget.consumerPack,
        },
        runValidationFirst: false,
      ),
    );

    // embedded skipped (no plan) → warning + zero artifact for that target
    // consumerPack falls back to ConsumerPackVariant.ragOnly → 1 artifact
    expect(result.success, isTrue);
    expect(result.artifacts.map((a) => a.target).toList(),
        [BuildTarget.consumerPack]);
    expect(result.warnings, hasLength(1));
    expect(result.warnings.single, contains('embedded'));
  });

  test('runValidationFirst:false skips validation', () async {
    final broken = McpBundle(
      manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
      agents: const AgentsSection(
        agents: [
          AgentDefinition(
            id: 'a1',
            name: 'A',
            role: 'worker',
            profileIds: ['missing'],
          ),
        ],
      ),
    );

    final result = await converter.run(
      bundle: broken,
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.mbd},
        runValidationFirst: false,
      ),
    );

    // No pre-check ran; the broken bundle is written as-is.
    expect(result.success, isTrue);
    expect(result.validationReport, isNull);
    expect(result.artifacts, hasLength(1));
  });
}
