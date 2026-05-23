import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_reviewer_queue_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('pushNew + find + reject + clear round-trip', () async {
    final project = await Project.newAt(p.join(tmp.path, 'A.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id = queue.pushNew(
      category: AssetCategory.philosophy,
      newAssetJson: <String, dynamic>{
        'id': 'reuse',
        'name': 'Reuse first',
        'statement': 'Prefer proven patterns.',
      },
      source: ProposalSource.userIntent,
      toolName: 'kb_add_philosophy',
    );

    expect(queue.pending, hasLength(1));
    expect(queue.find(id)?.toolName, 'kb_add_philosophy');

    expect(queue.reject(id), isTrue);
    expect(queue.pending, isEmpty);
    expect(queue.reject('missing'), isFalse);

    queue.pushNew(
      category: AssetCategory.philosophy,
      newAssetJson: <String, dynamic>{
        'id': 'p2',
        'name': 'P2',
        'statement': 'X',
      },
      source: ProposalSource.userIntent,
    );
    queue.clear();
    expect(queue.pending, isEmpty);

    await undo.dispose();
    await project.close();
  });

  test('approve commits to canonical via PatchPipeline', () async {
    final project = await Project.newAt(p.join(tmp.path, 'B.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id = queue.pushNew(
      category: AssetCategory.philosophy,
      newAssetJson: <String, dynamic>{
        'id': 'reuse',
        'name': 'Reuse first',
        'statement': 'Prefer proven patterns.',
      },
      source: ProposalSource.userIntent,
    );

    final result = await queue.approve(
      id,
      originator: const UserOriginator(),
    );
    expect(result, isA<PatchApplied>());
    expect(queue.pending, isEmpty,
        reason: 'approved proposal must leave the queue');

    final philosophies =
        project.canonical.bundle.philosophy?.philosophies ?? const [];
    expect(philosophies, hasLength(1));
    expect(philosophies.single.id, 'reuse');

    await undo.dispose();
    await project.close();
  });

  // Regression — N-asset accumulation across multiple approvals.
  // Prior to the state-aware _toPatch fix, the second approve in each
  // category emitted an `add` op to the section root (e.g. `/skills`)
  // that, per RFC 6902 §4.1 add-on-existing-member, silently replaced
  // the previously committed assets. These tests pin the accumulation
  // semantics so that regression cannot reappear.

  test('approve accumulates skill assets across approvals', () async {
    final project = await Project.newAt(p.join(tmp.path, 'D.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id1 = queue.pushNew(
      category: AssetCategory.skill,
      newAssetJson: <String, dynamic>{
        'id': 'sk-A',
        'name': 'A',
        'description': 'first',
      },
      source: ProposalSource.userIntent,
    );
    final r1 = await queue.approve(id1, originator: const UserOriginator());
    expect(r1, isA<PatchApplied>());

    final id2 = queue.pushNew(
      category: AssetCategory.skill,
      newAssetJson: <String, dynamic>{
        'id': 'sk-B',
        'name': 'B',
        'description': 'second',
      },
      source: ProposalSource.userIntent,
    );
    final r2 = await queue.approve(id2, originator: const UserOriginator());
    expect(r2, isA<PatchApplied>());

    final modules = project.canonical.bundle.skills?.modules ?? const [];
    expect(modules, hasLength(2),
        reason: 'both skills should remain after sequential approvals');
    expect(modules.map((m) => m.id).toList(), equals(['sk-A', 'sk-B']));

    await undo.dispose();
    await project.close();
  });

  test('approve accumulates profile assets across approvals', () async {
    final project = await Project.newAt(p.join(tmp.path, 'E.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id1 = queue.pushNew(
      category: AssetCategory.profile,
      newAssetJson: <String, dynamic>{
        'id': 'pr-A',
        'name': 'A',
      },
      source: ProposalSource.userIntent,
    );
    await queue.approve(id1, originator: const UserOriginator());

    final id2 = queue.pushNew(
      category: AssetCategory.profile,
      newAssetJson: <String, dynamic>{
        'id': 'pr-B',
        'name': 'B',
      },
      source: ProposalSource.userIntent,
    );
    await queue.approve(id2, originator: const UserOriginator());

    final profiles =
        project.canonical.bundle.profiles?.profiles ?? const [];
    expect(profiles, hasLength(2),
        reason: 'both profiles should remain after sequential approvals');
    expect(profiles.map((p) => p.id).toList(), equals(['pr-A', 'pr-B']));

    await undo.dispose();
    await project.close();
  });

  test('approve accumulates philosophy assets across approvals', () async {
    final project = await Project.newAt(p.join(tmp.path, 'F.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id1 = queue.pushNew(
      category: AssetCategory.philosophy,
      newAssetJson: <String, dynamic>{
        'id': 'ph-A',
        'name': 'A',
        'statement': 'first',
      },
      source: ProposalSource.userIntent,
    );
    await queue.approve(id1, originator: const UserOriginator());

    final id2 = queue.pushNew(
      category: AssetCategory.philosophy,
      newAssetJson: <String, dynamic>{
        'id': 'ph-B',
        'name': 'B',
        'statement': 'second',
      },
      source: ProposalSource.userIntent,
    );
    await queue.approve(id2, originator: const UserOriginator());

    final phs =
        project.canonical.bundle.philosophy?.philosophies ?? const [];
    expect(phs, hasLength(2),
        reason: 'both philosophies should remain after sequential approvals');
    expect(phs.map((p) => p.id).toList(), equals(['ph-A', 'ph-B']));

    await undo.dispose();
    await project.close();
  });

  test('approve accumulates agent assets across approvals', () async {
    final project = await Project.newAt(p.join(tmp.path, 'G.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id1 = queue.pushNew(
      category: AssetCategory.agent,
      newAssetJson: <String, dynamic>{
        'id': 'ag-A',
        'name': 'A',
        'role': 'worker',
      },
      source: ProposalSource.userIntent,
    );
    await queue.approve(id1, originator: const UserOriginator());

    final id2 = queue.pushNew(
      category: AssetCategory.agent,
      newAssetJson: <String, dynamic>{
        'id': 'ag-B',
        'name': 'B',
        'role': 'worker',
      },
      source: ProposalSource.userIntent,
    );
    await queue.approve(id2, originator: const UserOriginator());

    final agents = project.canonical.bundle.agents?.agents ?? const [];
    expect(agents, hasLength(2),
        reason: 'both agents should remain after sequential approvals');
    expect(agents.map((a) => a.id).toList(), equals(['ag-A', 'ag-B']));

    await undo.dispose();
    await project.close();
  });

  test('approve accumulates chunks (KnowledgeDocument) across approvals',
      () async {
    final project = await Project.newAt(p.join(tmp.path, 'H.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id1 = queue.pushNew(
      category: AssetCategory.chunks,
      newAssetJson: <String, dynamic>{
        'id': 'doc-A',
        'content': 'first',
        'format': 'text',
      },
      source: ProposalSource.userIntent,
    );
    final r1 = await queue.approve(id1, originator: const UserOriginator());
    expect(r1, isA<PatchApplied>(),
        reason: 'first approve must commit (was throwing '
            '`Cannot add to an unmodifiable list` pre-fix)');

    final id2 = queue.pushNew(
      category: AssetCategory.chunks,
      newAssetJson: <String, dynamic>{
        'id': 'doc-B',
        'content': 'second',
        'format': 'text',
      },
      source: ProposalSource.userIntent,
    );
    final r2 = await queue.approve(id2, originator: const UserOriginator());
    expect(r2, isA<PatchApplied>());

    final sources = project.canonical.bundle.knowledge?.sources ?? const [];
    expect(sources, hasLength(1));
    final docs = sources.first.documents ?? const [];
    expect(docs, hasLength(2),
        reason: 'both documents should remain after sequential approvals');
    expect(docs.map((d) => d.id).toList(), equals(['doc-A', 'doc-B']));

    await undo.dispose();
    await project.close();
  });

  test('approve accumulates fact assets across approvals', () async {
    final project = await Project.newAt(p.join(tmp.path, 'I.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    final id1 = queue.pushNew(
      category: AssetCategory.fact,
      newAssetJson: <String, dynamic>{
        'id': 'f-A',
        'subject': 'X',
        'predicate': 'is',
        'object': 'Y',
      },
      source: ProposalSource.userIntent,
    );
    final r1 = await queue.approve(id1, originator: const UserOriginator());
    expect(r1, isA<PatchApplied>(),
        reason: 'first approve must commit (was throwing '
            '`Cannot add to an unmodifiable list` pre-fix)');

    final id2 = queue.pushNew(
      category: AssetCategory.fact,
      newAssetJson: <String, dynamic>{
        'id': 'f-B',
        'subject': 'P',
        'predicate': 'is',
        'object': 'Q',
      },
      source: ProposalSource.userIntent,
    );
    final r2 = await queue.approve(id2, originator: const UserOriginator());
    expect(r2, isA<PatchApplied>());

    // Read facts via canonical.toJson() — embedded fact list lives at
    // /factGraphSection/embedded/facts (mcp_bundle's wired slot for
    // fact instance data). The JSON snapshot is the deterministic
    // check.
    final json = project.canonical.bundle.toJson();
    final facts = (((json['factGraphSection']
            as Map<String, dynamic>?)?['embedded'] as Map<String, dynamic>?)?[
        'facts'] as List?) ??
        const [];
    expect(facts, hasLength(2),
        reason: 'both facts should remain after sequential approvals');
    expect(
      facts.map((f) => (f as Map)['id']).toList(),
      equals(['f-A', 'f-B']),
    );

    await undo.dispose();
    await project.close();
  });

  test('approve keeps proposal queued when validation rejects', () async {
    final project = await Project.newAt(p.join(tmp.path, 'C.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);

    // Agent referencing a missing profile id — cross-ref will reject.
    final id = queue.pushNew(
      category: AssetCategory.agent,
      newAssetJson: <String, dynamic>{
        'id': 'a1',
        'name': 'A',
        'role': 'worker',
        'profileIds': ['missing'],
      },
      source: ProposalSource.userIntent,
    );

    final result = await queue.approve(
      id,
      originator: const UserOriginator(),
    );
    expect(result, isA<PatchRejected>());
    expect(queue.pending, hasLength(1),
        reason:
            'rejected proposal stays in the queue so the user can retry');

    await undo.dispose();
    await project.close();
  });
}
