/// Regression tests for `HostToolRegistry` — the general-tool wiring
/// layer that pairs the in-process dispatcher with the external
/// endpoint and adds the `<bundleId>.<rawName>` prefix in one call.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('HostToolRegistry', () {
    late Map<String, KernelToolHandler> dispatcher;
    late InProcessKernelServerHost endpoint;
    late HostToolRegistry registry;

    setUp(() {
      dispatcher = <String, KernelToolHandler>{};
      endpoint = InProcessKernelServerHost(
        name: 'host_tool_registry_test',
        version: '0.0.1',
      );
      registry = HostToolRegistry(
        endpoint: endpoint,
        attachToDispatcher: (name, handler) => dispatcher[name] = handler,
        detachFromDispatcher: dispatcher.remove,
      );
    });

    test('exposed name is bundleId-prefixed', () {
      final exposed = registry.registerExposed(
        bundleId: 'recipe_a',
        rawName: 'editor.open',
        description: 'Open editor',
        handler: (_) async => KernelToolResult(
          content: <KernelContent>[KernelTextContent(text: 'opened')],
        ),
      );
      expect(exposed, 'recipe_a.editor.open');
      expect(dispatcher.containsKey('recipe_a.editor.open'), isTrue);
      expect(
        endpoint.toolDefinitions.map((d) => d.name),
        contains('recipe_a.editor.open'),
      );
    });

    test('two bundles with the same raw name register without collision',
        () {
      registry.registerExposed(
        bundleId: 'recipe_a',
        rawName: 'editor.open',
        description: 'A open',
        handler: (_) async => KernelToolResult(
          content: <KernelContent>[KernelTextContent(text: 'A')],
        ),
      );
      registry.registerExposed(
        bundleId: 'recipe_b',
        rawName: 'editor.open',
        description: 'B open',
        handler: (_) async => KernelToolResult(
          content: <KernelContent>[KernelTextContent(text: 'B')],
        ),
      );
      expect(dispatcher.keys.toSet(), {
        'recipe_a.editor.open',
        'recipe_b.editor.open',
      });
      final names = endpoint.toolDefinitions.map((d) => d.name).toSet();
      expect(names, containsAll(<String>{
        'recipe_a.editor.open',
        'recipe_b.editor.open',
      }));
    });

    test('unregisterExposed removes from both layers', () async {
      final exposed = registry.registerExposed(
        bundleId: 'recipe_a',
        rawName: 'editor.open',
        description: 'Open editor',
        handler: (_) async => KernelToolResult(
          content: <KernelContent>[KernelTextContent(text: 'opened')],
        ),
      );
      expect(dispatcher.containsKey(exposed), isTrue);

      final removed = registry.unregisterExposed(
        bundleId: 'recipe_a',
        rawName: 'editor.open',
      );
      expect(removed, exposed);
      expect(dispatcher.containsKey(exposed), isFalse);
      expect(
        endpoint.toolDefinitions.map((d) => d.name),
        isNot(contains(exposed)),
      );
    });

    test('endpoint callTool dispatches via the registered handler',
        () async {
      registry.registerExposed(
        bundleId: 'recipe_a',
        rawName: 'echo',
        description: 'Echo handler',
        inputSchema: const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'text': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['text'],
        },
        handler: (args) async => KernelToolResult(
          content: <KernelContent>[
            KernelTextContent(text: 'echoed:${args['text']}'),
          ],
        ),
      );
      final result = await endpoint.callTool(
        'recipe_a.echo',
        <String, dynamic>{'text': 'hi'},
      );
      expect(result.isError, isNot(isTrue));
      expect((result.content.first as KernelTextContent).text, 'echoed:hi');
    });

    // ── §6 destructive gate ────────────────────────────────────────────

    HostToolRegistry registryWith(ConfirmDestructive? confirm) =>
        HostToolRegistry(
          endpoint: endpoint,
          attachToDispatcher: (name, handler) => dispatcher[name] = handler,
          detachFromDispatcher: dispatcher.remove,
          confirmDestructive: confirm,
        );

    test('destructive tool blocked when no confirm callback wired (§6)',
        () async {
      var ran = false;
      registry.registerExposed(
        bundleId: 'ops',
        rawName: 'git.push',
        description: 'git push',
        destructive: true,
        handler: (_) async {
          ran = true;
          return KernelToolResult(
            content: <KernelContent>[KernelTextContent(text: 'pushed')],
          );
        },
      );
      final result =
          await endpoint.callTool('ops.git.push', <String, dynamic>{});
      expect(result.isError, isTrue);
      expect((result.content.first as KernelTextContent).text,
          contains('destructive_action_blocked'));
      expect(ran, isFalse);
    });

    test('destructive tool blocked when the human declines (§6)', () async {
      var ran = false;
      registryWith((_, __) async => false).registerExposed(
        bundleId: 'ops',
        rawName: 'mail.send',
        description: 'send mail',
        destructive: true,
        handler: (_) async {
          ran = true;
          return KernelToolResult(
            content: <KernelContent>[KernelTextContent(text: 'sent')],
          );
        },
      );
      final result =
          await endpoint.callTool('ops.mail.send', <String, dynamic>{});
      expect(result.isError, isTrue);
      expect(ran, isFalse);
    });

    test('destructive tool runs when the human approves (§6)', () async {
      var ran = false;
      registryWith((_, __) async => true).registerExposed(
        bundleId: 'ops',
        rawName: 'deploy',
        description: 'deploy',
        destructive: true,
        handler: (_) async {
          ran = true;
          return KernelToolResult(
            content: <KernelContent>[KernelTextContent(text: 'deployed')],
          );
        },
      );
      final result = await endpoint.callTool('ops.deploy', <String, dynamic>{});
      expect(result.isError, isNot(isTrue));
      expect(ran, isTrue);
      expect((result.content.first as KernelTextContent).text, 'deployed');
    });
  });
}
