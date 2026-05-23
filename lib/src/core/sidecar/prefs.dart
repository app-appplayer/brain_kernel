/// Per-project UI preferences sidecar (`<kbproj>/prefs.json`).
///
/// Persists ShellLayout state (focused asset category, selected asset id,
/// chat visibility, preview snapshot, last query). Missing or corrupt
/// `prefs.json` falls back to defaults — never fatal (NFR-PERSIST-003).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../types.dart';

/// Immutable snapshot a host can read/replace as a unit.
class PrefsSnapshot {
  const PrefsSnapshot({
    this.focusedCategory,
    this.selectedAssetId,
    this.chatVisible = true,
    this.previewState = const {},
    this.lastQuery,
  });

  factory PrefsSnapshot.fromJson(Map<String, dynamic> json) {
    final cat = json['focusedCategory'] as String?;
    AssetCategory? resolvedCat;
    if (cat != null) {
      resolvedCat = AssetCategory.values
          .where((c) => c.name == cat)
          .cast<AssetCategory?>()
          .firstWhere((c) => c != null, orElse: () => null);
    }
    return PrefsSnapshot(
      focusedCategory: resolvedCat,
      selectedAssetId: json['selectedAssetId'] as String?,
      chatVisible: json['chatVisible'] as bool? ?? true,
      previewState: (json['previewState'] as Map?)?.cast<String, dynamic>() ??
          const {},
      lastQuery: json['lastQuery'] as String?,
    );
  }

  final AssetCategory? focusedCategory;
  final String? selectedAssetId;
  final bool chatVisible;
  final Map<String, dynamic> previewState;
  final String? lastQuery;

  Map<String, dynamic> toJson() => {
        if (focusedCategory != null)
          'focusedCategory': focusedCategory!.name,
        if (selectedAssetId != null) 'selectedAssetId': selectedAssetId,
        'chatVisible': chatVisible,
        if (previewState.isNotEmpty) 'previewState': previewState,
        if (lastQuery != null) 'lastQuery': lastQuery,
      };

  PrefsSnapshot copyWith({
    AssetCategory? focusedCategory,
    String? selectedAssetId,
    bool? chatVisible,
    Map<String, dynamic>? previewState,
    String? lastQuery,
  }) {
    return PrefsSnapshot(
      focusedCategory: focusedCategory ?? this.focusedCategory,
      selectedAssetId: selectedAssetId ?? this.selectedAssetId,
      chatVisible: chatVisible ?? this.chatVisible,
      previewState: previewState ?? this.previewState,
      lastQuery: lastQuery ?? this.lastQuery,
    );
  }
}

/// File-backed preferences. Atomic write (temp + rename) so a crash
/// mid-flush cannot corrupt the live file (NFR-PERSIST-001).
class Prefs {
  Prefs._({required String path, required PrefsSnapshot snapshot})
      : _path = path,
        _snapshot = snapshot;

  /// Load existing prefs or return defaults. Never throws on parse error
  /// — corrupt JSON is logged via [warnings] and replaced with defaults.
  static Future<Prefs> load(String projectPath) async {
    final path = p.join(projectPath, 'prefs.json');
    final file = File(path);
    if (!await file.exists()) {
      return Prefs._(
          path: path, snapshot: const PrefsSnapshot());
    }
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return Prefs._(
          path: path,
          snapshot: PrefsSnapshot.fromJson(decoded),
        );
      }
    } catch (_) {
      // Fall through to defaults — UX over correctness.
    }
    return Prefs._(path: path, snapshot: const PrefsSnapshot());
  }

  final String _path;
  PrefsSnapshot _snapshot;

  PrefsSnapshot get snapshot => _snapshot;

  /// Replace the in-memory snapshot. Does not persist — call [save].
  void update(PrefsSnapshot next) {
    _snapshot = next;
  }

  /// Persist the current snapshot atomically. Swallows IO errors so the
  /// UI tick never blocks on prefs (NFR-PERSIST-003).
  Future<void> save() async {
    try {
      final tmp = File('$_path.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_snapshot.toJson()),
        flush: true,
      );
      await tmp.rename(_path);
    } catch (_) {
      // Non-fatal — see NFR-PERSIST-003.
    }
  }

  /// Copy the prefs file from this project to [destProjectPath]. Used by
  /// `Project.saveAs` so the new project starts with the same UI state.
  Future<void> copyTo(String destProjectPath) async {
    final src = File(_path);
    if (!await src.exists()) return;
    final destFile = File(p.join(destProjectPath, 'prefs.json'));
    await destFile.parent.create(recursive: true);
    await src.copy(destFile.path);
  }
}
