/// In-memory inverse-patch undo / redo stack (MOD-CORE-004).
///
/// Pairs a forward [JsonPatchSet] with its computed inverse so the
/// pipeline can replay either direction. Session-scoped — discarded on
/// dispose; the on-disk audit log (`history.jsonl`) keeps the durable
/// trail.
library;

import 'dart:async';

import '_inverse_patch.dart';

/// Snapshot of the stack — emitted on every push / undo / redo / clear
/// so UI buttons stay in sync.
class UndoState {
  const UndoState({
    required this.canUndo,
    required this.canRedo,
    required this.stackDepth,
    required this.redoDepth,
  });

  final bool canUndo;
  final bool canRedo;
  final int stackDepth;
  final int redoDepth;
}

/// One frame in either stack — the forward patch and the inverse used to
/// undo it (DDD-04 §3).
class _PatchFrame {
  _PatchFrame({
    required this.forward,
    required this.inverse,
    required this.originator,
  });

  final JsonPatchSet forward;
  final JsonPatchSet inverse;
  final Object? originator;
}

/// Bounded LIFO of patch frames.
class UndoRedoStack {
  UndoRedoStack({this.maxDepth = 200});

  final int maxDepth;
  final List<_PatchFrame> _undo = <_PatchFrame>[];
  final List<_PatchFrame> _redo = <_PatchFrame>[];
  final StreamController<UndoState> _controller =
      StreamController<UndoState>.broadcast();
  bool _disposed = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  int get stackDepth => _undo.length;
  int get redoDepth => _redo.length;
  Stream<UndoState> get changes => _controller.stream;

  /// Snapshot of the undo half (oldest first, top-of-stack last). Used by
  /// [UndoLog] to persist the stack for crash recovery.
  List<UndoFrame> get undoFrames => List.unmodifiable(
        _undo.map((f) => UndoFrame._(f.forward, f.inverse, f.originator)),
      );

  /// Snapshot of the redo half (oldest first, top-of-stack last).
  List<UndoFrame> get redoFrames => List.unmodifiable(
        _redo.map((f) => UndoFrame._(f.forward, f.inverse, f.originator)),
      );

  /// Replace the current undo / redo halves with the supplied frames —
  /// used by host code rehydrating from an `UndoLog` snapshot. The
  /// argument lists follow the same order as [undoFrames] / [redoFrames]
  /// (top-of-stack last).
  void seedFrames({
    List<UndoFrame> undoFrames = const [],
    List<UndoFrame> redoFrames = const [],
  }) {
    _ensureLive();
    _undo
      ..clear()
      ..addAll([
        for (final f in undoFrames)
          _PatchFrame(
            forward: f.forward,
            inverse: f.inverse,
            originator: f.originator,
          ),
      ]);
    _redo
      ..clear()
      ..addAll([
        for (final f in redoFrames)
          _PatchFrame(
            forward: f.forward,
            inverse: f.inverse,
            originator: f.originator,
          ),
      ]);
    _emit();
  }

  /// Record a successful patch. Clears the redo stack — pushing a new
  /// branch invalidates the previous redo line.
  void push({
    required JsonPatchSet forward,
    required JsonPatchSet inverse,
    Object? originator,
  }) {
    _ensureLive();
    _undo.add(_PatchFrame(
      forward: forward,
      inverse: inverse,
      originator: originator,
    ));
    if (_undo.length > maxDepth) _undo.removeAt(0);
    _redo.clear();
    _emit();
  }

  /// Pop the top forward frame; returns its inverse so the caller (the
  /// pipeline) can apply it to the canonical. Returns null when empty.
  _UndoRedoEntry? popUndo() {
    _ensureLive();
    if (_undo.isEmpty) return null;
    final frame = _undo.removeLast();
    _redo.add(frame);
    _emit();
    return _UndoRedoEntry(
      patch: frame.inverse,
      reverse: frame.forward,
      originator: frame.originator,
    );
  }

  /// Pop the top redo frame; returns its forward patch so the caller can
  /// re-apply it.
  _UndoRedoEntry? popRedo() {
    _ensureLive();
    if (_redo.isEmpty) return null;
    final frame = _redo.removeLast();
    _undo.add(frame);
    _emit();
    return _UndoRedoEntry(
      patch: frame.forward,
      reverse: frame.inverse,
      originator: frame.originator,
    );
  }

  void clear() {
    _ensureLive();
    _undo.clear();
    _redo.clear();
    _emit();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }

  void _emit() {
    _controller.add(UndoState(
      canUndo: canUndo,
      canRedo: canRedo,
      stackDepth: stackDepth,
      redoDepth: redoDepth,
    ));
  }

  void _ensureLive() {
    if (_disposed) throw StateError('UndoRedoStack has been disposed');
  }
}

/// Returned by [UndoRedoStack.popUndo] / [popRedo] — the patch to apply
/// plus the patch the caller would push back to reverse this step.
class _UndoRedoEntry {
  _UndoRedoEntry({
    required this.patch,
    required this.reverse,
    required this.originator,
  });

  final JsonPatchSet patch;
  final JsonPatchSet reverse;
  final Object? originator;
}

/// Public alias so external callers can reference the entry type without
/// crossing the underscore boundary.
typedef UndoRedoEntry = _UndoRedoEntry;

/// Public, serializable snapshot of one stack frame. Used by sidecar
/// persistence (`UndoLog`) and by hosts rehydrating from disk.
class UndoFrame {
  const UndoFrame._(this.forward, this.inverse, this.originator);

  /// Construct an [UndoFrame] from raw fields (e.g. when rehydrating
  /// from an `UndoLog` JSON snapshot).
  const UndoFrame({
    required this.forward,
    required this.inverse,
    this.originator,
  });

  final JsonPatchSet forward;
  final JsonPatchSet inverse;
  final Object? originator;
}
