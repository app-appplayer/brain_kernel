/// A skill run passes the active ethos first (platform spec 12 §4, 30 §8): a
/// hard prohibition stops it, a soft one goes to a confirmation that can say
/// no, and without an ethos nothing is checked.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

mb.SkillModule _skill(String id) => mb.SkillModule(
      id: id,
      name: id,
      procedures: [
        mb.SkillProcedure(id: 'm', name: 'm', steps: [
          mb.ProcedureStep(
            id: 's',
            action: mb.StepAction(
              type: mb.StepActionType.tool,
              config: {'toolRef': 'host.$id'},
            ),
          ),
        ]),
      ],
    );

Map<String, dynamic> _ethos(String severity) => {
      'id': 'e1',
      'name': 'e1',
      'valuePriorities': <dynamic>[],
      'prohibitions': [
        {
          'id': 'no-wipe',
          'statement': 'never wipe',
          'severity': severity,
          'rationale': 'data loss',
          'forbiddenPatterns': ['wipe'],
        },
      ],
      'metadata': {
        'version': '1.0.0',
        'createdAt': '2026-10-30T00:00:00Z',
        'updatedAt': '2026-10-30T00:00:00Z',
      },
    };

void main() {
  late List<String> ran;

  Future<KernelApp> boot({
    String? severity,
    SoftViolationConfirm? confirm,
  }) async {
    ran = <String>[];
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      hostTools: (n, a) async {
        ran.add(n);
        return KernelToolResult(content: [KernelTextContent(text: '"ok"')]);
      },
      confirmSoftViolation: confirm,
    );
    addTearDown(app.shutdown);
    await app.registerSkill(_skill('wipe'), bundleId: 'b');
    await app.registerSkill(_skill('read'), bundleId: 'b');
    if (severity != null) {
      final tools = standardTools(app);
      await tools['bk.philosophy.put']!({'ethos': _ethos(severity)});
      await tools['bk.philosophy.activate']!({'id': 'e1'});
    }
    return app;
  }

  Future<Map<String, dynamic>> run(KernelApp app, String id) async =>
      Map<String, dynamic>.from(await standardTools(app)['bk.skill.execute']!(
        {'skillId': 'b.$id'},
      ) as Map);

  test('with no ethos nothing is checked', () async {
    final app = await boot();
    expect((await run(app, 'wipe'))['ok'], isTrue);
  });

  test('a hard prohibition stops the run and the skill never starts',
      () async {
    final app = await boot(severity: 'hard');
    final r = await run(app, 'wipe');
    expect(r['ok'], isNot(true));
    expect('${r['error'] ?? r}', contains('hard prohibition'));
    expect(ran, isEmpty);
    expect((await run(app, 'read'))['ok'], isTrue, reason: 'others still run');
  });

  test('a soft prohibition runs with a warning when no one is asked',
      () async {
    final app = await boot(severity: 'soft');
    final r = await run(app, 'wipe');
    expect(r['ok'], isTrue);
    expect(r['warnings'], isNotEmpty);
  });

  test('a soft prohibition waits for the person, and no stops it', () async {
    final asked = <String>[];
    final app = await boot(
      severity: 'soft',
      confirm: (action, violations) async {
        asked.add(action);
        return false;
      },
    );
    final r = await run(app, 'wipe');
    expect(r['ok'], isNot(true));
    expect(asked, ['b.wipe']);
    expect(ran, isEmpty);
  });

  test('a soft prohibition runs when the person says yes', () async {
    final app = await boot(
      severity: 'soft',
      confirm: (action, violations) async => true,
    );
    expect((await run(app, 'wipe'))['ok'], isTrue);
    expect(ran, ['host.wipe']);
  });
}
