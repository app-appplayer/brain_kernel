/// An agent called from a flow step says which flow, run and step it came
/// from (platform spec 12 §0.5) — for a workflow and for a behavior alike.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_knowledge_ops/mcp_knowledge_ops.dart' as ko;
import 'package:test/test.dart';

class _Llm extends mb.LlmPort {
  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities.minimal();

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async =>
      const mb.LlmResponse(content: 'done');
}

class _Outputs implements fb.AgentOutputPort {
  final recorded = <fb.AgentOutput>[];

  @override
  Future<void> record(fb.AgentOutput output) async => recorded.add(output);
}

void main() {
  late KernelApp app;
  late _Outputs out;
  late BundleActivation activation;
  final seenArgs = <Map<String, dynamic>>[];

  setUp(() async {
    out = _Outputs();
    seenArgs.clear();
    app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      fallbackLlm: _Llm(),
      agentOutputs: out,
    );
    await app.system.agents.createAgent(
      id: 'worker',
      displayName: 'Worker',
      model: const fb.ModelSpec(provider: 'x', model: 'x'),
      workspaceId: 'ws',
    );
    final tools = standardTools(app);
    activation = BundleActivation(
      system: app.system,
      bundleId: 'org',
      callTool: (tool, args) async {
        seenArgs.add(Map<String, dynamic>.of(args));
        final result = await tools[tool]!(args);
        return KernelToolResult(
          content: [KernelTextContent(text: jsonEncode(result))],
        );
      },
    );
  });
  tearDown(() => app.shutdown());

  test('a workflow step: flow id, run id and step id are on the record',
      () async {
    final r = await activation.activate(mb.McpBundle(
      manifest: mb.BundleManifest(id: 'org', name: 'org', version: '1'),
      flow: mb.FlowSection(flows: [
        mb.FlowDefinition(
          id: 'publish',
          name: 'publish',
          trigger: const mb.FlowTrigger(type: mb.TriggerType.manual),
          steps: [
            mb.FlowStep(id: 'draft', type: mb.StepType.action, config: const {
              'tool': 'bk.agent.ask',
              'args': {'agentId': 'worker', 'message': 'draft it'},
            }),
          ],
        ),
      ]),
    ));
    expect(r.errors, isEmpty);

    final run = await app.system.ops.runWorkflow('org.publish', {});
    expect(run.status, 'succeeded');
    final flow = out.recorded.single.flow!;
    expect(flow.kind, 'workflow');
    expect(flow.flowId, 'org.publish');
    expect(flow.runId, run.runId);
    expect(flow.stepId, 'draft');
  });

  test('a behavior step: the same, and the tool never sees the marker',
      () async {
    final r = await activation.activate(mb.McpBundle(
      manifest: mb.BundleManifest(id: 'org', name: 'org', version: '1'),
      behavior: mb.BehaviorSection(definitions: [
        mb.BehaviorDefinition(
          id: 'review',
          name: 'review',
          steps: [
            const mb.BehaviorStepDef(id: 'ask', action: {
              'tool': 'bk.agent.ask',
              'args': {'agentId': 'worker', 'message': 'check it'},
            }),
            const mb.BehaviorStepDef(id: 'done'),
          ],
        ),
      ]),
    ));
    expect(r.errors, isEmpty);

    final runtime = app.system.opsRuntime as ko.OpsRuntime;
    final run =
        await runtime.behaviorRegistry['org.review']!().run('run-7', {});
    expect(run.isComplete, isTrue);

    final flow = out.recorded.single.flow!;
    expect(flow.kind, 'behavior');
    expect(flow.flowId, 'org.review');
    expect(flow.runId, 'run-7');
    expect(flow.stepId, 'ask');
    expect(seenArgs.single.keys, isNot(contains('__fbStep')));
    expect(seenArgs.single['agentId'], 'worker');
  });

  test('an agent asked outside any flow has no flow on its record', () async {
    await app.system.agents.ask('worker', 'hello');
    expect(out.recorded.single.flow, isNull);
  });
}
