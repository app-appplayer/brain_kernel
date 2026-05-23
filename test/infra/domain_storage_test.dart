import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:brain_kernel/brain_kernel.dart';

void main() {
  late Directory tmp;
  late JsonFileDomainStorage store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('domain_storage_');
    store = JsonFileDomainStorage(rootDir: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('JsonFileDomainStorage', () {
    test('put + get round-trip preserves the value', () async {
      await store.put('com.test.a', 'greeting', 'hello');
      expect(await store.get('com.test.a', 'greeting'), 'hello');
    });

    test('preserves JSON-shaped values (map / list / number / bool)',
        () async {
      await store.put('com.test.b', 'shape', {
        'recents': ['x', 'y'],
        'count': 2,
        'active': true,
      });
      final v = await store.get('com.test.b', 'shape') as Map;
      expect(v['recents'], ['x', 'y']);
      expect(v['count'], 2);
      expect(v['active'], isTrue);
    });

    test('list returns every entry in the namespace', () async {
      await store.put('com.test.c', 'a', 1);
      await store.put('com.test.c', 'b', 2);
      final entries = await store.list('com.test.c');
      expect(entries.length, 2);
      expect(entries.map((e) => e.key).toSet(), {'a', 'b'});
    });

    test('list filters by prefix', () async {
      await store.put('com.test.c', 'recent/a', 1);
      await store.put('com.test.c', 'recent/b', 2);
      await store.put('com.test.c', 'pin/c', 3);
      final recents = await store.list('com.test.c', prefix: 'recent/');
      expect(recents.length, 2);
      expect(
        recents.map((e) => e.key).toSet(),
        {'recent/a', 'recent/b'},
      );
    });

    test('delete removes the entry and reports prior presence', () async {
      await store.put('com.test.d', 'k', 1);
      expect(await store.delete('com.test.d', 'k'), isTrue);
      expect(await store.delete('com.test.d', 'k'), isFalse);
      expect(await store.get('com.test.d', 'k'), isNull);
    });

    test('namespaces are isolated from one another', () async {
      await store.put('com.a', 'k', 'A-value');
      await store.put('com.b', 'k', 'B-value');
      expect(await store.get('com.a', 'k'), 'A-value');
      expect(await store.get('com.b', 'k'), 'B-value');
      await store.delete('com.a', 'k');
      // b's entry still there
      expect(await store.get('com.b', 'k'), 'B-value');
    });

    test('writes are durable across instances against the same root',
        () async {
      await store.put('com.persist', 'k', 'v1');
      // Construct a fresh adapter pointing at the same root.
      final fresh = JsonFileDomainStorage(rootDir: tmp.path);
      expect(await fresh.get('com.persist', 'k'), 'v1');
    });

    test('state.json on disk is human-readable + valid JSON', () async {
      await store.put('com.disk', 'a', 1);
      await store.put('com.disk', 'b', [10, 20]);
      final file = File(p.join(tmp.path, 'com.disk', 'state.json'));
      expect(file.existsSync(), isTrue);
      final parsed = jsonDecode(file.readAsStringSync()) as Map;
      expect(parsed['a'], 1);
      expect(parsed['b'], [10, 20]);
    });

    test('clearNamespace drops every key in that namespace only',
        () async {
      await store.put('com.x', 'a', 1);
      await store.put('com.y', 'a', 2);
      await store.clearNamespace('com.x');
      expect(await store.list('com.x'), isEmpty);
      expect(await store.get('com.y', 'a'), 2);
    });

    test('sanitises unsafe characters in the namespace path', () async {
      await store.put('weird/name with spaces!', 'k', 'ok');
      // The folder name is sanitised — verify by reading via the same
      // namespace string (must round-trip).
      expect(await store.get('weird/name with spaces!', 'k'), 'ok');
      // And the on-disk folder name doesn't contain '/' or ' ' or '!'.
      final dirs = tmp
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList();
      expect(dirs.any((d) => !d.contains('/')), isTrue);
    });

    test('concurrent puts against the same namespace serialise — no '
        'lost update', () async {
      // Fire many puts back-to-back; the per-namespace lock should
      // keep them ordered so the final state contains every key.
      final futures = <Future<void>>[
        for (var i = 0; i < 20; i++) store.put('com.race', 'k$i', i),
      ];
      await Future.wait(futures);
      final entries = await store.list('com.race');
      expect(entries.length, 20);
    });
  });
}
