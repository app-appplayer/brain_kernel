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
}
