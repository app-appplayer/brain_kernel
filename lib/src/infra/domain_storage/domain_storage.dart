/// Namespace-scoped key-value storage for domain bundles. Each domain
/// (identified by its `manifest.id`) gets an isolated state area
/// inside the host's knowledge folder; domains store arbitrary
/// JSON-shaped state (recents, pins, preferences, derived caches,
/// progressive learnings) and never see each other's data.
///
/// The interface is intentionally small — put / get / list / delete /
/// clearNamespace. Adapters can back this with a JSON file, SQLite,
/// the fact graph, or any other store; the canonical first-cut is
/// [JsonFileDomainStorage] which writes one JSON document per
/// namespace under `<rootDir>/<namespace>/state.json`.
///
/// Why "domain storage" not "key-value cache"?
/// Memory `feedback_knowledge_definition` formalises that a user's
/// "knowledge" spans facts / skills / profile / philosophy /
/// workflow / agents. Per-domain state (what the bundle remembers
/// between activations) is the bundle's slice of that knowledge —
/// the host stores it in the same physical area so a single
/// configRoot move / backup carries every domain's accumulated
/// context.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One stored value inside a namespace — opaque JSON-shaped payload.
typedef DomainValue = Object?;

/// Result of a [DomainStorage.list] call.
class DomainEntry {
  const DomainEntry({required this.key, required this.value});
  final String key;
  final DomainValue value;
}

/// Abstract surface — adapters back this with disk / db / graph.
abstract class DomainStorage {
  /// Write or overwrite the value at [key] inside [namespace].
  Future<void> put(String namespace, String key, DomainValue value);

  /// Read the value at [key]; returns null when absent.
  Future<DomainValue> get(String namespace, String key);

  /// List entries whose key starts with [prefix] (empty = all). Order
  /// is implementation-defined; callers that need a stable order
  /// should sort by key.
  Future<List<DomainEntry>> list(String namespace, {String prefix = ''});

  /// Delete the entry at [key]. Returns true when an entry existed,
  /// false otherwise.
  Future<bool> delete(String namespace, String key);

  /// Drop every key inside [namespace]. Used by uninstall to reclaim
  /// space and prevent the next install from seeing stale state.
  Future<void> clearNamespace(String namespace);
}

/// JSON-file backed adapter. Each namespace owns one document at
/// `<rootDir>/<sanitisedNamespace>/state.json` — a flat
/// `{ key: value }` map. The file is rewritten atomically (via
/// `<file>.tmp` rename) on each [put] / [delete] so a crashed write
/// can't leave the JSON half-formed.
///
/// Concurrency: per-namespace [Future] serialisation guarantees
/// in-process write ordering. Cross-process concurrency (multiple
/// vibe_studio instances against the same config root) is out of
/// scope for first-cut — hosts that need it should upgrade to a
/// db-backed adapter.
class JsonFileDomainStorage implements DomainStorage {
  JsonFileDomainStorage({required this.rootDir});

  /// Directory under which each namespace gets a sub-folder. The host
  /// typically passes `<configRoot>/domains` so domain state lives
  /// alongside (but isolated from) the host's other knowledge files.
  final String rootDir;

  /// Per-namespace tail of pending writes so concurrent put / delete
  /// against the same namespace serialise — prevents the
  /// read-modify-write race where two callers both stale-read the
  /// JSON before one writes.
  final Map<String, Future<void>> _serialise = <String, Future<void>>{};

  /// Reads-only memo of the parsed map per namespace. Invalidated on
  /// any write to that namespace.
  final Map<String, Map<String, dynamic>> _cache =
      <String, Map<String, dynamic>>{};

  @override
  Future<void> put(String namespace, String key, DomainValue value) {
    return _withLock(namespace, () async {
      final map = await _loadLocked(namespace);
      map[key] = value;
      await _writeLocked(namespace, map);
    });
  }

  @override
  Future<DomainValue> get(String namespace, String key) async {
    final map = await _load(namespace);
    return map[key];
  }

  @override
  Future<List<DomainEntry>> list(
    String namespace, {
    String prefix = '',
  }) async {
    final map = await _load(namespace);
    final out = <DomainEntry>[];
    for (final entry in map.entries) {
      if (prefix.isEmpty || entry.key.startsWith(prefix)) {
        out.add(DomainEntry(key: entry.key, value: entry.value));
      }
    }
    return out;
  }

  @override
  Future<bool> delete(String namespace, String key) {
    return _withLock(namespace, () async {
      final map = await _loadLocked(namespace);
      if (!map.containsKey(key)) return false;
      map.remove(key);
      await _writeLocked(namespace, map);
      return true;
    });
  }

  @override
  Future<void> clearNamespace(String namespace) {
    return _withLock(namespace, () async {
      _cache.remove(namespace);
      final dir = Directory(_namespacePath(namespace));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });
  }

  // ----- internals ---------------------------------------------------

  Future<T> _withLock<T>(String namespace, Future<T> Function() body) async {
    final prev = _serialise[namespace] ?? Future<void>.value();
    final completer = Completer<T>();
    // Chain the body off the previous lock holder; the new tail
    // resolves only after this body returns, so the next put/delete
    // sees the up-to-date file.
    final next = prev.then((_) async {
      try {
        final r = await body();
        completer.complete(r);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _serialise[namespace] = next;
    return completer.future;
  }

  Future<Map<String, dynamic>> _load(String namespace) async {
    final cached = _cache[namespace];
    if (cached != null) return Map<String, dynamic>.from(cached);
    return _loadLocked(namespace);
  }

  Future<Map<String, dynamic>> _loadLocked(String namespace) async {
    final file = File(_statePath(namespace));
    if (!await file.exists()) {
      _cache[namespace] = <String, dynamic>{};
      return _cache[namespace]!;
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _cache[namespace] = <String, dynamic>{};
        return _cache[namespace]!;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        _cache[namespace] = <String, dynamic>{};
        return _cache[namespace]!;
      }
      _cache[namespace] = decoded;
      return decoded;
    } catch (_) {
      _cache[namespace] = <String, dynamic>{};
      return _cache[namespace]!;
    }
  }

  Future<void> _writeLocked(
    String namespace,
    Map<String, dynamic> map,
  ) async {
    final filePath = _statePath(namespace);
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final tmp = File('$filePath.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(map),
      flush: true,
    );
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(filePath);
    _cache[namespace] = Map<String, dynamic>.from(map);
  }

  /// Path to the namespace folder. Reverse-DNS dots stay verbatim
  /// (they're filesystem-legal on every supported OS); other unsafe
  /// chars get squashed to `_`. Empty namespace falls back to
  /// `_default` so callers don't accidentally write outside [rootDir].
  String _namespacePath(String namespace) {
    final sanitised = namespace.isEmpty
        ? '_default'
        : namespace.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    return p.join(rootDir, sanitised);
  }

  String _statePath(String namespace) {
    return p.join(_namespacePath(namespace), 'state.json');
  }
}
