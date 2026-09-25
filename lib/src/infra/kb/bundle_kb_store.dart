/// A bundle's `host.kb` state — the one implementation every host runs.
///
/// A bundle runs on more than one host (the marketplace cloud runner,
/// AppPlayer, Studio) and on more than one device. Hosts that each carried
/// their own copy of this logic drifted: a fix landed in one and not the
/// other. So the contract lives here and a host's `kb` atom only forwards
/// arguments to [BundleKbStore].
///
/// The contract:
///
///   * `get(key)` → value | `null`
///   * `list(prefix)` → `[{key, value}]`, ascending by key; `prefix` is a
///     string prefix, not a path segment
///   * `put(key, value, force?)` → `{ok: true}` or
///     `{ok: false, conflict: {value}}`
///   * `delete(key, force?)` → `{removed: bool}` or
///     `{ok: false, conflict: {value}}`
///   * `conflicts()` → `[{key, mine, theirs}]`
///   * `query(text, …)` → hits, or [KbError.queryUnavailable]
///
/// **Each key is its own versioned record.** A write is made on the version
/// this store last saw for that key. When the stored record moved since, the
/// write does not happen and the current value comes back: the bundle knows
/// what its value means and merges; the host never picks a side. `force`
/// overwrites deliberately. A record store with no other writer (a device's
/// own file store) never reports a conflict for a key this store has not yet
/// seen, because the only earlier writer was this device.
///
/// **State is keyed by app identity, not by what the bundle calls itself.**
/// [appId] is `listing:<listingId>` for an app acquired through the
/// marketplace and `bundle:<manifest.id>` otherwise — a manifest id is chosen
/// by its author, so two publishers can pick the same one.
library;

import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../domain_storage/domain_storage.dart';
import '../knowledge/query_engine.dart';

/// A refused `kb` call. A conflict is not one of these — it is a result.
class KbError implements Exception {
  const KbError(this.code, this.message);

  static const String invalidKey = 'KB_INVALID_KEY';
  static const String invalidValue = 'KB_INVALID_VALUE';
  static const String quotaExceeded = 'KB_QUOTA_EXCEEDED';
  static const String valueTooLarge = 'KB_VALUE_TOO_LARGE';
  static const String queryUnavailable = 'KB_QUERY_UNAVAILABLE';

  /// No store will take this app's state — the account refused it and there
  /// is no device copy to fall back on (bundle spec 04_Tools §4.8.1).
  static const String unavailable = 'KB_UNAVAILABLE';

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// One stored value and the version it was stored at.
class KbRecord {
  const KbRecord({
    required this.key,
    required this.value,
    required this.version,
  });

  final String key;
  final Object? value;
  final String version;
}

/// What a writer knows about a key before writing it.
sealed class KbExpectation {
  const KbExpectation();

  /// This writer has neither read nor written the key.
  static const KbExpectation unknown = _Unknown();

  /// This writer last saw the key absent.
  static const KbExpectation absent = _Absent();

  /// This writer last saw the key at [version].
  const factory KbExpectation.at(String version) = KbExpectedVersion;
}

final class _Unknown extends KbExpectation {
  const _Unknown();
}

final class _Absent extends KbExpectation {
  const _Absent();
}

final class KbExpectedVersion extends KbExpectation {
  const KbExpectedVersion(this.version);
  final String version;
}

/// Outcome of a conditional write.
sealed class KbWriteOutcome {
  const KbWriteOutcome();
}

/// The write happened. [version] is the new version (null after a delete);
/// [existed] says whether a value was there before.
final class KbWritten extends KbWriteOutcome {
  const KbWritten({required this.version, required this.existed});
  final String? version;
  final bool existed;
}

/// The write did not happen: the record moved. [current] is what is stored
/// now, null when the key is absent.
final class KbConflict extends KbWriteOutcome {
  const KbConflict(this.current);
  final KbRecord? current;
}

/// A write made while the store could not reach its authority, rejected when
/// it could.
class KbPendingConflict {
  const KbPendingConflict({
    required this.key,
    required this.mine,
    required this.theirs,
  });

