/// A bundle's `kb` in account storage keeps the §4.8.1 contract while the
/// account is reachable, keeps working while it is not, and on reconnect
/// never forces a write over something another device wrote — it reports it.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

/// Account storage for one app, with versions and a reachability switch.
class _FakeAccount implements KbAccountRecords {
  final Map<String, (Object?, int)> records = {};
  bool online = true;
  int _next = 0;

  void _reach() {
    if (!online) throw StateError('account unreachable');
  }

  KbRecord? _record(String key) {
    final r = records[key];
    return r == null ? null : KbRecord(key: key, value: r.$1, version: 'v${r.$2}');
  }

  @override
  Future<KbRecord?> read(String appId, String key) async {
    _reach();
    return _stored(AccountKbRecordStore.kbKeyOf(key)!);
  }

  /// A record as the account answers it — under its account key.
  KbRecord? _stored(String key) {
    final r = _record(key);
    return r == null
        ? null
        : KbRecord(key: AccountKbRecordStore.accountKeyOf(key), value: r.value, version: r.version);
  }

  @override
  Future<List<KbRecord>> list(String appId, String prefix) async {
    _reach();
    return [
      for (final k in records.keys)
        if (AccountKbRecordStore.accountKeyOf(k).startsWith(prefix)) _stored(k)!,
    ];
  }

  @override
  Future<String> write(String appId, String key, Object? value, {String? ifMatch}) async {
    _reach();
    final kbKey = AccountKbRecordStore.kbKeyOf(key)!;
    final current = _stored(kbKey);
    if (ifMatch != null && current?.version != ifMatch) throw KbAccountConflict(current);
    records[kbKey] = (value, ++_next);
    return 'v$_next';
  }

  @override
  Future<bool> remove(String appId, String key, {String? ifMatch}) async {
    _reach();
    final kbKey = AccountKbRecordStore.kbKeyOf(key)!;
    final current = _stored(kbKey);
    if (ifMatch != null && current?.version != ifMatch) throw KbAccountConflict(current);
    return records.remove(kbKey) != null;
  }

  /// Another device writing straight to the account.
  void writeFromElsewhere(String key, Object? value) => records[key] = (value, ++_next);
}

/// An account that is reachable and refuses one key it does not accept.
class _KeyRefusingAccount extends _FakeAccount {
  @override
  Future<String> write(String appId, String key, Object? value, {String? ifMatch}) async {
    _reach();
    if (AccountKbRecordStore.kbKeyOf(key) == 'bad') {
      throw const KbError(KbError.invalidKey, 'invalid storage key');
    }
    return super.write(appId, key, value, ifMatch: ifMatch);
  }
}

/// An account that is reachable and full.
class _RefusingAccount extends _FakeAccount {
  @override
  Future<String> write(String appId, String key, Object? value, {String? ifMatch}) async =>
      throw const KbError(KbError.quotaExceeded, 'account storage is full');
}

