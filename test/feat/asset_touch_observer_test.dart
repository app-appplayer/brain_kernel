import 'dart:async';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_asset_touch_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<({Project project, PatchPipeline pipeline, ReviewerQueue queue})>
      _bootstrap(String slug) async {
    final project = await Project.newAt(p.join(tmp.path, '$slug.kbproj'));
    final undo = UndoRedoStack();
    final pipeline = PatchPipeline(
      canonical: project.canonical,
      validator: const AssetValidator(),
      undoStack: undo,
    );
    final queue = ReviewerQueue(pipeline: pipeline);
    return (project: project, pipeline: pipeline, queue: queue);
  }

  Future<List<AssetTouch>> _collect(
    AssetTouchObserver observer,
    Future<void> Function() driver, {
    Duration grace = const Duration(milliseconds: 50),
  }) async {
    final captured = <AssetTouch>[];
    final sub = observer.touches.listen(captured.add);
    await driver();
    await Future<void>.delayed(grace);
    await sub.cancel();
    return captured;
  }

  test('skill add + update emits category=skill with resolved id', () async {
    final boot = await _bootstrap('A');
    final observer = AssetTouchObserver(canonical: boot.project.canonical);

    final touches = await _collect(observer, () async {
      final id = boot.queue.pushNew(
        category: AssetCategory.skill,
        newAssetJson: <String, dynamic>{
          'id': 'sk-1',
          'name': 'first',
          'description': 'd',
          'version': '1.0.0',
        },
        source: ProposalSource.userIntent,
      );
      await boot.queue.approve(id, originator: const UserOriginator());
    });

    expect(touches, isNotEmpty);
    expect(touches.first.category, AssetCategory.skill);
    expect(touches.first.id, 'sk-1');
    expect(touches.first.kind, CanonicalChangeKind.patch);
    expect(observer.last?.id, 'sk-1');

    await observer.dispose();
    await boot.project.close();
  });

  test('profile / philosophy / agent route to correct categories', () async {
    final boot = await _bootstrap('B');
    final observer = AssetTouchObserver(canonical: boot.project.canonical);

    final touches = await _collect(observer, () async {
      final pid = boot.queue.pushNew(
        category: AssetCategory.profile,
        newAssetJson: <String, dynamic>{
          'id': 'p-1',
          'name': 'P',
          'version': '1.0.0',
          'description': 'd',
        },
        source: ProposalSource.userIntent,
      );
      await boot.queue.approve(pid, originator: const UserOriginator());

      final phid = boot.queue.pushNew(
        category: AssetCategory.philosophy,
        newAssetJson: <String, dynamic>{
          'id': 'ph-1',
          'name': 'Ph',
          'statement': 'S',
        },
        source: ProposalSource.userIntent,
      );
      await boot.queue.approve(phid, originator: const UserOriginator());

      final aid = boot.queue.pushNew(
        category: AssetCategory.agent,
        newAssetJson: <String, dynamic>{
          'id': 'a-1',
          'name': 'A',
          'role': 'worker',
          'systemPrompt': 'do',
        },
        source: ProposalSource.userIntent,
      );
      await boot.queue.approve(aid, originator: const UserOriginator());
    });

    final cats = touches.map((t) => t.category).toSet();
    expect(cats, containsAll(<AssetCategory>[
      AssetCategory.profile,
      AssetCategory.philosophy,
      AssetCategory.agent,
    ]));

    final byCat = {
      for (final t in touches) t.category: t,
    };
    expect(byCat[AssetCategory.profile]?.id, 'p-1');
    expect(byCat[AssetCategory.philosophy]?.id, 'ph-1');
    expect(byCat[AssetCategory.agent]?.id, 'a-1');

    await observer.dispose();
    await boot.project.close();
  });

  test('non-asset pointer is ignored', () async {
    final boot = await _bootstrap('C');
    final observer = AssetTouchObserver(canonical: boot.project.canonical);

    final touches = await _collect(observer, () async {
      final next = boot.project.canonical.bundle.copyWith(
        manifest: boot.project.canonical.bundle.manifest.copyWith(
          name: 'Renamed',
        ),
      );
      await boot.project.canonical.applyAtomicBundle(
        next,
        changedPointers: const ['/manifest/name'],
      );
    });

    expect(touches, isEmpty);
    expect(observer.last, isNull);

    await observer.dispose();
    await boot.project.close();
  });

  test('sequential patches emit one touch per asset pointer', () async {
    final boot = await _bootstrap('D');
    final observer = AssetTouchObserver(canonical: boot.project.canonical);

    final touches = await _collect(observer, () async {
      final sid = boot.queue.pushNew(
        category: AssetCategory.skill,
        newAssetJson: <String, dynamic>{
          'id': 'sk-1',
          'name': 'first',
          'description': 'd',
          'version': '1.0.0',
        },
        source: ProposalSource.userIntent,
      );
      await boot.queue.approve(sid, originator: const UserOriginator());

      final pid = boot.queue.pushNew(
        category: AssetCategory.profile,
        newAssetJson: <String, dynamic>{
          'id': 'p-1',
          'name': 'P',
          'version': '1.0.0',
          'description': 'd',
        },
        source: ProposalSource.userIntent,
      );
      await boot.queue.approve(pid, originator: const UserOriginator());
    });

    final categories = touches.map((t) => t.category).toList();
    expect(categories, containsAllInOrder(<AssetCategory>[
      AssetCategory.skill,
      AssetCategory.profile,
    ]));

    await observer.dispose();
    await boot.project.close();
  });

  test('dispose stops further emissions', () async {
    final boot = await _bootstrap('E');
    final observer = AssetTouchObserver(canonical: boot.project.canonical);
    final captured = <AssetTouch>[];
    final sub = observer.touches.listen(captured.add);

    final id1 = boot.queue.pushNew(
      category: AssetCategory.skill,
      newAssetJson: <String, dynamic>{
        'id': 'sk-1',
        'name': 'first',
        'description': 'd',
        'version': '1.0.0',
      },
      source: ProposalSource.userIntent,
    );
    await boot.queue.approve(id1, originator: const UserOriginator());
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final captureCount = captured.length;
    expect(captureCount, greaterThanOrEqualTo(1));

    await observer.dispose();
    await sub.cancel();

    // Subsequent patch should not produce more events.
    final id2 = boot.queue.pushNew(
      category: AssetCategory.skill,
      newAssetJson: <String, dynamic>{
        'id': 'sk-2',
        'name': 'second',
        'description': 'd',
        'version': '1.0.0',
      },
      source: ProposalSource.userIntent,
    );
    await boot.queue.approve(id2, originator: const UserOriginator());
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(captured.length, captureCount);
    await boot.project.close();
  });
}
