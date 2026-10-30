/// A scoped skill is seen and run only by a call whose scope chain holds its
/// owner; a skill with no owner is global (platform spec 30 §8).
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

mb.SkillModule _skill(String id) => mb.SkillModule(
      id: id,
      name: id,
      procedures: [
        mb.SkillProcedure(
          id: 'm',
          name: 'm',
          steps: [
            mb.ProcedureStep(
              id: 's',
              action: mb.StepAction(
                type: mb.StepActionType.tool,
                config: {'toolRef': 'host.$id'},
              ),
            ),
          ],
        ),
      ],
    );

void main() {
  // org: root > team > desk ; other is a sibling of team
  final parents = {'desk': 'team', 'team': 'root', 'other': 'root'};
  Future<List<String>> chain(String s) async {
    final out = <String>[s];
    var at = s;
    while (parents[at] != null) {
      at = parents[at]!;
      out.add(at);
    }
    return out;
  }

  Future<KernelApp> boot({bool withChain = true}) async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      hostTools: (n, a) async =>
          KernelToolResult(content: [KernelTextContent(text: '"ok"')]),
      skillScopeChain: withChain ? chain : null,
    );
    addTearDown(app.shutdown);
    await app.registerSkill(_skill('shared'), bundleId: 'b');
    await app.registerSkill(_skill('teamonly'),
        bundleId: 'b', ownerScope: 'team');
    return app;
  }

  Future<bool> sees(SkillScopes s, String id, String? scope) =>
      s.visible('b.$id', scope);

  test('a skill with no owner is seen from every scope', () async {
    final app = await boot();
    for (final scope in [null, 'desk', 'other', 'root']) {
      expect(await sees(app.skillScopes, 'shared', scope), isTrue);
    }
  });

  test('an owned skill is seen by the owner and below, not above or beside',
      () async {
    final app = await boot();
    expect(await sees(app.skillScopes, 'teamonly', 'team'), isTrue);
    expect(await sees(app.skillScopes, 'teamonly', 'desk'), isTrue);
    expect(await sees(app.skillScopes, 'teamonly', 'root'), isFalse);
    expect(await sees(app.skillScopes, 'teamonly', 'other'), isFalse);
    expect(await sees(app.skillScopes, 'teamonly', null), isFalse);
  });

  test('without a chain provider only the scope itself counts', () async {
    final app = await boot(withChain: false);
    expect(await sees(app.skillScopes, 'teamonly', 'team'), isTrue);
    expect(await sees(app.skillScopes, 'teamonly', 'desk'), isFalse);
  });

  group('the bk.skill tools', () {
    Future<Map<String, dynamic>> call(
        KernelApp app, String tool, Map<String, dynamic> args) async {
      final h = standardTools(app)[tool]!;
      return Map<String, dynamic>.from(await h(args) as Map);
    }

    test('list shows what the scope may see', () async {
      final app = await boot();
      String ids(Map<String, dynamic> r) => [
            for (final s in r['skills'] as List)
              (s as Map)['manifest']['id'] as String
          ].join(',');
      expect(ids(await call(app, 'bk.skill.list', {'scopeId': 'desk'})),
          contains('b.teamonly'));
      expect(ids(await call(app, 'bk.skill.list', {'scopeId': 'other'})),
          isNot(contains('b.teamonly')));
      expect(ids(await call(app, 'bk.skill.list', {'scopeId': 'other'})),
          contains('b.shared'));
    });

    test('execute refuses a skill outside the scope and runs one inside',
        () async {
      final app = await boot();
      final no = await call(app, 'bk.skill.execute',
          {'skillId': 'b.teamonly', 'scopeId': 'other'});
      expect(no['ok'], isNot(true));
      final yes = await call(app, 'bk.skill.execute',
          {'skillId': 'b.teamonly', 'scopeId': 'desk'});
      expect(yes['ok'], isTrue);
    });
  });
}
