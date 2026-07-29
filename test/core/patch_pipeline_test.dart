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

  test('PatchApplied carries the real before/after hashes (not empty)',
      () async {
    // Regression: the pipeline used to hardcode beforeHash/afterHash to ''
    // instead of forwarding the hashes applyAtomic already computes for the
    // change stream. A consumer reading the result inline (rather than
    // correlating the `changes` stream) got silent empty strings.
    final result = await pipeline.apply(
      JsonPatchSet([
        const PatchOp(op: 'replace', path: '/manifest/name', value: 'Renamed'),
      ]),
      originator: const UserOriginator(),
    );

    final applied = result as PatchApplied;
    expect(applied.beforeHash, isNotEmpty);
    expect(applied.afterHash, isNotEmpty);
    // The mutation changed the bundle, so the hashes must differ.
    expect(applied.afterHash, isNot(applied.beforeHash));
    // Sanity: canonical sha256 hex digest length.
    expect(applied.beforeHash, hasLength(64));
    expect(applied.afterHash, hasLength(64));
  });

  test('undo/redo PatchApplied also carry real hashes', () async {
    await pipeline.apply(
      JsonPatchSet([
        const PatchOp(op: 'replace', path: '/manifest/name', value: 'Renamed'),
      ]),
      originator: const UserOriginator(),
    );
    final undone = await pipeline.undo() as PatchApplied;
    expect(undone.beforeHash, isNotEmpty);
    expect(undone.afterHash, isNotEmpty);
    expect(undone.afterHash, isNot(undone.beforeHash));

    final redone = await pipeline.redo() as PatchApplied;
    expect(redone.beforeHash, isNotEmpty);
    expect(redone.afterHash, isNotEmpty);
    expect(redone.afterHash, isNot(redone.beforeHash));
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
