/// `kb` records in account storage, with this device's copy underneath.
///
/// Bundle spec 04_Tools §4.8.1 puts a bundle's `kb` state in the account's
/// `app/<appId>` scope (platform spec 20 §2) where the host is signed in, and
/// on the device where it is not. This is the signed-in side: every read and
/// write goes to the account, conditioned on the version last seen, and the
/// device keeps a copy so a bundle still works while the account is out of
/// reach.
///
/// While unreachable, writes land on the device and wait in a queue with the
/// account version they were based on. When the account answers again the
/// queue goes up in order; a write whose base moved meanwhile is not forced —
/// it is kept as a conflict (`{key, mine, theirs}`) for the bundle to settle,
/// because the host does not know what the value means.
library;

import 'dart:convert' show utf8;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import 'bundle_kb_store.dart';

/// The account's versioned `kb` records for one app.
///
/// Implemented by the host over account storage, in the `app/<appId>` scope.
/// Keys arrive as account keys ([AccountKbRecordStore.accountKeyOf]) and are
/// stored as given; records come back under the account key. Versions are
/// opaque. A write or removal whose [ifMatch] does not match throws
/// [KbAccountConflict]; a refusal the account answered (quota, size, a key or
/// scope it does not accept) throws [KbError]; any other failure means the
/// account could not be reached.
abstract interface class KbAccountRecords {
  Future<KbRecord?> read(String appId, String key);

  /// Records whose key starts with [prefix], in any order.
  Future<List<KbRecord>> list(String appId, String prefix);

  /// Writes [value]; answers the new version. Unconditional when [ifMatch] is
  /// null.
  Future<String> write(String appId, String key, Object? value, {String? ifMatch});

  /// Removes [key]; answers whether a record was there.
  Future<bool> remove(String appId, String key, {String? ifMatch});
}

/// The account holds a different version than the write was based on.
class KbAccountConflict implements Exception {
  const KbAccountConflict(this.current);

  /// What the account holds now; null when the record is gone.
  final KbRecord? current;

  @override
  String toString() => 'KbAccountConflict(${current?.version ?? 'absent'})';
}

/// Versions minted for writes the account has not seen yet.
const String _localVersionPrefix = 'local:';

class AccountKbRecordStore implements KbRecordStore {
  AccountKbRecordStore({required this.account, required this.kv});

  final KbAccountRecords account;

  /// This device's key-value store — the same one [KvKbRecordStore] uses.
  final mb.KvStoragePort kv;

  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  static String _enc(String segment) => Uri.encodeComponent(segment);

  /// Longest key account storage holds (platform spec 20 §1).
  static const int accountKeyLimit = 256;

  static const String _accountKeyPrefix = 'kb/';