  final String key;
  final Object? mine;
  final Object? theirs;
}

/// Where `kb` records live. The device's file store implements it over the
/// kernel [mb.KvStoragePort] ([KvKbRecordStore]); account storage implements
/// it over versioned remote records.
abstract interface class KbRecordStore {
  Future<KbRecord?> read(String appId, String key);

  /// Records whose key starts with [prefix], in any order.
  Future<List<KbRecord>> list(String appId, String prefix);

  Future<KbWriteOutcome> write(
    String appId,
    String key,
    Object? value, {
    required KbExpectation expected,
    bool force = false,
  });

  Future<KbWriteOutcome> remove(
    String appId,
    String key, {
    required KbExpectation expected,
    bool force = false,
  });

  /// Writes rejected on reconnect. Empty for a store that is never offline.
  Future<List<KbPendingConflict>> conflicts(String appId);

  /// Drop every record of [appId] held by **this** store — for a device store
  /// that is the device's copy, never the account's.
  Future<void> clear(String appId);
}

/// `kb` records in the kernel key/value store — the device's copy.
///
/// Storage key: `app/<appId>/kb/<key>`, each segment percent-encoded so an
/// app id such as `listing:abc` and any key character are valid file names
/// on every platform. A deleted key keeps a tombstone so its version keeps
/// counting up: a writer holding a version from before the delete must not
/// match a record created after it.
class KvKbRecordStore implements KbRecordStore {
  KvKbRecordStore(this.kv);

  final mb.KvStoragePort kv;

  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  static String _enc(String segment) => Uri.encodeComponent(segment);

  String _scope(String appId) => 'app/${_enc(appId)}/kb/';

  String _storageKey(String appId, String key) =>
      _scope(appId) + key.split('/').map(_enc).join('/');

  /// Encodes a string prefix segment by segment. Percent-encoding maps each
  /// character on its own, so the encoding of a prefix is a prefix of the
  /// encoding of every key that starts with it.
  String _storagePrefix(String appId, String prefix) =>
      _scope(appId) + prefix.split('/').map(_enc).join('/');

  String _keyOf(String appId, String storageKey) => storageKey
      .substring(_scope(appId).length)
      .split('/')
      .map(Uri.decodeComponent)
      .join('/');

  Future<Map<String, Object?>?> _raw(String storageKey) async {
    final raw = await kv.get(storageKey);
    if (raw is Map && raw['v'] is num) return raw.cast<String, Object?>();
    return null;
  }

  KbRecord? _recordOf(String key, Map<String, Object?>? raw) {
    if (raw == null || raw['deleted'] == true) return null;
    return KbRecord(
      key: key,
      value: raw['value'],
      version: '${(raw['v'] as num).toInt()}',
    );
  }

  /// Serialises writes to one storage key so read-compare-write is atomic
  /// within the process.
  Future<T> _locked<T>(String storageKey, Future<T> Function() body) {
    final previous = _tails[storageKey] ?? Future<void>.value();
    final result = previous.then((_) => body());
    _tails[storageKey] = result.then((_) {}, onError: (_) {});
    return result;
  }

  static bool _matches(KbExpectation expected, KbRecord? current) =>
      switch (expected) {
        _Unknown() => true,
        _Absent() => current == null,
        KbExpectedVersion(:final version) => current?.version == version,
      };

  @override
  Future<KbRecord?> read(String appId, String key) async =>
      _recordOf(key, await _raw(_storageKey(appId, key)));

  @override
  Future<List<KbRecord>> list(String appId, String prefix) async {
    final out = <KbRecord>[];
    for (final storageKey in await kv.keys(
      prefix: _storagePrefix(appId, prefix),
    )) {
      final key = _keyOf(appId, storageKey);
      final record = _recordOf(key, await _raw(storageKey));
      if (record != null) out.add(record);
    }
    return out;
  }

  @override
  Future<KbWriteOutcome> write(
    String appId,
    String key,
    Object? value, {
    required KbExpectation expected,
    bool force = false,
  }) {
    final storageKey = _storageKey(appId, key);
    return _locked(storageKey, () async {
      final raw = await _raw(storageKey);
      final current = _recordOf(key, raw);
      if (!force && !_matches(expected, current)) return KbConflict(current);
      final next = (raw == null ? 0 : (raw['v'] as num).toInt()) + 1;
      await kv.set(storageKey, <String, Object?>{'v': next, 'value': value});
      return KbWritten(version: '$next', existed: current != null);
    });
  }