void main() {
  const appId = 'listing:L1';
  late _FakeAccount account;
  late InMemoryKvStoragePort kv;
  late BundleKbStore kb;

  setUp(() {
    account = _FakeAccount();
    kv = InMemoryKvStoragePort();
    kb = BundleKbStore(appId: appId, records: AccountKbRecordStore(account: account, kv: kv));
  });

  group('reachable', () {
    test('put, get, list, delete land in the account with the contract shapes', () async {
      expect(await kb.put('notes/a', {'n': 1}), {'ok': true});
      expect(await kb.get('notes/a'), {'n': 1});
      expect(await kb.list('notes/'), [
        {'key': 'notes/a', 'value': {'n': 1}},
      ]);
      expect(await kb.delete('notes/a'), {'removed': true});
      expect(account.records, isEmpty);
    });

    test('a write based on a version another device replaced is a conflict, not an overwrite',
        () async {
      await kb.put('a', 1);
      await kb.get('a');
      account.writeFromElsewhere('a', 'theirs');

      expect(await kb.put('a', 2), {
        'ok': false,
        'conflict': {'value': 'theirs'},
      });
      expect(account.records['a']!.$1, 'theirs');
      expect(await kb.put('a', 2, force: true), {'ok': true});
      expect(account.records['a']!.$1, 2);
    });
  });

  group('unreachable', () {
    test('reads answer the last known account copy', () async {
      await kb.put('a', {'n': 1});
      account.online = false;

      expect(await kb.get('a'), {'n': 1});
      expect(await kb.list(), [
        {'key': 'a', 'value': {'n': 1}},
      ]);
    });

    test('writes wait on the device and go up when the account answers', () async {
      await kb.put('a', 1);
      await kb.get('a');
      account.online = false;

      expect(await kb.put('a', 2), {'ok': true});
      expect(await kb.put('b', 'new'), {'ok': true});
      expect(await kb.get('a'), 2, reason: 'this device sees its own write');
      expect(account.records['a']!.$1, 1, reason: 'the account has not seen it yet');

      account.online = true;
      expect(await kb.conflicts(), isEmpty);
      expect(account.records['a']!.$1, 2);
      expect(account.records['b']!.$1, 'new');
    });

    test('a waiting write whose base moved is kept as a conflict, never forced', () async {
      await kb.put('a', 'base');
      await kb.get('a');
      account.online = false;
      await kb.put('a', 'mine');

      account.online = true;
      account.writeFromElsewhere('a', 'theirs');

      expect(await kb.conflicts(), [
        {'key': 'a', 'mine': 'mine', 'theirs': 'theirs'},
      ]);
      expect(account.records['a']!.$1, 'theirs');
    });

    test('a removal while unreachable goes up too', () async {
      await kb.put('a', 1);
      await kb.get('a');
      account.online = false;
      expect(await kb.delete('a'), {'removed': true});
      expect(await kb.get('a'), isNull);

      account.online = true;
      await kb.conflicts();
      expect(account.records.containsKey('a'), isFalse);
    });
  });

  test('a refusal from the account reaches the bundle and is not queued', () async {
    final refusing = _RefusingAccount();
    final store = BundleKbStore(
      appId: appId,
      records: AccountKbRecordStore(account: refusing, kv: kv),
    );

    await expectLater(
      store.put('big', 'x'),
      throwsA(isA<KbError>().having((e) => e.code, 'code', KbError.quotaExceeded)),
    );
    expect(await kv.keys(prefix: 'app/${Uri.encodeComponent(appId)}/kbq/'), isEmpty);
  });

  test('clearing drops this device\'s copy and queue, never the account', () async {
    await kb.put('a', 1);
    account.online = false;
    await kb.put('b', 2);

    await kb.clearLocal();

    account.online = true;
    expect(account.records.keys, ['a'], reason: 'the queued write was this device\'s and went with it');
    expect(await kb.get('a'), 1);
  });

  group('account key layout (platform spec 20 §2.1.2)', () {
    final accountKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$');

    test('any key a bundle may use is stored in the account grammar and reads back', () {
      for (final key in ['메모 1', 'a:b', 'notes/2026 09/x@y', 'kb', 'A-Z_0.9', '%41']) {
        final stored = AccountKbRecordStore.accountKeyOf(key);
        expect(accountKey.hasMatch(stored), isTrue, reason: stored);
        expect(AccountKbRecordStore.kbKeyOf(stored), key);
      }
      expect(AccountKbRecordStore.accountKeyOf('메모 1'), 'kb/:EB:A9:94:EB:AA:A8:201');
      expect(AccountKbRecordStore.accountKeyOf('a:b'), 'kb/a:3Ab');
      expect(AccountKbRecordStore.kbKeyOf('settings'), isNull, reason: 'not a kb record');
    });

    test('keys with escaped characters round-trip through the store and list by prefix',
        () async {
      await kb.put('메모/1', 'one');
      await kb.put('메모/2', 'two');
      await kb.put('other', 3);

      expect(await kb.get('메모/1'), 'one');
      expect((await kb.list('메모/')).map((e) => (e as Map)['key']), ['메모/1', '메모/2']);
    });

    test('a key too long for the account is refused and never queued, even offline', () async {
      final tooLong = 'x' * (AccountKbRecordStore.accountKeyLimit - 'kb/'.length + 1);
      final invalidKey = throwsA(isA<KbError>().having((e) => e.code, 'code', KbError.invalidKey));

      await expectLater(kb.put(tooLong, 1), invalidKey);
      account.online = false;
      await expectLater(kb.put(tooLong, 1), invalidKey);
      expect(await kv.keys(prefix: 'app/${Uri.encodeComponent(appId)}/kbq/'), isEmpty);
    });

    test('a key the account refuses is heard now, and a refusal in the queue does not '
        'hold back the writes behind it', () async {
      final refusing = _KeyRefusingAccount();
      final store = BundleKbStore(
        appId: appId,
        records: AccountKbRecordStore(account: refusing, kv: kv),
      );

      await expectLater(store.put('bad', 1), throwsA(isA<KbError>()));
      expect(await kv.keys(prefix: 'app/${Uri.encodeComponent(appId)}/kbq/'), isEmpty);

      refusing.online = false;
      await store.put('bad', 1);
      await store.put('good', 2);
      refusing.online = true;

      final conflicts = await store.conflicts();
      expect(refusing.records.keys, ['good']);
      expect(conflicts.map((c) => (c as Map)['key']), ['bad']);
    });
  });
}
