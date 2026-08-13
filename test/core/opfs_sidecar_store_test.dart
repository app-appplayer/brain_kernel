/// The browser storage adapter, run against a real origin-private file system.
///
/// Compiling it proves nothing about whether it works — OPFS only exists at
/// run time, in a browser, in a secure context. So this runs there.
@TestOn('browser')
library;

import 'package:brain_kernel/src/core/sidecar/store/opfs_sidecar_store.dart';
import 'package:test/test.dart';

void main() {
  late OpfsSidecarStore store;
  var account = 0;

  setUp(() {
    // A fresh account per test — OPFS outlives a test case, and a shared root
    // would let one test read what another wrote.
    store = OpfsSidecarStore.forAccount('test-${account++}');
  });

  tearDown(() => store.wipe());

  test('a record that was never written reads as absent', () async {
    expect(await store.read('proj/.kbproj/prefs.json'), isNull);
    expect(await store.exists('proj/.kbproj/prefs.json'), isFalse);
  });

  test('what is written comes back', () async {
    await store.write('proj/.kbproj/prefs.json', '{"theme":"dark"}');

    expect(await store.read('proj/.kbproj/prefs.json'), '{"theme":"dark"}');
    expect(await store.exists('proj/.kbproj/prefs.json'), isTrue);
  });

  test('writing again replaces rather than accumulates', () async {
    await store.write('p/x.json', 'first-and-longer');
    await store.write('p/x.json', 'second');

    expect(await store.read('p/x.json'), 'second');
  });

  test('append adds to the end and keeps what was there', () async {
    await store.append('p/history.log', 'one\n');
    await store.append('p/history.log', 'two\n');
    await store.append('p/history.log', 'three\n');

    expect(await store.read('p/history.log'), 'one\ntwo\nthree\n');
  });

  test('append to an absent record starts it', () async {
    await store.append('p/chat.log', 'first line\n');

    expect(await store.read('p/chat.log'), 'first line\n');
  });

  test('append survives a record written whole first', () async {
    // The undo log rewrites its head and appends entries; both paths touch
    // the same record, so the offset has to follow the write.
    await store.write('p/undo.log', 'head\n');
    await store.append('p/undo.log', 'entry\n');

    expect(await store.read('p/undo.log'), 'head\nentry\n');
  });

  test('remove takes it away, and removing again is a no-op', () async {
    await store.write('p/x.json', 'v');
    await store.remove('p/x.json');

    expect(await store.exists('p/x.json'), isFalse);
    await store.remove('p/x.json');
    await store.remove('never/written.json');
  });

  test('copy duplicates, and copying an absent record does nothing', () async {
    await store.write('p/a.json', 'body');
    await store.copy('p/a.json', 'p/b.json');

    expect(await store.read('p/b.json'), 'body');

    await store.copy('p/missing.json', 'p/c.json');
    expect(await store.exists('p/c.json'), isFalse);
  });

  test('copy overwrites the destination', () async {
    await store.write('p/a.json', 'new');
    await store.write('p/b.json', 'old-and-longer');
    await store.copy('p/a.json', 'p/b.json');

    expect(await store.read('p/b.json'), 'new');
  });

  test('nested paths are directories, not flattened keys', () async {
    await store.write('a/b/c/deep.json', 'deep');
    await store.write('a/b/other.json', 'other');

    expect(await store.read('a/b/c/deep.json'), 'deep');
    expect(await store.read('a/b/other.json'), 'other');
  });

  test('a leading separator does not escape the account root', () async {
    await store.write('/p/x.json', 'v');

    expect(await store.read('p/x.json'), 'v');
  });

  group('what one account cannot reach', () {
    test('another account does not see it', () async {
      final other = OpfsSidecarStore.forAccount('test-other');
      addTearDown(other.wipe);

      await store.write('p/x.json', 'mine');

      expect(await other.read('p/x.json'), isNull);
    });

    test('wipe leaves nothing for the next person', () async {
      final person = OpfsSidecarStore.forAccount('test-shared-browser');
      await person.write('p/x.json', 'theirs');
      await person.append('p/chat.log', 'a line\n');
      await person.wipe();

      final next = OpfsSidecarStore.forAccount('test-shared-browser');
      expect(await next.read('p/x.json'), isNull);
      expect(await next.read('p/chat.log'), isNull);
    });

    test('a ref that climbs out is refused, not followed', () async {
      await expectLater(
        store.write('../elsewhere/x.json', 'v'),
        throwsArgumentError,
      );
      await expectLater(store.read('p/../../x.json'), throwsArgumentError);
    });
  });

  group('an account key that is not one segment', () {
    for (final bad in <String>['', '/', 'a/b', r'a\b', '.', '..']) {
      test('${bad.isEmpty ? '(empty)' : bad} is refused', () {
        expect(() => OpfsSidecarStore.forAccount(bad), throwsArgumentError);
      });
    }
  });
}
