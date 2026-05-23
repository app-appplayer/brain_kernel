/// MOD-INFRA-011 — KnowledgeBundleRegistry.
///
/// Persistent list of installed knowledge bundle paths, kept independent
/// of FlowBrain's runtime layer so the retrieval surface
/// (`vibe_knowledge_query`) works zero-key, zero-LLM. Each entry is the
/// absolute path of a `.mbd/` plus the namespace it was installed under
/// and an installation timestamp. Re-installing the same path updates
/// the timestamp + namespace; nothing is removed unless the caller
/// asks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class KnowledgeBundleEntry {
  const KnowledgeBundleEntry({
    required this.mbdPath,
    required this.namespace,
    required this.installedAt,
  });

  /// Absolute path to the `.mbd/` directory.
  final String mbdPath;

  /// Namespace label — typically the directory basename. Surfaced to
  /// retrieval callers so they can scope queries with `namespace`.
  final String namespace;

  /// UTC ISO-8601 string. Plain string instead of `DateTime` so the
  /// JSON snapshot round-trips losslessly without timezone drift.
  final String installedAt;

  factory KnowledgeBundleEntry.fromJson(Map<String, dynamic> json) {
    return KnowledgeBundleEntry(
      mbdPath: json['mbdPath'] as String,
      namespace: json['namespace'] as String,
      installedAt: json['installedAt'] as String,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mbdPath': mbdPath,
        'namespace': namespace,
        'installedAt': installedAt,
      };
}

class KnowledgeBundleRegistry {
  KnowledgeBundleRegistry({required this.storageDir});

  /// Directory the registry's snapshot file lives in. Typically
  /// `~/.config/app_builder/`. The file inside is
  /// [storageFile].
  final String storageDir;

  /// Snapshot filename. Kept stable so renaming requires migration.
  static const String storageFile = 'knowledge_bundles.json';

  String get _filePath => p.join(storageDir, storageFile);

  List<KnowledgeBundleEntry> _entries = const <KnowledgeBundleEntry>[];
  bool _loaded = false;

  Future<void> load() async {
    final file = File(_filePath);
    if (!await file.exists()) {
      _entries = const <KnowledgeBundleEntry>[];
      _loaded = true;
      return;
    }
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as List<dynamic>;
      _entries = decoded
          .map((e) =>
              KnowledgeBundleEntry.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
    } catch (_) {
      // Corrupt snapshot — start fresh. The registry is best-effort
      // bookkeeping; a parse failure should not block install / query.
      _entries = const <KnowledgeBundleEntry>[];
    }
    _loaded = true;
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<List<KnowledgeBundleEntry>> list() async {
    await _ensureLoaded();
    return List<KnowledgeBundleEntry>.unmodifiable(_entries);
  }

  /// Add or update an entry. Existing entries with the same [mbdPath]
  /// are replaced (timestamp + namespace updated).
  Future<KnowledgeBundleEntry> upsert({
    required String mbdPath,
    required String namespace,
  }) async {
    await _ensureLoaded();
    final entry = KnowledgeBundleEntry(
      mbdPath: mbdPath,
      namespace: namespace,
      installedAt: DateTime.now().toUtc().toIso8601String(),
    );
    final next = <KnowledgeBundleEntry>[
      for (final e in _entries)
        if (e.mbdPath != mbdPath) e,
      entry,
    ];
    _entries = next;
    await _persist();
    return entry;
  }

  /// Remove an entry by path. No-op when missing. Returns true when
  /// something was actually removed.
  Future<bool> remove(String mbdPath) async {
    await _ensureLoaded();
    final before = _entries.length;
    _entries = _entries.where((e) => e.mbdPath != mbdPath).toList();
    if (_entries.length == before) return false;
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
