import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A key is a path under the storage root. One that climbs out of it must be
/// refused, and narrowing the listing walk must not change which keys a
/// prefix returns.
void main() {
  late Directory root;
  late Directory outside;

  setUp(() async {
    final parent = await Directory.systemTemp.createTemp('kv_guard_');
    root = Directory(p.join(parent.path, 'root'))..createSync();
    outside = parent;
  });

  tearDown(() async {
    if (await outside.exists()) await outside.delete(recursive: true);
  });

  group('a key that resolves outside the root', () {
    for (final key in [
      '../escape',
      'a/../../escape',
      'app/x/../../../escape',
    ]) {
      test('$key is refused on every operation and writes nothing', () async {
        final kv = KvStoragePortAdapter(rootDir: root.path);
        expect(() => kv.set(key, 1), throwsArgumentError);
        expect(() => kv.get(key), throwsArgumentError);
        expect(() => kv.remove(key), throwsArgumentError);
        expect(() => kv.exists(key), throwsArgumentError);
        expect(File(p.join(outside.path, 'escape.json')).existsSync(), isFalse);
      });
    }

    test(
      'a . or .. that stays inside the root is refused rather than aliased',
      () async {
        final kv = KvStoragePortAdapter(rootDir: root.path);
        await kv.set('a/b', 1);
        // `a/x/../b` and `a/./b` would normalise onto `a/b` — a second name for
        // the same file.
        expect(() => kv.get('a/x/../b'), throwsArgumentError);
        expect(() => kv.set('a/./b', 2), throwsArgumentError);
        expect(await kv.get('a/b'), 1);
      },
    );
  });

  group('keys(prefix) after narrowing the walk', () {
    Future<KvStoragePortAdapter> seeded() async {
      final kv = KvStoragePortAdapter(rootDir: root.path);
      for (final k in [
        'app/one/kb/a',
        'app/one/kb/b/c',
        'app/one/kbx',
        'app/two/kb/a',
        'philosophy.ethos:e1',
        'top',
      ]) {
        await kv.set(k, k);
      }
      return kv;
    }

    Future<List<String>> byFullScan(
      KvStoragePortAdapter kv,
      String prefix,
    ) async => (await kv.keys()).where((k) => k.startsWith(prefix)).toList();

    for (final prefix in [
      'app/one/kb/',
      'app/one/kb',
      'app/one/k',
      'app/',
      'app/one/kb/b/',
      'philosophy.ethos:',
      'to',
      'app/none/',
    ]) {
      test(
        '"$prefix" returns exactly what a full scan filtered by prefix does',
        () async {
          final kv = await seeded();
          expect(await kv.keys(prefix: prefix), await byFullScan(kv, prefix));
        },
      );
    }

    test(
      'a prefix whose directory climbs out of the root lists nothing',
      () async {
        final kv = await seeded();
        expect(await kv.keys(prefix: '../x/'), isEmpty);
      },
    );
  });
}