  @override
  Future<KbWriteOutcome> remove(
    String appId,
    String key, {
    required KbExpectation expected,
    bool force = false,
  }) {
    final storageKey = _storageKey(appId, key);
    return _locked(storageKey, () async {
      final raw = await _raw(storageKey);
      final current = _recordOf(key, raw);
      if (!force && !_matches(expected, current)) return KbConflict(current);
      if (current == null)
        return const KbWritten(version: null, existed: false);
      final next = (raw!['v'] as num).toInt() + 1;
      await kv.set(storageKey, <String, Object?>{'v': next, 'deleted': true});
      return const KbWritten(version: null, existed: true);
    });
  }

  @override
  Future<List<KbPendingConflict>> conflicts(String appId) async =>
      const <KbPendingConflict>[];

  @override
  Future<void> clear(String appId) async {
    for (final storageKey in await kv.keys(prefix: _scope(appId))) {
      await kv.remove(storageKey);
    }
  }
}

/// One bundle's `kb` — the contract a host atom forwards to.
class BundleKbStore {
  BundleKbStore({required this.appId, required this.records, this.engine});

  /// `listing:<listingId>` or `bundle:<manifest.id>`.
  final String appId;

  final KbRecordStore records;

  /// Knowledge query. Null where the host runs no knowledge engine.
  final KnowledgeQueryEngine? engine;

  /// The version this store last saw per key; a present entry with a null
  /// value means "seen absent".
  final Map<String, String?> _seen = <String, String?>{};

  KbExpectation _expectationFor(String key) {
    if (!_seen.containsKey(key)) return KbExpectation.unknown;
    final version = _seen[key];
    return version == null ? KbExpectation.absent : KbExpectation.at(version);
  }

  Future<Object?> get(String key) async {
    checkKey(key);
    final record = await records.read(appId, key);
    _seen[key] = record?.version;
    return record?.value;
  }

  Future<List<Map<String, Object?>>> list([String prefix = '']) async {
    _checkPrefix(prefix);
    final found = await records.list(appId, prefix)
      ..sort((a, b) => a.key.compareTo(b.key));
    final out = <Map<String, Object?>>[];
    for (final record in found) {
      _seen[record.key] = record.version;
      out.add(<String, Object?>{'key': record.key, 'value': record.value});
    }
    return out;
  }

  Future<Map<String, Object?>> put(
    String key,
    Object? value, {
    bool force = false,
  }) async {
    checkKey(key);
    _checkValue(value, '');
    final outcome = await records.write(
      appId,
      key,
      value,
      expected: _expectationFor(key),
      force: force,
    );
    return _answer(key, outcome, (_) => const <String, Object?>{'ok': true});
  }

  Future<Map<String, Object?>> delete(String key, {bool force = false}) async {
    checkKey(key);
    final outcome = await records.remove(
      appId,
      key,
      expected: _expectationFor(key),
      force: force,
    );
    return _answer(
      key,
      outcome,
      (written) => <String, Object?>{'removed': written.existed},
    );
  }

  Future<List<Map<String, Object?>>> conflicts() async =>
      <Map<String, Object?>>[
        for (final c in await records.conflicts(appId))
          <String, Object?>{'key': c.key, 'mine': c.mine, 'theirs': c.theirs},
      ];

  Future<List<Map<String, Object?>>> query(
    String text, {
    int topK = 5,
    String? namespace,
    String? sourceId,
  }) async {
    final engine = this.engine;
    if (engine == null) {
      throw const KbError(
        KbError.queryUnavailable,
        'kb.query is not available in this host: no knowledge engine is running',
      );
    }
    final hits = await engine.query(
      text,
      topK: topK,
      namespace: namespace,
      sourceId: sourceId,
    );
    return <Map<String, Object?>>[for (final h in hits) h.toJson()];
  }

