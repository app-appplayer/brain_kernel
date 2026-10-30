/// A skill's `tool` step reaches the host's own tools when the host gives
/// KernelApp.boot a `hostTools` invoker (platform spec 30 §8). Without it the
/// step still runs through the stub port, as before.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

Future<void> _register(KernelApp app) =>
    app.system.skillRuntime!.registry.registerSkill(
      fb.SkillBundle(
        schemaVersion: '0.1.0',
        manifest: const fb.SkillManifest(
          id: 'demo.echo',
          name: 'echo',
          version: '1.0.0',
          provider: 'demo',
        ),
        procedures: [
          fb.Procedure.fromJson({
            'id': 'main',
            'name': 'main',
            'steps': [
              {
                'id': 's1',
                'order': 1,
                'name': 's1',
                'action': {
                  'type': 'tool',
                  'toolRef': 'host.echo',
                  'args': {'text': 'hello'},
                },
              },
            ],
          }),
        ],
      ),
    );

void main() {
  test('a tool step calls the host tool and gets its answer', () async {
    final calls = <String>[];
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      hostTools: (name, args) async {
        calls.add('$name:${args['text']}');
        return KernelToolResult(
          content: [KernelTextContent(text: '{"echoed":"${args['text']}"}')],
        );
      },
    );
    addTearDown(app.shutdown);
    await _register(app);

    final result = await app.system.skill.execute('demo.echo', const {});

    expect(calls, ['host.echo:hello']);
    expect(result.metadata.toolsCalled, ['host.echo']);
  });

  test('the port hands back the host answer, an error result for an error, and throws on a throw',
      () async {
    final ok = HostToolsMcpPort((name, args) async => KernelToolResult(
          content: [KernelTextContent(text: '{"n":1}')],
        ));
    final r = await ok.callTool('x', const {});
    expect(r.isError, isFalse);
    expect(r.content, {'n': 1});

    final plain = HostToolsMcpPort((name, args) async => KernelToolResult(
          content: [KernelTextContent(text: 'just text')],
        ));
    expect((await plain.callTool('x', const {})).content, 'just text');

    final flagged = HostToolsMcpPort((name, args) async => KernelToolResult(
          content: [KernelTextContent(text: 'denied')],
          isError: true,
        ));
    final f = await flagged.callTool('x', const {});
    expect(f.isError, isTrue);
    expect(f.errorMessage, 'denied');

    final thrown = HostToolsMcpPort(
        (name, args) async => throw StateError('no such tool'));
    await expectLater(
      thrown.callTool('x', const {}),
      throwsA(predicate((e) => '$e'.contains('no such tool'))),
    );
  });

  test('without hostTools the step still runs, through the stub port',
      () async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
    );
    addTearDown(app.shutdown);
    await _register(app);

    final result = await app.system.skill.execute('demo.echo', const {});

    expect(result.metadata.stepsExecuted, 1);
  });
}
