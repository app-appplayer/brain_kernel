import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

JsonPatchSet _patch(String path, Object? value) =>
    JsonPatchSet([PatchOp(op: 'replace', path: path, value: value)]);

UndoFrameSnapshot _snap(String path, Object? before, Object? after,
    {String? note}) {
  return UndoFrameSnapshot(
    forward: _patch(path, after),
    inverse: _patch(path, before),
    timestamp: DateTime.utc(2026, 5, 6, 12),
    originator: note == null ? null : <String, dynamic>{'note': note},
  );
}

Future<Directory> _tmp() => Directory.systemTemp.createTemp('undo_log_');

void main() {
  group('UndoLog', () {
    test('save then read round-trips a snapshot', () async {
      final dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));

      final log = UndoLog.attach(dir.path);
      final snap = UndoSnapshot(
        undoFrames: [
          _snap('/a', 1, 2, note: 'r1'),
          _snap('/b', null, 'x', note: 'r2'),
        ],
        redoFrames: [
          _snap('/c', 3, 4),
        ],
      );
      await log.save(snap);

      final read = await log.read();
      expect(read, isNotNull);
      expect(read!.undoFrames, hasLength(2));
      expect(read.redoFrames, hasLength(1));
      expect(read.undoFrames.first.forward.ops.first.path, '/a');
      expect(read.undoFrames.first.inverse.ops.first.value, 1);
      expect(read.undoFrames[1].originator?['note'], 'r2');
    });

    test('read returns null when file is missing', () async {
      final dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final log = UndoLog.attach(dir.path);
      expect(await log.read(), isNull);
    });

    test('read returns null when file is corrupt', () async {
      final dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final log = UndoLog.attach(dir.path);
      await File(p.join(dir.path, 'undo.json')).writeAsString('garbage{');
      expect(await log.read(), isNull);
    });

    test('clear removes the file', () async {
      final dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final log = UndoLog.attach(dir.path);
      await log.save(UndoSnapshot.empty);
      expect(await File(log.path).exists(), isTrue);
      await log.clear();
      expect(await File(log.path).exists(), isFalse);
    });

    test('save uses an atomic temp+rename (no .tmp leftover)', () async {
      final dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final log = UndoLog.attach(dir.path);
      await log.save(UndoSnapshot(
        undoFrames: [_snap('/a', 1, 2)],
        redoFrames: const [],
      ));
      expect(await File(log.path).exists(), isTrue);
      expect(await File('${log.path}.tmp').exists(), isFalse);
    });

    test('copyTo duplicates the snapshot to destination project', () async {
      final src = await _tmp();
      final dst = await _tmp();
      addTearDown(() => src.delete(recursive: true));
      addTearDown(() => dst.delete(recursive: true));

      final srcLog = UndoLog.attach(src.path);
      await srcLog.save(UndoSnapshot(
        undoFrames: [_snap('/a', 1, 2)],
        redoFrames: const [],
      ));
      await srcLog.copyTo(dst.path);

      final dstLog = UndoLog.attach(dst.path);
      final read = await dstLog.read();
      expect(read, isNotNull);
      expect(read!.undoFrames, hasLength(1));
    });
  });

  group('UndoRedoStack <-> UndoLog binding', () {
    test('seedFrames restores a stack from snapshot', () {
      final stack = UndoRedoStack();
      stack.seedFrames(
        undoFrames: [
          UndoFrame(forward: _patch('/a', 2), inverse: _patch('/a', 1)),
        ],
        redoFrames: [
          UndoFrame(forward: _patch('/b', 'x'), inverse: _patch('/b', null)),
        ],
      );
      expect(stack.canUndo, isTrue);
      expect(stack.canRedo, isTrue);
      expect(stack.stackDepth, 1);
      expect(stack.redoDepth, 1);
    });

    test('bindUndoLog flushes after every push / undo', () async {
      final dir = await _tmp();
      addTearDown(() => dir.delete(recursive: true));
      final log = UndoLog.attach(dir.path);
      final stack = UndoRedoStack();
      final sub = bindUndoLog(stack, log);

      stack.push(forward: _patch('/a', 2), inverse: _patch('/a', 1));
      stack.push(forward: _patch('/b', 4), inverse: _patch('/b', 3));
      // Allow the broadcast tick to drain to the log.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      var snap = await log.read();
      expect(snap, isNotNull);
      expect(snap!.undoFrames, hasLength(2));
      expect(snap.redoFrames, isEmpty);

      stack.popUndo();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      snap = await log.read();
      expect(snap!.undoFrames, hasLength(1));
      expect(snap.redoFrames, hasLength(1));

      await sub.cancel();
      await stack.dispose();
    });
  });
}
