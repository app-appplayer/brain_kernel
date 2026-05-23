import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

McpBundle _bundleWithEverything() {
  return McpBundle(
    manifest: BundleManifest(
      id: 'pack-test',
      name: 'Pack Test',
      version: '0.0.0',
      description: 'A bundle that exercises every section.',
    ),
    knowledge: KnowledgeSection(
      sources: [
        KnowledgeSource(
          id: 'default',
          name: 'default',
          type: KnowledgeSourceType.unknown,
          documents: [
            KnowledgeDocument(
              id: 'doc-1',
              title: 'Cats',
              content: 'cats are small carnivorous mammals',
              format: DocumentFormat.text,
              source: 'cat.md',
            ),
          ],
        ),
      ],
    ),
    philosophy: const PhilosophySection(
      philosophies: [
        Philosophy(
          id: 'reuse',
          name: 'Reuse first',
          statement: 'Prefer proven patterns.',
          examples: [
            PhilosophyExample(description: 'Adopt vibe shell pattern.'),
          ],
        ),
      ],
    ),
    skills: const SkillSection(modules: [
      SkillModule(
        id: 's1',
        name: 'Layout',
        description: 'Compose UI layouts.',
      ),
    ]),
    profiles: const ProfilesSection(profiles: [
      ProfileDefinition(
          id: 'p1', name: 'Craftsman', description: 'Quality-first persona.'),
    ]),
    agents: const AgentsSection(agents: [
      AgentDefinition(
          id: 'a1', name: 'Designer', role: 'worker', description: 'UI agent.'),
    ]),
  );
}

void main() {
  late Directory tmp;
  const converter = Converter();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_converter_consumer_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<McpBundle> _readBundle(String dir) async {
    final json = jsonDecode(
      await File(p.join(dir, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    return McpBundle.fromJson(json);
  }

  test('rag-only variant strips every section except knowledge', () async {
    final result = await converter.run(
      bundle: _bundleWithEverything(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.consumerPack},
        runValidationFirst: false,
        consumerPackVariant: ConsumerPackVariant.ragOnly,
      ),
    );
    expect(result.success, isTrue);
    final dir = result.artifacts.single.absolutePath;
    final bundle = await _readBundle(dir);
    expect(bundle.knowledge, isNotNull);
    expect(bundle.philosophy, isNull);
    expect(bundle.skills, isNull);
    expect(bundle.profiles, isNull);
    expect(bundle.agents, isNull);
  });

  test('flowbrain-full variant preserves the entire bundle', () async {
    final result = await converter.run(
      bundle: _bundleWithEverything(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.consumerPack},
        runValidationFirst: false,
        consumerPackVariant: ConsumerPackVariant.flowBrainFull,
      ),
    );
    expect(result.success, isTrue);
    final bundle = await _readBundle(result.artifacts.single.absolutePath);
    expect(bundle.knowledge, isNotNull);
    expect(bundle.philosophy?.philosophies, hasLength(1));
    expect(bundle.skills?.modules, hasLength(1));
    expect(bundle.profiles?.profiles, hasLength(1));
    expect(bundle.agents?.agents, hasLength(1));
  });

  test('prompt-pack variant emits a single markdown file', () async {
    final result = await converter.run(
      bundle: _bundleWithEverything(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.consumerPack},
        runValidationFirst: false,
        consumerPackVariant: ConsumerPackVariant.promptPack,
      ),
    );
    expect(result.success, isTrue);
    final dir = result.artifacts.single.absolutePath;
    final markdown = File(p.join(dir, 'prompt-pack.md'));
    expect(markdown.existsSync(), isTrue);

    final body = await markdown.readAsString();
    expect(body, contains('# Pack Test'));
    expect(body, contains('## Knowledge chunks'));
    expect(body, contains('cats are small carnivorous mammals'));
    expect(body, contains('## Philosophies'));
    expect(body, contains('Prefer proven patterns'));
    expect(body, contains('## Skills'));
    expect(body, contains('## Profiles'));
    expect(body, contains('## Agents'));
  });

  test('default variant when consumerPack target requested without one',
      () async {
    final result = await converter.run(
      bundle: _bundleWithEverything(),
      request: BuildRequest(
        outDir: p.join(tmp.path, 'out'),
        targets: const {BuildTarget.consumerPack},
        runValidationFirst: false,
        // no consumerPackVariant — expect rag-only default
      ),
    );
    expect(result.success, isTrue);
    final bundle = await _readBundle(result.artifacts.single.absolutePath);
    expect(bundle.philosophy, isNull,
        reason: 'default variant is rag-only — strips other sections');
  });
}
