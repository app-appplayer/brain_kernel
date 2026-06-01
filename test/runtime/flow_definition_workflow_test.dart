/// Unit tests for `_evalCondition` (parentheses precedence) and
/// graph-shaped `step.next[]` traversal in [FlowDefinitionWorkflow].
///
/// The workflow's other paths (action / api / skill / llm / flow
/// dispatchers) are covered by integration suites — these tests focus
/// on the two extensions added 2026-05-29.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_knowledge_ops/mcp_knowledge_ops.dart' as fb;
import 'package:test/test.dart';

fb.WorkflowContext _ctx() => fb.WorkflowContext(
      runId: 't',
      workspaceId: 'ws',
      userId: 'user',
      asOf: DateTime.fromMillisecondsSinceEpoch(0),
      config: const fb.WorkflowConfig(),
    );

void main() {
  group('FlowDefinitionWorkflow — _evalCondition parentheses', () {
    Future<fb.WorkflowResult<Map<String, dynamic>>> runWith({
      required String condition,
      required Map<String, dynamic> input,
    }) {
      final wf = FlowDefinitionWorkflow(
        mb.FlowDefinition(
          id: 'parens',
          name: 'parens',
          trigger: const mb.FlowTrigger(type: mb.TriggerType.manual),
          steps: <mb.FlowStep>[
            mb.FlowStep(
              id: 'gated',
              type: mb.StepType.action,
              condition: condition,
              config: const <String, dynamic>{
                'tool': 'noop',
                'args': <String, dynamic>{},
              },
            ),
          ],
        ),
      );
      return wf.run(input, _ctx());
    }

    bool stepRan(fb.WorkflowResult<Map<String, dynamic>> r) {
      // Stage is reached unless skipped. Without a dispatcher the step
      // fails with STEP_FAILED — that means condition was truthy.
      final stages = r.stages;
      if (stages.isEmpty) return false;
      return stages.first.status != fb.StageStatus.skipped;
    }

    test('outer parens around whole expression', () async {
      final r = await runWith(
        condition: '(a == 1)',
        input: <String, dynamic>{'a': 1},
      );
      expect(stepRan(r), isTrue);
    });

    test('outer parens around OR — falsy → skipped', () async {
      final r = await runWith(
        condition: '(a == 1 || b == 2)',
        input: <String, dynamic>{'a': 99, 'b': 99},
      );
      expect(stepRan(r), isFalse);
    });

    test('precedence: (a || b) && c — a true makes whole truthy',
        () async {
      final r = await runWith(
        condition: '(a == 1 || a == 2) && c == 3',
        input: <String, dynamic>{'a': 1, 'c': 3},
      );
      expect(stepRan(r), isTrue);
    });

    test('precedence: (a || b) && c — c false makes whole falsy',
        () async {
      final r = await runWith(
        condition: '(a == 1 || a == 2) && c == 3',
        input: <String, dynamic>{'a': 1, 'c': 99},
      );
      expect(stepRan(r), isFalse);
    });

    test('nested parens: ((x))', () async {
      final r = await runWith(
        condition: '((x == 1))',
        input: <String, dynamic>{'x': 1},
      );
      expect(stepRan(r), isTrue);
    });

    test('parens do not swallow trailing top-level operator', () async {
      // `(a) && (b)` is NOT wrapped by one outer pair — must not strip
      // the first `(` together with the last `)`.
      final r = await runWith(
        condition: '(a == 1) && (b == 2)',
        input: <String, dynamic>{'a': 1, 'b': 99},
      );
      expect(stepRan(r), isFalse);
    });
  });

  group('FlowDefinitionWorkflow — step.next[] graph traversal', () {
    test('linear flow (no next[]) runs steps in declaration order',
        () async {
      final wf = FlowDefinitionWorkflow(
        mb.FlowDefinition(
          id: 'linear',
          name: 'linear',
          trigger: const mb.FlowTrigger(type: mb.TriggerType.manual),
          steps: <mb.FlowStep>[
            mb.FlowStep(
              id: 'a',
              type: mb.StepType.action,
              condition: 'true',
            ),
            mb.FlowStep(
              id: 'b',
              type: mb.StepType.action,
              condition: 'true',
            ),
          ],
        ),
      );
      final r = await wf.run(const <String, dynamic>{}, _ctx());
      expect(r.stages.first.stageId, equals('a'));
    });

    test('graph flow (step.next[]) follows declared edges', () async {
      // a → c (skip b in array order). Graph walker follows
      // `a.next = [c]`; `b` is disconnected and appended after BFS.
      final wf = FlowDefinitionWorkflow(
        mb.FlowDefinition(
          id: 'graph',
          name: 'graph',
          trigger: const mb.FlowTrigger(type: mb.TriggerType.manual),
          steps: <mb.FlowStep>[
            mb.FlowStep(
              id: 'a',
              type: mb.StepType.action,
              condition: 'true',
              next: const <String>['c'],
              onError: '__continue',
            ),
            mb.FlowStep(
              id: 'b',
              type: mb.StepType.action,
              condition: 'true',
              onError: '__continue',
            ),
            mb.FlowStep(
              id: 'c',
              type: mb.StepType.action,
              condition: 'true',
              onError: '__continue',
            ),
          ],
        ),
      );
      final r = await wf.run(const <String, dynamic>{}, _ctx());
      final ids = r.stages.map((s) => s.stageId).toList();
      expect(ids, equals(<String>['a', 'c', 'b']));
    });

    test('cycle protection: a ↔ b never revisits', () async {
      final wf = FlowDefinitionWorkflow(
        mb.FlowDefinition(
          id: 'cycle',
          name: 'cycle',
          trigger: const mb.FlowTrigger(type: mb.TriggerType.manual),
          steps: <mb.FlowStep>[
            mb.FlowStep(
              id: 'a',
              type: mb.StepType.action,
              condition: 'true',
              next: const <String>['b'],
              onError: '__continue',
            ),
            mb.FlowStep(
              id: 'b',
              type: mb.StepType.action,
              condition: 'true',
              next: const <String>['a'],
              onError: '__continue',
            ),
          ],
        ),
      );
      final r = await wf.run(const <String, dynamic>{}, _ctx());
      final ids = r.stages.map((s) => s.stageId).toList();
      expect(ids, equals(<String>['a', 'b']));
    });
  });
}
