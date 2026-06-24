/// Verifies that a bundle's `behavior` section activates into the unified
/// behavior engine via `OpsRuntime.behaviorRegistry`, and runs end-to-end
/// (guard → wait → resume) — the durable "behavior definition" path.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_knowledge_ops/mcp_knowledge_ops.dart' as ko;
import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

Future<FlowBrainWiring> _bootWiring() async {
  final wiring = FlowBrainWiring(
    workspaceId: 'test',
    kvStoragePort: InMemoryKvStoragePort(),
    llmProviders: const <String, LlmPort>{},
  );
  await wiring.boot();
  return wiring;
}

mb.McpBundle _bundleWithBehavior() => mb.McpBundle(
      manifest: mb.BundleManifest(id: 'b', name: 'b', version: '1.0.0'),
      behavior: mb.BehaviorSection(definitions: <mb.BehaviorDefinition>[
        mb.BehaviorDefinition(
          id: 'approve',
          name: 'Approve and finish',
          steps: <mb.BehaviorStepDef>[
            // A pure gate: wait until `approved == true`.
            const mb.BehaviorStepDef(
              id: 'gate',
              when: 'approved == true',
              then: {'false': 'wait'},
            ),
            const mb.BehaviorStepDef(id: 'done'),
          ],
        ),
      ]),
    );

void main() {
  test('activates behavior definitions into the ops runtime', () async {
    final wiring = await _bootWiring();
    final activation = BundleActivation(system: wiring.system, bundleId: 'b');

    final result = await activation.activate(_bundleWithBehavior());
    expect(result.behaviors, 1);
    expect(result.errors, isEmpty);
    expect(activation.registeredBehaviors, contains('b.approve'));

    final runtime = wiring.system.opsRuntime as ko.OpsRuntime;
    expect(runtime.behaviorRegistry.containsKey('b.approve'), isTrue);
  });

  test('runs end-to-end: gate waits then resumes after approval', () async {
    final wiring = await _bootWiring();
    final activation = BundleActivation(system: wiring.system, bundleId: 'b');
    await activation.activate(_bundleWithBehavior());
    final runtime = wiring.system.opsRuntime as ko.OpsRuntime;

    // Separate factory() calls for run vs resume — proves the store is
    // shared per registered behavior (mirrors run/resume via separate tool
    // invocations).
    final first = await runtime.behaviorRegistry['b.approve']!().run('run1', {});
    expect(first.isSuspended, isTrue);
    expect(first.waitingStepId, 'gate');

    // A tool / approver sets the state the guard reads, then resume.
    final store = runtime.behaviorRegistry['b.approve']!().store;
    final saved = await store.load('run1');
    saved!.state['approved'] = true;
    await store.save(saved);

    final resumed =
        await runtime.behaviorRegistry['b.approve']!().resume('run1');
    expect(resumed.isComplete, isTrue);
  });

  test(
      'tool-action dispatches through injected callTool closure (boot == null)',
      () async {
    // Registry-host topology: the host endpoint is a BuiltinToolRegistry, not
    // a raw KernelServerHost, so `boot` is null. Without an injected callTool
    // closure the tool step throws "tool dispatch not wired"; with it the
    // dispatch routes through the closure.
    final wiring = await _bootWiring();
    final calls = <(String, Map<String, dynamic>)>[];
    final activation = BundleActivation(
      system: wiring.system,
      bundleId: 'b',
      // boot intentionally omitted (null) — only the closure is wired.
      callTool: (tool, args) async {
        calls.add((tool, args));
        return KernelToolResult(
          content: const [KernelTextContent(text: '{"ok":true}')],
        );
      },
    );

    final bundle = mb.McpBundle(
      manifest: mb.BundleManifest(id: 'b', name: 'b', version: '1.0.0'),
      behavior: mb.BehaviorSection(definitions: <mb.BehaviorDefinition>[
        mb.BehaviorDefinition(
          id: 'invoke',
          name: 'Invoke a tool',
          steps: <mb.BehaviorStepDef>[
            const mb.BehaviorStepDef(
              id: 'call',
              action: {
                'tool': 'my.tool',
                'args': {'x': 1},
              },
            ),
            const mb.BehaviorStepDef(id: 'done'),
          ],
        ),
      ]),
    );
    final result = await activation.activate(bundle);
    expect(result.errors, isEmpty);

    final runtime = wiring.system.opsRuntime as ko.OpsRuntime;
    final run = await runtime.behaviorRegistry['b.invoke']!().run('run1', {});
    expect(run.isComplete, isTrue);
    // The closure ran with the step's tool ref + args.
    expect(calls, hasLength(1));
    expect(calls.single.$1, 'my.tool');
    expect(calls.single.$2, {'x': 1});
  });

  test('tool-action without boot or callTool throws "not wired"', () async {
    final wiring = await _bootWiring();
    final activation = BundleActivation(system: wiring.system, bundleId: 'b');
    final bundle = mb.McpBundle(
      manifest: mb.BundleManifest(id: 'b', name: 'b', version: '1.0.0'),
      behavior: mb.BehaviorSection(definitions: <mb.BehaviorDefinition>[
        mb.BehaviorDefinition(
          id: 'invoke',
          name: 'Invoke a tool',
          steps: <mb.BehaviorStepDef>[
            const mb.BehaviorStepDef(
              id: 'call',
              action: {'tool': 'my.tool'},
            ),
          ],
        ),
      ]),
    );
    await activation.activate(bundle);
    final runtime = wiring.system.opsRuntime as ko.OpsRuntime;
    final run = await runtime.behaviorRegistry['b.invoke']!().run('run1', {});
    // Dispatch is unwired → the run fails with the diagnostic message.
    expect(run.isComplete, isFalse);
    expect(run.error, contains('tool dispatch not wired'));
  });
}
