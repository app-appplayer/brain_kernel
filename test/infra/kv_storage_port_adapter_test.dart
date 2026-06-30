import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

/// A value that is not JSON-native but carries a `toJson()` — exercises
/// the encode fallback.
class _Envelope {
  _Envelope(this.id);
  final String id;
  Map<String, Object?> toJson() => <String, Object?>{'id': id};
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kv_adapter_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('KvStoragePortAdapter — no scope (default)', () {
    test('round-trips any key, no enforcement', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      await kv.set('ws/other/x', 1);
      await kv.set('global/y', 2);
      expect(await kv.get('ws/other/x'), 1);
      expect(await kv.get('global/y'), 2);
    });
  });

  group('KvStoragePortAdapter — workspace scope', () {
    test('global (non-ws/) key bypasses enforcement', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path, workspaceId: 'A');
      await kv.set('settings/theme', 'dark');
      expect(await kv.get('settings/theme'), 'dark');
    });

    test('matching ws/<id>/ key allowed', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path, workspaceId: 'A');
      await kv.set('ws/A/messages/1', 'hi');
      expect(await kv.get('ws/A/messages/1'), 'hi');
    });

    test('mismatched ws/<other>/ key throws on every op', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path, workspaceId: 'A');
      expect(() => kv.set('ws/B/x', 1), throwsArgumentError);
      expect(() => kv.get('ws/B/x'), throwsArgumentError);
      expect(() => kv.remove('ws/B/x'), throwsArgumentError);
      expect(() => kv.exists('ws/B/x'), throwsArgumentError);
    });

    test('mutable workspaceId re-points enforcement', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path, workspaceId: 'A');
      await kv.set('ws/A/x', 1);
      kv.workspaceId = 'B';
      expect(() => kv.get('ws/A/x'), throwsArgumentError);
      await kv.set('ws/B/y', 2);
      expect(await kv.get('ws/B/y'), 2);
    });
  });

  group('KvStoragePortAdapter — keys(prefix:) string-prefix contract', () {
    test('colon-namespaced flat keys are listed by prefix (regression)',
        () async {
      // Mirrors KvEthosStoreAdapter: set('philosophy.ethos:<id>', ...).
      // Previously keys(prefix:) treated the prefix as a directory and
      // returned [] for these flat keys, so bk.philosophy.list was empty.
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      await kv.set('philosophy.ethos:alpha', {'id': 'alpha'});
      await kv.set('philosophy.ethos:beta', {'id': 'beta'});

      expect(await kv.get('philosophy.ethos:alpha'), {'id': 'alpha'});
      expect(
        await kv.keys(prefix: 'philosophy.ethos:'),
        ['philosophy.ethos:alpha', 'philosophy.ethos:beta'],
      );
      expect((await kv.keys()).length, 2);
    });

    test('hierarchical slash keys still match a directory-style prefix',
        () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      await kv.set('ws/A/m/1', 'a');
      await kv.set('ws/A/m/2', 'b');
      await kv.set('global/z', 'c');

      expect(await kv.keys(prefix: 'ws/A/'), ['ws/A/m/1', 'ws/A/m/2']);
    });

    test('partial-segment prefix matches by string, not directory', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      await kv.set('ws/A/x', 1);
      await kv.set('ws/AB/y', 2);

      expect(await kv.keys(prefix: 'ws/A'), ['ws/A/x', 'ws/AB/y']);
    });

    test('empty store / non-matching prefix returns empty', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      expect(await kv.keys(prefix: 'nope:'), isEmpty);
      await kv.set('a:1', 1);
      expect(await kv.keys(prefix: 'b:'), isEmpty);
    });
  });

  group('KvStoragePortAdapter — encode fallback', () {
    test('non-JSON-native value with toJson() round-trips', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      await kv.set('e', _Envelope('z1'));
      expect(await kv.get('e'), <String, Object?>{'id': 'z1'});
    });
  });
}
