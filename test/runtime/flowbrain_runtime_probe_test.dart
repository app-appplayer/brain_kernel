import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

McpBundle _emptyBundle() {
  return McpBundle(
    manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
  );
}

McpBundle _bundleWithAssets() {
  return McpBundle(
    manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
    philosophy: const PhilosophySection(
      philosophies: [
        Philosophy(
          id: 'reuse',
          name: 'Reuse first',
          statement: 'Prefer proven patterns.',
        ),
      ],
    ),
    agents: const AgentsSection(
      agents: [
        AgentDefinition(id: 'a1', name: 'A1', role: 'worker'),
      ],
    ),
  );
}

void main() {
  group('FlowBrainRuntimeProbe', () {
    test('returns KB-RT-WIRING-NOT-BOOTED when wiring is cold', () async {
      final wiring = FlowBrainWiring(
        workspaceId: 'kb',
        kvStoragePort: InMemoryKvStoragePort(),
      );
      final probe = FlowBrainRuntimeProbe(wiring);
      final report = await probe.probe(_emptyBundle());
      expect(report.errors.single.code, 'KB-RT-WIRING-NOT-BOOTED');
    });

    test('successful import yields KB-RT-IMPORT-OK info', () async {
      final wiring = FlowBrainWiring(
        workspaceId: 'kb',
        kvStoragePort: InMemoryKvStoragePort(),
      );
      await wiring.boot();
      final probe = FlowBrainRuntimeProbe(wiring);
      final report = await probe.probe(_bundleWithAssets());
      expect(report.errors, isEmpty);
      expect(
        report.infos.any((i) => i.code == 'KB-RT-IMPORT-OK'),
        isTrue,
      );
      await wiring.dispose();
    });

    test('repeat import surfaces KB-RT-AGENT-SKIPPED warning', () async {
      final wiring = FlowBrainWiring(
        workspaceId: 'kb',
        kvStoragePort: InMemoryKvStoragePort(),
      );
      await wiring.boot();
      final probe = FlowBrainRuntimeProbe(wiring);
      // First import populates the workspace. The second sees the same
      // ids and skips them — still no errors, but a warning row.
      await probe.probe(_bundleWithAssets());
      final secondReport = await probe.probe(_bundleWithAssets());
      expect(secondReport.errors, isEmpty);
      expect(
        secondReport.warnings.any((w) => w.code == 'KB-RT-AGENT-SKIPPED'),
        isTrue,
      );
      await wiring.dispose();
    });
  });

  group('AssetValidator.validateAll — all 4 layers', () {
    test('schema + cross-ref + runtime + behavioral compose cleanly',
        () async {
      final wiring = FlowBrainWiring(
        workspaceId: 'kb',
        kvStoragePort: InMemoryKvStoragePort(),
      );
      await wiring.boot();
      final probe = FlowBrainRuntimeProbe(wiring);

      final bundle = McpBundle(
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
              ],
            ),
          ],
        ),
      );

      const validator = AssetValidator();
      final report = await validator.validateAll(
        bundle,
        runtimeProbe: probe.fn,
        goldSet: const [
          GoldQuestion(
            id: 'q-cats',
            question: 'cats',
            expectedChunkIds: ['a-cat'],
          ),
        ],
      );
      expect(report.errors, isEmpty);
      expect(
        report.infos.any((i) => i.code == 'KB-RT-IMPORT-OK'),
        isTrue,
      );
      expect(
        report.infos.any((i) => i.code == 'KB-BH-GOLD-PASS'),
        isTrue,
      );
      await wiring.dispose();
    });

    test('schema/cross-ref errors short-circuit before runtime + behavioral',
        () async {
      final wiring = FlowBrainWiring(
        workspaceId: 'kb',
        kvStoragePort: InMemoryKvStoragePort(),
      );
      await wiring.boot();
      final probe = FlowBrainRuntimeProbe(wiring);

      final bundle = McpBundle(
        manifest: BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
        agents: const AgentsSection(
          agents: [
            AgentDefinition(
              id: 'a1',
              name: 'A',
              role: 'worker',
              profileIds: ['missing-profile'],
            ),
          ],
        ),
      );

      const validator = AssetValidator();
      final report = await validator.validateAll(
        bundle,
        runtimeProbe: probe.fn,
      );
      expect(report.errors, isNotEmpty);
      // Runtime probe should NOT have fired — no runtime info row.
      expect(
        report.infos.any((i) => i.code == 'KB-RT-IMPORT-OK'),
        isFalse,
      );
      await wiring.dispose();
    });
  });
}
