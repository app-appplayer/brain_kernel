/// A skill's `llm` step uses the host's provider when there is one, the
/// connected client's model through sampling when there is not, and fails
/// when there is neither (platform spec 30 §8).
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

class _Adapter extends LlmPortAdapter {
  _Adapter(this.log) : super(modelId: 'x', apiKey: 'k');
  final List<String> log;
  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest r) async {
    log.add('internal:${r.messages?.last.content ?? r.prompt}');
    return const mb.LlmResponse(content: 'from internal');
  }

}

Future<void> _register(KernelApp app) =>
    app.system.skillRuntime!.registry.registerSkill(
      fb.SkillBundle(
        schemaVersion: '0.1.0',
        manifest: const fb.SkillManifest(
          id: 'demo.ask',
          name: 'ask',
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
                'action': {'type': 'llm', 'prompt': 'hello'},
              },
            ],
          }),
        ],
      ),
    );

void main() {
  test('with no provider the connected client answers by sampling', () async {
    final asked = <String>[];
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      sampling: ({required prompt, systemPrompt, temperature, maxTokens = 0}) async {
        asked.add(prompt);
        return 'from client';
      },
    );
    addTearDown(app.shutdown);
    await _register(app);

    await app.system.skill.execute('demo.ask', const {});

    expect(asked, ['hello']);
  });

  test('a provider the host set after boot is used before sampling', () async {
    final log = <String>[];
    final asked = <String>[];
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      sampling: ({required prompt, systemPrompt, temperature, maxTokens = 0}) async {
        asked.add(prompt);
        return 'from client';
      },
    );
    addTearDown(app.shutdown);
    await _register(app);
    app.agentLlmSessions.register('main', _Adapter(log));

    await app.system.skill.execute('demo.ask', const {});

    expect(log, ['internal:hello']);
    expect(asked, isEmpty);
  });

  test('a client that cannot sample fails the step instead of answering empty',
      () async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      sampling: ({required prompt, systemPrompt, temperature, maxTokens = 0}) =>
          throw StateError('client does not support sampling'),
    );
    addTearDown(app.shutdown);
    await _register(app);

    final r = await app.system.skill.execute('demo.ask', const {});

    expect('${r.metadata.custom?['error']}',
        contains('does not support sampling'));
  });

  test('bk.skill.execute does not call a failed skill ok', () async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      sampling: ({required prompt, systemPrompt, temperature, maxTokens = 0}) =>
          throw StateError('client does not support sampling'),
    );
    addTearDown(app.shutdown);
    await _register(app);

    final r = Map<String, dynamic>.from(
      await standardTools(app)['bk.skill.execute']!({'skillId': 'demo.ask'})
          as Map,
    );

    expect(r['ok'], isNot(true));
    expect('${r['error'] ?? r}', contains('does not support sampling'));
  });
}
