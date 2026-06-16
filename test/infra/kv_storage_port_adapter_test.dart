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

  group('KvStoragePortAdapter — encode fallback', () {
    test('non-JSON-native value with toJson() round-trips', () async {
      final kv = KvStoragePortAdapter(rootDir: tmp.path);
      await kv.set('e', _Envelope('z1'));
      expect(await kv.get('e'), <String, Object?>{'id': 'z1'});
    });
  });
}
