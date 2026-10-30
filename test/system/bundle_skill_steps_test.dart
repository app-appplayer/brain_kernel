/// A skill a bundle declares runs on the kernel: the bundle's step names are
/// turned into the ones the skill runtime executes (platform spec 30 §8).
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_skill/mcp_skill.dart' as ms;
import 'package:test/test.dart';

mb.SkillModule _skill(String actionType, Map<String, dynamic> config) =>
    mb.SkillModule(
      id: 'demo',
      name: 'demo',
      version: '1.0.0',
      procedures: [
        mb.SkillProcedure(
          id: 'main',
          name: 'main',
          steps: [
            mb.ProcedureStep(
              id: 's1',
              action: mb.StepAction(
                type: mb.StepActionType.fromString(actionType),
                config: config,
              ),
            ),
          ],
        ),
      ],
    );

void main() {
  Future<KernelApp> boot(List<String> prompts) => KernelApp.boot(
        workspaceId: 'ws',
        kvStorage: mb.InMemoryKvStoragePort(),
        fallbackLlm: _EchoLlm(prompts),
        hostTools: (name, args) async => KernelToolResult(
          content: [KernelTextContent(text: '"ok"')],
        ),
      );

  test('a bundle prompt step runs as an llm step', () async {
    final prompts = <String>[];
    final app = await boot(prompts);
    addTearDown(app.shutdown);
    final act = BundleActivation(system: app.system, bundleId: 'b');
    await act.registerSkill(_skill('prompt', {'prompt': 'say hi'}));

    final r = await app.system.skill.execute('b.demo', const {});

    expect(prompts, ['say hi']);
    expect(r.metadata.stepsExecuted, 1);
  });

  test('a bundle tool step runs as a tool step', () async {
    final app = await boot(<String>[]);
    addTearDown(app.shutdown);
    final act = BundleActivation(system: app.system, bundleId: 'b');
    await act.registerSkill(_skill('tool', {'toolRef': 'host.x'}));

    final r = await app.system.skill.execute('b.demo', const {});

    expect(r.metadata.toolsCalled, ['host.x']);
  });

  for (final t in ['unknown', 'bogus']) {
    test('a bundle $t step is refused at registration, not run as nothing',
        () async {
      final app = await boot(<String>[]);
      addTearDown(app.shutdown);
      final act = BundleActivation(system: app.system, bundleId: 'b');

      await expectLater(
        act.registerSkill(_skill(t, const {})),
        throwsA(isA<ms.InvalidProcedureException>()),
      );
    });
  }

  test('a bundle output step hands its value back', () async {
    final app = await boot(<String>[]);
    addTearDown(app.shutdown);
    final act = BundleActivation(system: app.system, bundleId: 'b');
    await act.registerSkill(_skill('output', {'value': '1 + 2'}));

    final r = await app.system.skill.execute('b.demo', const {});

    expect(r.output, 3);
  });

  mb.SkillModule graph(List<mb.ProcedureStep> steps) => mb.SkillModule(
        id: 'g',
        name: 'g',
        procedures: [mb.SkillProcedure(id: 'm', name: 'm', steps: steps)],
      );
  mb.ProcedureStep step(String id,
          {List<String> next = const [], String? onError}) =>
      mb.ProcedureStep(
        id: id,
        action: mb.StepAction(
          type: mb.StepActionType.tool,
          config: {'toolRef': 'host.$id'},
        ),
        next: next,
        onError: onError,
      );

  group('procedureId', () {
    mb.SkillModule two() => mb.SkillModule(
          id: 'two',
          name: 'two',
          procedures: [
            mb.SkillProcedure(id: 'first', name: 'first', steps: [
              mb.ProcedureStep(
                id: 's',
                action: mb.StepAction(
                  type: mb.StepActionType.tool,
                  config: {'toolRef': 'host.first'},
                ),
              ),
            ]),
            mb.SkillProcedure(id: 'second', name: 'second', steps: [
              mb.ProcedureStep(
                id: 's',
                action: mb.StepAction(
                  type: mb.StepActionType.tool,
                  config: {'toolRef': 'host.second'},
                ),
              ),
            ]),
          ],
        );

    Future<Map<String, dynamic>> call(KernelApp app, [String? id]) async =>
        Map<String, dynamic>.from(await standardTools(app)['bk.skill.execute']!({
          'skillId': 'b.two',
          if (id != null) 'procedureId': id,
        }) as Map);

    test('bk.skill.execute runs the procedure it is told to', () async {
      final ran = <String>[];
      final app = await KernelApp.boot(
        workspaceId: 'ws',
        kvStorage: mb.InMemoryKvStoragePort(),
        hostTools: (n, a) async {
          ran.add(n);
          return KernelToolResult(content: [KernelTextContent(text: '"ok"')]);
        },
      );
      addTearDown(app.shutdown);
      await BundleActivation(system: app.system, bundleId: 'b')
          .registerSkill(two());

      await call(app);
      await call(app, 'second');

      expect(ran, ['host.first', 'host.second']);
    });

    test('an unknown procedure fails and does not run the first', () async {
      final ran = <String>[];
      final app = await KernelApp.boot(
        workspaceId: 'ws',
        kvStorage: mb.InMemoryKvStoragePort(),
        hostTools: (n, a) async {
          ran.add(n);
          return KernelToolResult(content: [KernelTextContent(text: '"ok"')]);
        },
      );
      addTearDown(app.shutdown);
      await BundleActivation(system: app.system, bundleId: 'b')
          .registerSkill(two());

      final r = await call(app, 'nope');

      expect(r['ok'], isNot(true));
      expect(ran, isEmpty);
    });
  });

  group('a bundle step graph', () {
    test('a forward next skips the steps in between', () async {
      final app = await boot(<String>[]);
      addTearDown(app.shutdown);
      final act = BundleActivation(system: app.system, bundleId: 'b');
      await act.registerSkill(graph([
        step('a', next: ['c']),
        step('b'),
        step('c'),
      ]));

      final r = await app.system.skill.execute('b.g', const {});

      expect(r.metadata.toolsCalled, ['host.a', 'host.c']);
    });

    test('an onError step takes over when a step fails', () async {
      final app = await KernelApp.boot(
        workspaceId: 'ws',
        kvStorage: mb.InMemoryKvStoragePort(),
        hostTools: (name, args) async {
          if (name == 'host.a') throw StateError('boom');
          return KernelToolResult(content: [KernelTextContent(text: '"ok"')]);
        },
      );
      addTearDown(app.shutdown);
      final act = BundleActivation(system: app.system, bundleId: 'b');
      await act.registerSkill(graph([
        step('a', onError: 'c'),
        step('b'),
        step('c'),
      ]));

      final r = await app.system.skill.execute('b.g', const {});

      expect(r.metadata.toolsCalled, contains('host.c'));
      expect(r.metadata.toolsCalled, isNot(contains('host.b')));
    });

    test('an error result from a host tool takes the onError path', () async {
      final app = await KernelApp.boot(
        workspaceId: 'ws',
        kvStorage: mb.InMemoryKvStoragePort(),
        hostTools: (name, args) async => name == 'host.a'
            ? KernelToolResult(
                content: [KernelTextContent(text: 'nope')],
                isError: true,
              )
            : KernelToolResult(content: [KernelTextContent(text: '"ok"')]),
      );
      addTearDown(app.shutdown);
      final act = BundleActivation(system: app.system, bundleId: 'b');
      await act.registerSkill(graph([
        step('a', onError: 'c'),
        step('b'),
        step('c'),
      ]));

      final r = await app.system.skill.execute('b.g', const {});

      expect(r.metadata.toolsCalled, contains('host.c'));
      expect(r.metadata.toolsCalled, isNot(contains('host.b')));
    });

    for (final c in {
      'several next': [step('a', next: ['b', 'c']), step('b'), step('c')],
      'a way back': [step('a'), step('b', next: ['a'])],
      'an unknown id': [step('a', next: ['zzz'])],
      'an onError that goes back': [step('a'), step('b', onError: 'a')],
    }.entries) {
      test('${c.key} is refused', () async {
        final app = await boot(<String>[]);
        addTearDown(app.shutdown);
        final act = BundleActivation(system: app.system, bundleId: 'b');
        await expectLater(
          act.registerSkill(graph(c.value)),
          throwsA(isA<ms.InvalidProcedureException>()),
        );
      });
    }
  });
}

class _EchoLlm implements mb.LlmPort {
  _EchoLlm(this.prompts);
  final List<String> prompts;

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #complete) {
      final req = i.positionalArguments.first as mb.LlmRequest;
      prompts.add(req.messages!.last.content);
      return Future.value(mb.LlmResponse(content: 'hi'));
    }
    return super.noSuchMethod(i);
  }
}
