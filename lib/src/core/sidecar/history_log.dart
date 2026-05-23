/// Patch-audit sidecar (`<kbproj>/history.jsonl`).
///
/// Subscribes to a [Canonical]'s change stream and appends one row per
/// `kind: patch` event. Other change kinds (`open` / `saveAs` / `revert`)
/// are not recorded — they carry no diff a downstream auditor could
/// replay (DDD-04 §6).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../canonical.dart';
import '../patch_pipeline.dart';

/// One row read from `history.jsonl`.
class HistoryEntry {
  const HistoryEntry({
    required this.timestamp,
    required this.kind,
    required this.changedPaths,
    required this.beforeHash,
    required this.afterHash,
    this.originator,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      timestamp: DateTime.tryParse(json['ts'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      kind: json['kind'] as String? ?? 'patch',
      changedPaths: (json['changedPaths'] as List?)?.cast<String>() ??
          const [],
      beforeHash: json['beforeHash'] as String? ?? '',
      afterHash: json['afterHash'] as String? ?? '',
      originator: (json['originator'] as Map?)?.cast<String, dynamic>(),
    );
  }

  final DateTime timestamp;
  final String kind;
  final List<String> changedPaths;
  final String beforeHash;
  final String afterHash;
  final Map<String, dynamic>? originator;

  Map<String, dynamic> toJson() => {
        'ts': timestamp.toUtc().toIso8601String(),
        'kind': kind,
        if (changedPaths.isNotEmpty) 'changedPaths': changedPaths,
        if (beforeHash.isNotEmpty) 'beforeHash': beforeHash,
        if (afterHash.isNotEmpty) 'afterHash': afterHash,
        if (originator != null) 'originator': originator,
      };
}

class HistoryLog {
  HistoryLog._(this._path);

  /// Attach to `<projectPath>/history.jsonl`. The caller is responsible
  /// for invoking [subscribe] with the live canonical.
  static HistoryLog attach(String projectPath) {
    return HistoryLog._(p.join(projectPath, 'history.jsonl'));
  }

  final String _path;
  StreamSubscription<CanonicalChange>? _sub;

  /// Path to the underlying file (absolute).
  String get path => _path;

  /// Begin recording `kind: patch` events from [canonical].
  void subscribe(Canonical canonical) {
    _sub?.cancel();
    _sub = canonical.changes.listen((change) {
      if (change.kind != CanonicalChangeKind.patch) return;
      _append(_changeToEntry(change));
    });
  }

  /// Stop recording. Outstanding events that already crossed the stream
  /// boundary are still flushed by `_append` itself — IO is swallowed on
  /// failure.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Read every row. Corrupt lines are skipped.
  Future<List<HistoryEntry>> readAll() async {
    final file = File(_path);
    if (!await file.exists()) return const [];
    final raw = await file.readAsString();
    final out = <HistoryEntry>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          out.add(HistoryEntry.fromJson(decoded));
        }
      } catch (_) {
        // Skip — corrupt line.
      }
    }
    return out;
  }

  /// Manually append an entry — used by `commitAs` / `import` flows where
  /// the change does not pass through the canonical's normal patch
  /// stream but should still appear in the audit trail.
  Future<void> append(HistoryEntry entry) => _append(entry);

  /// Truncate the audit file (developer / debugging only — production
  /// users should preserve the trail).
  Future<void> clear() async {
    final file = File(_path);
    if (await file.exists()) {
      await file.writeAsString('', flush: true);
    }
  }

  /// Copy the audit file when a project is duplicated (`saveAs`).
  Future<void> copyTo(String destProjectPath) async {
    final src = File(_path);
    if (!await src.exists()) return;
    final destFile = File(p.join(destProjectPath, 'history.jsonl'));
    await destFile.parent.create(recursive: true);
    await src.copy(destFile.path);
  }

  HistoryEntry _changeToEntry(CanonicalChange change) {
    Map<String, dynamic>? originatorJson;
    final originator = change.originator;
    if (originator is PatchOriginator) {
      originatorJson = originator.toJson();
    } else if (originator is Map<String, dynamic>) {
      originatorJson = originator;
    }
    return HistoryEntry(
      timestamp: change.timestamp,
      kind: change.kind.name,
      changedPaths: change.changedPointers,
      beforeHash: change.beforeHash,
      afterHash: change.afterHash,
      originator: originatorJson,
    );
  }

  Future<void> _append(HistoryEntry entry) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Non-fatal — NFR-PERSIST-003.
    }
  }
}
