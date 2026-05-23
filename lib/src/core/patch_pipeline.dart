/// Single entry point for canonical mutation (MOD-CORE-003).
///
/// Wraps:
/// 1. dry-run schema + cross-ref validation (fast paths only),
/// 2. JSON patch apply + inverse computation,
/// 3. canonical `applyAtomic` call,
/// 4. undo/redo stack push,
/// 5. broadcast of the resulting `CanonicalChange` for the history log.
library;

import 'package:mcp_bundle/mcp_bundle.dart';

import '_inverse_patch.dart';
import 'asset_validator.dart';
import 'canonical.dart';
import 'undo_redo_stack.dart';

export '_inverse_patch.dart' show JsonPatchSet, PatchOp, PatchApplyException;

/// Typed origin descriptor (DDD-04 §2). Sealed so consumers can switch
/// exhaustively in their UI / audit code.
sealed class PatchOriginator {
  const PatchOriginator();

  /// Audit-friendly JSON form. Always carries `kind` plus the typed
  /// fields of the concrete subclass so [HistoryLog] can persist a
  /// row that survives subsequent reads.
  Map<String, dynamic> toJson();
}

class UserOriginator extends PatchOriginator {
  const UserOriginator({this.note});
  final String? note;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'user',
        if (note != null) 'note': note,
      };
}

class LlmOriginator extends PatchOriginator {
  const LlmOriginator({required this.turnId, this.toolName});
  final String turnId;
  final String? toolName;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'llm',
        'turnId': turnId,
        if (toolName != null) 'toolName': toolName,
      };
}

class McpClientOriginator extends PatchOriginator {
  const McpClientOriginator({required this.clientId, required this.toolName});
  final String clientId;
  final String toolName;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'mcpClient',
        'clientId': clientId,
        'toolName': toolName,
      };
}

class CliOriginator extends PatchOriginator {
  const CliOriginator({required this.subcommand});
  final String subcommand;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'cli',
        'subcommand': subcommand,
      };
}

class ImportOriginator extends PatchOriginator {
  const ImportOriginator({required this.sourcePath});
  final String sourcePath;

  @override
  Map<String, dynamic> toJson() => {
        'kind': 'import',
        'sourcePath': sourcePath,
      };
}

/// Outcome of [PatchPipeline.apply].
sealed class PatchResult {
  const PatchResult();
}

class PatchApplied extends PatchResult {
  const PatchApplied({
    required this.changedPointers,
    required this.beforeHash,
    required this.afterHash,
  });
  final List<String> changedPointers;
  final String beforeHash;
  final String afterHash;
}

class PatchRejected extends PatchResult {
  const PatchRejected({required this.report});
  final ValidationReport report;
}

/// Coordinates patch application against a [Canonical].
class PatchPipeline {
  PatchPipeline({
    required Canonical canonical,
    required AssetValidator validator,
    required UndoRedoStack undoStack,
  })  : _canonical = canonical,
        _validator = validator,
        _undoStack = undoStack;

  final Canonical _canonical;
  final AssetValidator _validator;
  final UndoRedoStack _undoStack;

  /// The session-scoped undo / redo stack this pipeline pushes into.
  /// Exposed so UI hosts can subscribe to [UndoRedoStack.changes] for
  /// canUndo / canRedo button enable state without owning the stack.
  UndoRedoStack get undoStack => _undoStack;

  /// Try to apply [patch]. The pipeline:
  /// 1. simulates the patch on a JSON copy and runs the fast validator
  ///    layers — schema and cross-ref. Errors short-circuit with no
  ///    side-effects.
  /// 2. calculates the inverse from the *before* state.
  /// 3. mutates the canonical via `applyAtomic`.
  /// 4. pushes the (forward, inverse) pair onto the undo stack.
  Future<PatchResult> apply(
    JsonPatchSet patch, {
    required PatchOriginator originator,
  }) async {
    final beforeJson = _deepCloneJson(_canonical.bundleJson);

    final probedJson = _deepCloneJson(beforeJson);
    applyPatch(probedJson, patch);
    final probedBundle = McpBundle.fromJson(probedJson);

    final dry = ValidationReport.merge([
      _validator.validateSchema(probedBundle),
      _validator.validateCrossRef(probedBundle),
    ]);
    if (dry.errors.isNotEmpty) {
      return PatchRejected(report: dry);
    }

    final inverse = computeInverse(beforeJson, patch);

    await _canonical.applyAtomic(
      probedJson,
      changedPointers: patch.changedPointers,
      originator: originator,
    );

    _undoStack.push(
      forward: patch,
      inverse: inverse,
      originator: originator,
    );

    return PatchApplied(
      changedPointers: patch.changedPointers,
      beforeHash: '',
      afterHash: '',
    );
  }

  /// Undo the most recent applied patch. Returns `null` when the stack
  /// is empty. Internally re-uses [apply] semantics so the inverse trip
  /// is itself audited (originator marked as `UserOriginator(note:
  /// 'undo')`).
  Future<PatchResult?> undo() async {
    final entry = _undoStack.popUndo();
    if (entry == null) return null;
    return _replay(entry, const UserOriginator(note: 'undo'));
  }

  /// Redo the most recently undone patch. Returns `null` when the redo
  /// stack is empty.
  Future<PatchResult?> redo() async {
    final entry = _undoStack.popRedo();
    if (entry == null) return null;
    return _replay(entry, const UserOriginator(note: 'redo'));
  }

  Future<PatchResult> _replay(
    UndoRedoEntry entry,
    PatchOriginator originator,
  ) async {
    final beforeJson = _deepCloneJson(_canonical.bundleJson);
    applyPatch(beforeJson, entry.patch);
    await _canonical.applyAtomic(
      beforeJson,
      changedPointers: entry.patch.changedPointers,
      originator: originator,
    );
    return PatchApplied(
      changedPointers: entry.patch.changedPointers,
      beforeHash: '',
      afterHash: '',
    );
  }

  /// Deep-cloned JSON snapshot of the canonical bundle. Helpers that
  /// must inspect current state before emitting init-vs-append patch ops
  /// (e.g. [ReviewerQueue._toPatch]) read from this snapshot rather
  /// than the live canonical, so the canonical's `applyAtomic`
  /// invariants stay intact.
  Map<String, dynamic> snapshotJson() =>
      _deepCloneJson(_canonical.bundleJson);

  Map<String, dynamic> _deepCloneJson(Map<String, dynamic> source) {
    return _cloneValue(source) as Map<String, dynamic>;
  }

  Object? _cloneValue(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key as String: _cloneValue(entry.value),
      };
    }
    if (value is List) {
      return [for (final item in value) _cloneValue(item)];
    }
    return value;
  }
}
