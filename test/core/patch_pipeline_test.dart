import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

McpBundle _seed() {
  return McpBundle(
    manifest:
        BundleManifest(id: 'seed', name: 'Seed', version: '0.0.0'),
    skills: const SkillSection(),
  );
}

void main() {
  late Directory tmp;
  late Canonical canonical;
  late PatchPipeline pipeline;
  late UndoRedoStack stack;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_patch_');
    final mbd = p.join(tmp.path, 'app.mbd');
    await McpBundleWriter.writeDirectory(_seed(), mbd);
    canonical = await Canonical.openAt(mbd, draftPath: '$mbd.draft');
    stack = UndoRedoStack();
    pipeline = PatchPipeline(
      canonical: canonical,
      validator: const AssetValidator(),
      undoStack: stack,
    );
  });

  tearDown(() async {
    await canonical.dispose();
    await stack.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('apply commits changes and pushes onto undo stack', () async {
    final result = await pipeline.apply(
      JsonPatchSet([
        const PatchOp(op: 'replace', path: '/manifest/name', value: 'Renamed'),
      ]),
      originator: const UserOriginator(),
    );

    expect(result, isA<PatchApplied>());
    expect(canonical.bundle.manifest.name, 'Renamed');
    expect(stack.canUndo, isTrue);
    expect(stack.canRedo, isFalse);
  });

  test('undo reverts the change; redo re-applies it', () async {
    await pipeline.apply(
      JsonPatchSet([
        const PatchOp(op: 'replace', path: '/manifest/name', value: 'Renamed'),
      ]),
      originator: const UserOriginator(),
    );

    final undone = await pipeline.undo();
    expect(undone, isNotNull);
    expect(canonical.bundle.manifest.name, 'Seed');

    final redone = await pipeline.redo();
    expect(redone, isNotNull);
    expect(canonical.bundle.manifest.name, 'Renamed');
  });

  test('dry-run rejects an agent referencing a missing profile id',
      () async {
    final result = await pipeline.apply(
      JsonPatchSet([
        const PatchOp(
          op: 'add',
          path: '/agents',
          value: {
            'agents': [
              {
                'id': 'a1',
                'name': 'A1',
                'role': 'worker',
                'profileIds': ['missing-profile'],
              }
            ]
          },
        ),
      ]),
      originator: const UserOriginator(),
    );

    expect(result, isA<PatchRejected>());
    final report = (result as PatchRejected).report;
    expect(
      report.errors.any((e) => e.code == 'KB-CR-AGENT-PROFILE-MISSING'),
      isTrue,
    );
    // Canonical untouched on rejection.
    expect(canonical.isDirty, isFalse);
    expect(canonical.bundle.agents, isNull);
    expect(stack.canUndo, isFalse);
  });
}