  /// The account key a `kb` key is stored under (platform spec 20 §2.1.2):
  /// `kb/`, then the key with every UTF-8 byte outside `A-Z a-z 0-9 . _ / -`
  /// written as `:` and two uppercase hex digits — `:` itself included. Every
  /// host writes the same layout, it reverses exactly, and a key's prefix
  /// stores as its stored form's prefix, so a prefix listing stays one.
  static String accountKeyOf(String key) {
    final out = StringBuffer(_accountKeyPrefix);
    for (final b in utf8.encode(key)) {
      final safe = (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          b == 0x2E ||
          b == 0x5F ||
          b == 0x2F ||
          b == 0x2D;
      if (safe) {
        out.writeCharCode(b);
      } else {
        out
          ..write(':')
          ..write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return out.toString();
  }

  /// The `kb` key an account key holds; null when it is not a `kb` record.
  static String? kbKeyOf(String accountKey) {
    if (!accountKey.startsWith(_accountKeyPrefix)) return null;
    final s = accountKey.substring(_accountKeyPrefix.length);
    final bytes = <int>[];
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c != 0x3A) {
        bytes.add(c);
        continue;
      }
      final hex = i + 2 < s.length ? int.tryParse(s.substring(i + 1, i + 3), radix: 16) : null;
      if (hex == null) return null;
      bytes.add(hex);
      i += 2;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  /// A key whose stored form the account cannot hold is refused before it is
  /// read, written or queued — a queued write the account can never accept
  /// would read back as saved and never reach another device.
  static String _accountKey(String key) {
    final stored = accountKeyOf(key);
    if (stored.length > accountKeyLimit) {
      throw KbError(
        KbError.invalidKey,
        'key is longer than account storage holds (${stored.length} > $accountKeyLimit stored)',
      );
    }
    return stored;
  }

  static KbRecord? _rekey(String key, KbRecord? record) =>
      record == null ? null : KbRecord(key: key, value: record.value, version: record.version);

  String _root(String appId, String area) => 'app/${_enc(appId)}/$area/';

  String _path(String appId, String area, String key) =>
      _root(appId, area) + key.split('/').map(_enc).join('/');

  String _keyOf(String appId, String area, String storageKey) => storageKey
      .substring(_root(appId, area).length)
      .split('/')
      .map(Uri.decodeComponent)
      .join('/');

  // Device areas: `kbr` = last known account copy, `kbq` = writes waiting for
  // the account, `kbc` = writes the account turned down on reconnect.

  Future<T> _locked<T>(String appId, Future<T> Function() body) {
    final previous = _tails[appId] ?? Future<void>.value();
    final result = previous.then((_) => body());
    _tails[appId] = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, Object?>?> _get(String storageKey) async {
    final raw = await kv.get(storageKey);
    return raw is Map ? raw.cast<String, Object?>() : null;
  }

  Future<void> _remember(String appId, String key, KbRecord? record) async {
    final path = _path(appId, 'kbr', key);
    if (record == null) {
      await kv.remove(path);
    } else {
      await kv.set(path, <String, Object?>{
        'value': record.value,
        'version': record.version,
      });
    }
  }

  Future<KbRecord?> _remembered(String appId, String key) async {
    final raw = await _get(_path(appId, 'kbr', key));
    if (raw == null) return null;
    return KbRecord(key: key, value: raw['value'], version: '${raw['version']}');
  }

  Future<Map<String, Object?>?> _pending(String appId, String key) =>
      _get(_path(appId, 'kbq', key));

  Future<List<String>> _keysIn(String appId, String area, [String prefix = '']) async {
    final keys = await kv.keys(
      prefix: _root(appId, area) + prefix.split('/').map(_enc).join('/'),
    );
    return [for (final k in keys) _keyOf(appId, area, k)];
  }

  /// Only an unreachable account queues. A conflict is an answer, and a
  /// [KbError] (quota, size) is a refusal the bundle has to hear now.
  static bool _isOffline(Object error) =>
      error is! KbAccountConflict && error is! KbError;

  /// The account version a write should be conditioned on, or null for an
  /// unconditional write.
  Future<String?> _ifMatch(String appId, String key, KbExpectation expected, bool force) async {
    if (force) return null;
    switch (expected) {
      case KbExpectedVersion(:final version):
        if (!version.startsWith(_localVersionPrefix)) return version;
        final pending = await _pending(appId, key);
        return pending?['base'] as String?;
      default:
        return null;
    }
  }

  /// Sends queued writes, oldest first. Stops at the first unreachable call.
  Future<void> _flush(String appId) async {
    final keys = await _keysIn(appId, 'kbq');
    final entries = <(String, Map<String, Object?>)>[];
    for (final key in keys) {
      final raw = await _pending(appId, key);
      if (raw != null) entries.add((key, raw));
    }
    entries.sort((a, b) => ((a.$2['seq'] as num?) ?? 0).compareTo((b.$2['seq'] as num?) ?? 0));
    for (final (key, raw) in entries) {
      final base = raw['base'] as String?;
      final deleted = raw['deleted'] == true;
      try {
        if (deleted) {
          await account.remove(appId, _accountKey(key), ifMatch: base);
          await _remember(appId, key, null);
        } else {
          final version = await account.write(appId, _accountKey(key), raw['value'], ifMatch: base);
          await _remember(appId, key, KbRecord(key: key, value: raw['value'], version: version));
        }
        await kv.remove(_path(appId, 'kbq', key));
      } on KbAccountConflict catch (conflict) {
        await kv.set(_path(appId, 'kbc', key), <String, Object?>{
          'mine': deleted ? null : raw['value'],
          'theirs': conflict.current?.value,
        });
        await _remember(appId, key, conflict.current);
        await kv.remove(_path(appId, 'kbq', key));
      } on KbError catch (refused) {
        // The account refused the queued write (quota, size). Kept beside the
        // conflicts so it is not silently lost, with the account's value as
        // theirs.
        await kv.set(_path(appId, 'kbc', key), <String, Object?>{
          'mine': deleted ? null : raw['value'],
          'theirs': (await _remembered(appId, key))?.value,
          'error': refused.code,
        });
        await kv.remove(_path(appId, 'kbq', key));
      } catch (_) {
        return;
      }
    }
  }

  Future<void> _tryFlush(String appId) async {
    try {
      await _flush(appId);
    } catch (_) {/* the account is unreachable; the queue waits */}
  }

  Future<int> _nextSeq(String appId) async {
    final path = '${_root(appId, 'kbm')}seq';
    final raw = await kv.get(path);
    final next = (raw is num ? raw.toInt() : 0) + 1;
    await kv.set(path, next);
    return next;
  }

  @override
  Future<KbRecord?> read(String appId, String key) => _locked(appId, () async {
        final stored = _accountKey(key);
        await _tryFlush(appId);
        final pending = await _pending(appId, key);
        if (pending != null) {
          return pending['deleted'] == true
              ? null
              : KbRecord(key: key, value: pending['value'], version: '$_localVersionPrefix${pending['seq']}');
        }
        try {
          final record = _rekey(key, await account.read(appId, stored));
          await _remember(appId, key, record);
          return record;
        } catch (e) {
          if (!_isOffline(e)) rethrow;
          return _remembered(appId, key);
        }
      });

  @override
  Future<List<KbRecord>> list(String appId, String prefix) => _locked(appId, () async {
        await _tryFlush(appId);
        final byKey = <String, KbRecord>{};
        try {
          for (final stored in await account.list(appId, accountKeyOf(prefix))) {
            final key = kbKeyOf(stored.key);
            if (key == null) continue;
            final record = _rekey(key, stored)!;
            byKey[key] = record;
            await _remember(appId, key, record);
          }
        } catch (e) {
          if (!_isOffline(e)) rethrow;
          for (final key in await _keysIn(appId, 'kbr', prefix)) {
            final record = await _remembered(appId, key);
            if (record != null) byKey[key] = record;
          }
        }
        for (final key in await _keysIn(appId, 'kbq', prefix)) {
          final pending = await _pending(appId, key);
          if (pending == null) continue;
          if (pending['deleted'] == true) {
            byKey.remove(key);
          } else {
            byKey[key] = KbRecord(key: key, value: pending['value'], version: '$_localVersionPrefix${pending['seq']}');
          }
        }
        return byKey.values.toList();
      });

  @override
  Future<KbWriteOutcome> write(
    String appId,
    String key,
    Object? value, {
    required KbExpectation expected,
    bool force = false,
  }) =>
      _locked(appId, () async {
        await _tryFlush(appId);
        final stored = _accountKey(key);
        final ifMatch = await _ifMatch(appId, key, expected, force);
        final before = await _remembered(appId, key);
        try {
          final version = await account.write(appId, stored, value, ifMatch: ifMatch);
          await _remember(appId, key, KbRecord(key: key, value: value, version: version));
          await kv.remove(_path(appId, 'kbq', key));
          await kv.remove(_path(appId, 'kbc', key));
          return KbWritten(version: version, existed: before != null);
        } on KbAccountConflict catch (conflict) {
          await _remember(appId, key, conflict.current);
          return KbConflict(_rekey(key, conflict.current));
        } catch (e) {
          if (!_isOffline(e)) rethrow;
          return _queue(appId, key, value: value, deleted: false, ifMatch: ifMatch, existed: before != null);
        }
      });

  @override
  Future<KbWriteOutcome> remove(
    String appId,
    String key, {
    required KbExpectation expected,
    bool force = false,
  }) =>
      _locked(appId, () async {
        await _tryFlush(appId);
        final stored = _accountKey(key);
        final ifMatch = await _ifMatch(appId, key, expected, force);
        try {
          final existed = await account.remove(appId, stored, ifMatch: ifMatch);
          await _remember(appId, key, null);
          await kv.remove(_path(appId, 'kbq', key));
          await kv.remove(_path(appId, 'kbc', key));
          return KbWritten(version: null, existed: existed);
        } on KbAccountConflict catch (conflict) {
          await _remember(appId, key, conflict.current);
          return KbConflict(_rekey(key, conflict.current));
        } catch (e) {
          if (!_isOffline(e)) rethrow;
          final before = await _remembered(appId, key);
          await _queue(appId, key, value: null, deleted: true, ifMatch: ifMatch, existed: before != null);
          return KbWritten(version: null, existed: before != null);
        }
      });

  Future<KbWritten> _queue(
    String appId,
    String key, {
    required Object? value,
    required bool deleted,
    required String? ifMatch,
    required bool existed,
  }) async {
    final waiting = await _pending(appId, key);
    // A second offline write to the same key keeps the first one's base: the
    // account has seen neither.
    final base = waiting != null ? waiting['base'] as String? : ifMatch;
    final seq = await _nextSeq(appId);
    await kv.set(_path(appId, 'kbq', key), <String, Object?>{
      if (!deleted) 'value': value,
      'deleted': deleted,
      'base': base,
      'seq': seq,
    });
    return KbWritten(version: deleted ? null : '$_localVersionPrefix$seq', existed: existed);
  }

  @override
  Future<List<KbPendingConflict>> conflicts(String appId) => _locked(appId, () async {
        await _tryFlush(appId);
        final out = <KbPendingConflict>[];
        for (final key in await _keysIn(appId, 'kbc')) {
          final raw = await _get(_path(appId, 'kbc', key));
          if (raw == null) continue;
          out.add(KbPendingConflict(key: key, mine: raw['mine'], theirs: raw['theirs']));
        }
        return out;
      });

  /// Drops this device's copy, queue and conflicts. The account's records are
  /// not this device's to delete.
  @override
  Future<void> clear(String appId) =>
      _locked(appId, () => clearDeviceCopy(kv, appId));

  /// What [clear] removes, reachable without an account — a device that was
  /// signed in earlier still holds these areas after signing out, and
  /// uninstalling the bundle there has to drop them too.
  static Future<void> clearDeviceCopy(mb.KvStoragePort kv, String appId) async {
    for (final area in const ['kbr', 'kbq', 'kbc', 'kbm']) {
      final root = 'app/${_enc(appId)}/$area/';
      for (final storageKey in await kv.keys(prefix: root)) {
        await kv.remove(storageKey);
      }
    }
  }
}
