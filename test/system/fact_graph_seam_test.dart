/// KernelApp.boot takes an optional L0 runtime. Without it nothing changes
/// (platform spec 30 §10 — shared layers only add).
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

void main() {
  test('boot without a runtime keeps the default in-memory graph', () async {
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
    );
    addTearDown(app.shutdown);
    await app.system.facts.writeFacts([
      mb.FactRecord(
        id: 'f1',
        workspaceId: 'ws',
        type: 'note',
        content: const {'k': 'v'},
        createdAt: DateTime.utc(2026, 10, 30),
      ),
    ]);
    expect(await app.system.facts.getFact('f1'), isNotNull);
  });

  test('a runtime handed to boot is the one the system uses', () async {
    final runtime = fb.FactGraphRuntime.inMemory(defaultWorkspaceId: 'ws');
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      factGraph: runtime,
    );
    addTearDown(app.shutdown);
    expect(identical(app.system.factGraph, runtime), isTrue);
  });

  test('agent ports handed to boot reach the agents; without them agents are '
      'unchanged (spec 30 §5.1)', () async {
    final seen = <String>[];
    final out = _Outputs();
    final llm = _Echo();
    final app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      llmProviders: const <String, LlmPortAdapter>{},
      fallbackLlm: llm,
      agentContext: _Context(seen, 'STATE: step 3'),
      agentOutputs: out,
    );
    addTearDown(app.shutdown);
    await app.system.agents.createAgent(
      id: 'a',
      displayName: 'A',
      model: const fb.ModelSpec(provider: 'x', model: 'x'),
      workspaceId: 'ws',
    );
    await app.system.agents.ask('a', 'go');
    expect(seen, ['a']);
    expect(llm.system, contains('STATE: step 3'));
    expect(out.recorded.single.content, 'ok');

    final plain = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
      fallbackLlm: _Echo(),
    );
    addTearDown(plain.shutdown);
    await plain.system.agents.createAgent(
      id: 'a',
      displayName: 'A',
      model: const fb.ModelSpec(provider: 'x', model: 'x'),
      workspaceId: 'ws',
    );
    final r = await plain.system.agents.ask('a', 'go');
    expect(r.content, 'ok');
  });
}

class _Echo extends mb.LlmPort {
  String? system;

  @override
  mb.LlmCapabilities get capabilities => const mb.LlmCapabilities.minimal();

  @override
  Future<mb.LlmResponse> complete(mb.LlmRequest request) async {
    system = request.systemPrompt;
    return const mb.LlmResponse(content: 'ok');
  }
}

class _Context implements fb.AgentContextPort {
  _Context(this.seen, this.text);
  final List<String> seen;
  final String text;

  @override
  Future<fb.AgentContext?> contextFor(String agentId, String request,
      {String? workspaceId, DateTime? asOf}) async {
    seen.add(agentId);
    return fb.AgentContext(text: text);
  }
}

class _Outputs implements fb.AgentOutputPort {
  final recorded = <fb.AgentOutput>[];

  @override
  Future<void> record(fb.AgentOutput output) async => recorded.add(output);
}