  /// Drop this device's copy — what uninstalling the bundle here means.
  Future<void> clearLocal() async {
    await records.clear(appId);
    _seen.clear();
  }

  Map<String, Object?> _answer(
    String key,
    KbWriteOutcome outcome,
    Map<String, Object?> Function(KbWritten written) onWritten,
  ) {
    switch (outcome) {
      case KbWritten():
        _seen[key] = outcome.version;
        return onWritten(outcome);
      case KbConflict(:final current):
        _seen[key] = current?.version;
        return <String, Object?>{
          'ok': false,
          'conflict': <String, Object?>{'value': current?.value},
        };
    }
  }

  /// Key rules every host applies: non-empty; no leading `/`; no `\` or NUL;
  /// no empty, `.` or `..` segment when split on `/`.
  static void checkKey(Object? key) {
    if (key is! String || key.isEmpty) {
      throw const KbError(KbError.invalidKey, 'key must be a non-empty string');
    }
    final reason = _keyProblem(key);
    if (reason != null) {
      throw KbError(KbError.invalidKey, '$reason: $key');
    }
  }

  static String? _keyProblem(String key) {
    if (key.startsWith('/')) return 'key starts with /';
    if (key.contains(r'\')) return r'key contains \';
    if (key.contains(' ')) return 'key contains NUL';
    for (final segment in key.split('/')) {
      if (segment.isEmpty) return 'key has an empty segment';
      if (segment == '.' || segment == '..') return 'key has a . or .. segment';
    }
    return null;
  }

  static void _checkPrefix(String prefix) {
    if (prefix.isEmpty) return;
    final trimmed =
        prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix;
    final reason = trimmed.isEmpty ? 'prefix is only /' : _keyProblem(trimmed);
    if (reason != null) {
      throw KbError(KbError.invalidKey, '$reason: $prefix');
    }
  }

  /// Values are what JSON carries: maps with string keys, lists, strings,
  /// finite numbers, booleans and null. Anything else would be stored as one
  /// thing and read back as another.
  static void _checkValue(Object? value, String path) {
    if (value == null || value is String || value is bool) return;
    if (value is num) {
      if (value.isFinite) return;
      throw KbError(KbError.invalidValue, 'non-finite number at ${_at(path)}');
    }
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _checkValue(value[i], '$path[$i]');
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw KbError(
            KbError.invalidValue,
            'non-string map key at ${_at(path)}',
          );
        }
        _checkValue(entry.value, '$path.${entry.key}');
      }
      return;
    }
    throw KbError(
      KbError.invalidValue,
      '${value.runtimeType} is not a JSON value at ${_at(path)}',
    );
  }

  static String _at(String path) => path.isEmpty ? 'the top level' : path;
}

/// What importing a [DomainStorage] namespace into `kb` did.
class KbImportReport {
  const KbImportReport({
    required this.imported,
    required this.alreadyPresent,
    required this.skipped,
  });

  final List<String> imported;

  /// Keys `kb` already held — left as they were.
  final List<String> alreadyPresent;

  /// Keys that break the key rules, with the reason.
  final Map<String, String> skipped;
}

/// Moves a host's former per-bundle [DomainStorage] state into `kb` once.
///
/// Never overwrites what `kb` already holds, and never deletes the source —
/// removing the old files is the person's decision, not the migration's.
Future<KbImportReport> importDomainStorageNamespace({
  // ignore: deprecated_member_use_from_same_package
  required DomainStorage source,
  required String namespace,
  required BundleKbStore target,
}) async {
  final imported = <String>[];
  final present = <String>[];
  final skipped = <String, String>{};
  for (final entry in await source.list(namespace)) {
    try {
      BundleKbStore.checkKey(entry.key);
    } on KbError catch (e) {
      skipped[entry.key] = e.message;
      continue;
    }
    if (await target.get(entry.key) != null) {
      present.add(entry.key);
      continue;
    }
    final answer = await target.put(entry.key, entry.value);
    if (answer['ok'] == true) {
      imported.add(entry.key);
    } else {
      present.add(entry.key);
    }
  }
  return KbImportReport(
    imported: imported,
    alreadyPresent: present,
    skipped: skipped,
  );
}
