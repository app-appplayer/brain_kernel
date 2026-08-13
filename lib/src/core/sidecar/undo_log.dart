/// Undo / redo persistence sidecar (`<projectPath>/undo.json`).
///
/// Pairs with [UndoRedoStack] so that the in-memory undo / redo line
/// survives a host crash. The kernel persists the *patch frames* (forward +
/// inverse + originator) — applying them is still the host's responsibility
/// when it rehydrates the stack. The file is written atomically (temp +
/// rename) so a partial write cannot corrupt the prior snapshot.
///
/// Audit-log sibling (`history.jsonl`) keeps the chronological diff trail.
/// `undo.json` only needs to know "what's currently undoable / redoable" —
/// it overwrites on every save, never appends.
library;

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'store/resolve_sidecar_store.dart';
import 'store/sidecar_store.dart';

import '../_inverse_patch.dart';
import '../undo_redo_stack.dart';

/// Persisted shape of one [_PatchFrame]. Public because the snapshot
/// crosses the sidecar boundary.
class UndoFrameSnapshot {
  const UndoFrameSnapshot({
    required this.forward,
    required this.inverse,
    required this.timestamp,
    this.originator,
  });

  factory UndoFrameSnapshot.fromJson(Map<String, dynamic> json) {
    final forwardOps = (json['forward'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PatchOp.fromJson)
        .toList(growable: false);
    final inverseOps = (json['inverse'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PatchOp.fromJson)
        .toList(growable: false);
    return UndoFrameSnapshot(
      forward: JsonPatchSet(forwardOps),
      inverse: JsonPatchSet(inverseOps),
      timestamp: DateTime.tryParse(json['ts'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      originator: (json['originator'] as Map?)?.cast<String, dynamic>(),
    );
  }

  final JsonPatchSet forward;
  final JsonPatchSet inverse;
  final DateTime timestamp;
  final Map<String, dynamic>? originator;

  Map<String, dynamic> toJson() => {
        'forward': [for (final op in forward.ops) op.toJson()],
        'inverse': [for (final op in inverse.ops) op.toJson()],
        'ts': timestamp.toUtc().toIso8601String(),
        if (originator != null) 'originator': originator,
      };
}

/// Snapshot of the entire stack — undo + redo halves, in their natural
/// stack order (top-of-stack last).
class UndoSnapshot {
  const UndoSnapshot({
    required this.undoFrames,
    required this.redoFrames,
  });

  factory UndoSnapshot.fromJson(Map<String, dynamic> json) => UndoSnapshot(
        undoFrames: (json['undo'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(UndoFrameSnapshot.fromJson)
            .toList(growable: false),
        redoFrames: (json['redo'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(UndoFrameSnapshot.fromJson)
            .toList(growable: false),
      );

  static const empty = UndoSnapshot(undoFrames: [], redoFrames: []);

  final List<UndoFrameSnapshot> undoFrames;
  final List<UndoFrameSnapshot> redoFrames;

  bool get isEmpty => undoFrames.isEmpty && redoFrames.isEmpty;

  Map<String, dynamic> toJson() => {
        'undo': [for (final f in undoFrames) f.toJson()],
        'redo': [for (final f in redoFrames) f.toJson()],
      };
}

class UndoLog {
  UndoLog._(this._path, this._store);

  /// Bind to `<projectPath>/undo.json`. Does not read anything — call
  /// [read] when rehydrating.
  static UndoLog attach(String projectPath, {SidecarStore? store}) {
    return UndoLog._(p.join(projectPath, 'undo.json'),
        resolveSidecarStore(store, 'UndoLog.attach'));
  }

  final String _path;
  final SidecarStore _store;

  /// Path to the underlying file (absolute).
  String get path => _path;

  /// Serialize [snapshot] to the underlying record. The store writes
  /// atomically where it can, so a crash mid-write cannot corrupt the prior
  /// snapshot. Failures are swallowed (NFR-PERSIST-003).
  Future<void> save(UndoSnapshot snapshot) async {
    try {
      await _store.write(_path, jsonEncode(snapshot.toJson()));
    } catch (_) {
      // Non-fatal — kernel keeps running on its in-memory stack.
    }
  }

  /// Read the stored snapshot. Returns `null` when it is missing or corrupt
  /// — host treats that as "no recovery available" and starts from an empty
  /// stack.
  Future<UndoSnapshot?> read() async {
    try {
      final raw = await _store.read(_path);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return UndoSnapshot.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Remove the snapshot. Used when the host clears the stack or wants a
  /// clean start.
  Future<void> clear() async {
    try {
      await _store.remove(_path);
    } catch (_) {
      // Non-fatal.
    }
  }

  /// Copy the snapshot to the destination project (`saveAs` flow).
  Future<void> copyTo(String destProjectPath) async {
    try {
      await _store.copy(_path, p.join(destProjectPath, 'undo.json'));
    } catch (_) {
      // Non-fatal.
    }
  }
}

/// Convenience binding: every change emitted by [stack] flushes a fresh
/// snapshot to [log]. Returns the subscription so the host can cancel it
/// at dispose time. Reads the in-memory frames each time (cheap — pointer
/// lists), so the disk file always matches the live stack within one
/// stream tick.
StreamSubscription<UndoState> bindUndoLog(
  UndoRedoStack stack,
  UndoLog log,
) {
  return stack.changes.listen((_) {
    final snapshot = UndoSnapshot(
      undoFrames: [
        for (final f in stack.undoFrames)
          UndoFrameSnapshot(
            forward: f.forward,
            inverse: f.inverse,
            timestamp: DateTime.now().toUtc(),
            originator: _originatorJson(f.originator),
          ),
      ],
      redoFrames: [
        for (final f in stack.redoFrames)
          UndoFrameSnapshot(
            forward: f.forward,
            inverse: f.inverse,
            timestamp: DateTime.now().toUtc(),
            originator: _originatorJson(f.originator),
          ),
      ],
    );
    log.save(snapshot);
  });
}

Map<String, dynamic>? _originatorJson(Object? originator) {
  if (originator == null) return null;
  if (originator is Map<String, dynamic>) return originator;
  try {
    final dyn = originator as dynamic;
    final json = dyn.toJson();
    if (json is Map<String, dynamic>) return json;
  } catch (_) {
    // Originator does not expose toJson — drop.
  }
  return null;
}
