/// Philosophy feedback history and evolution proposals live in the kernel's
/// key/value store, so a host with a durable KV keeps them across restarts.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

void main() {
  test('feedback and proposals survive booting again on the same KV',
      () async {
    final kv = mb.InMemoryKvStoragePort();

    final first = await KernelApp.boot(
        workspaceId: 'ws', kvStorage: kv, philosophyEvolution: true);
    final engine = first.system.philosophyEngine!;
    final ethos = await first.system.philosophy.getEthos();
    for (var i = 0; i < 4; i++) {
      await first.system.philosophy.proposeFeedback(mb.FeedbackEvent(
        id: 'fb-$i',
        actionId: 'review:agent-1',
        ethosId: ethos.id,
        valuePriorityId: ethos.valuePriorities.first.id,
        outcome: mb.FeedbackOutcome.positive,
        outcomeScore: 1.0,
        outcomeDescription: 'reviewer verdict: pass',
        occurredAt: DateTime.utc(2026, 10, 30, 12, i),
      ));
    }
    final before = await engine.listProposals();
    await first.shutdown();

    final second = await KernelApp.boot(
        workspaceId: 'ws', kvStorage: kv, philosophyEvolution: true);
    final after = await second.system.philosophyEngine!.listProposals();
    expect(before, isNotEmpty, reason: 'four positive reviews propose');
    expect(after.map((p) => p.id).toSet(), before.map((p) => p.id).toSet());
    await second.shutdown();
    expect(fb.KnowledgeSystem, isNotNull);
  });

  test('without the host asking for evolution, feedback makes no proposal',
      () async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
    );
    final ethos = await app.system.philosophy.getEthos();
    for (var i = 0; i < 4; i++) {
      final proposed = await app.system.philosophy.proposeFeedback(
        mb.FeedbackEvent(
          id: 'fb-$i',
          actionId: 'review:agent-1',
          ethosId: ethos.id,
          valuePriorityId: ethos.valuePriorities.first.id,
          outcome: mb.FeedbackOutcome.positive,
          outcomeScore: 1.0,
          outcomeDescription: 'reviewer verdict: pass',
          occurredAt: DateTime.utc(2026, 10, 30, 12, i),
        ),
      );
      expect(proposed, isNull);
    }
    expect(await app.system.philosophyEngine!.listProposals(), isEmpty);
    await app.shutdown();
  });

  test('a fresh KV starts with none', () async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
    );
    expect(await app.system.philosophyEngine!.listProposals(), isEmpty);
    await app.shutdown();
  });
}
