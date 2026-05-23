import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

void main() {
  const validator = AssetValidator();

  test('clean bundle yields empty cross-ref report', () {
    final bundle = McpBundle(
      manifest:
          BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
    );
    final report = validator.validateCrossRef(bundle);
    expect(report.errors, isEmpty);
  });

  test('Agent with missing 4-axis ids yields cross-ref errors', () {
    final bundle = McpBundle(
      manifest:
          BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
      agents: const AgentsSection(
        agents: [
          AgentDefinition(
            id: 'a1',
            name: 'A',
            role: 'worker',
            profileIds: ['missing-profile'],
            skillIds: ['missing-skill'],
            philosophyIds: ['missing-philosophy'],
            factSourceIds: ['missing-fact'],
          ),
        ],
      ),
    );
    final report = validator.validateCrossRef(bundle);
    final codes = report.errors.map((e) => e.code).toSet();
    expect(codes, contains('KB-CR-AGENT-PROFILE-MISSING'));
    expect(codes, contains('KB-CR-AGENT-SKILL-MISSING'));
    expect(codes, contains('KB-CR-AGENT-PHILOSOPHY-MISSING'));
    expect(codes, contains('KB-CR-AGENT-FACT-MISSING'));
  });

  test('Duplicate philosophy ids reported', () {
    final bundle = McpBundle(
      manifest:
          BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
      philosophy: const PhilosophySection(
        philosophies: [
          Philosophy(id: 'dup', name: 'P1', statement: 'S1'),
          Philosophy(id: 'dup', name: 'P2', statement: 'S2'),
        ],
      ),
    );
    final report = validator.validateCrossRef(bundle);
    expect(
      report.errors.any((e) => e.code == 'KB-CR-DUP-ID'),
      isTrue,
    );
  });

  test('runtime + behavioral layers stubbed return empty', () async {
    final bundle = McpBundle(
      manifest:
          BundleManifest(id: 'b', name: 'B', version: '0.0.0'),
    );
    expect(
      (await validator.validateRuntime(bundle)).errors,
      isEmpty,
    );
    expect(
      (await validator.validateBehavioral(bundle, [])).errors,
      isEmpty,
    );
  });
}
