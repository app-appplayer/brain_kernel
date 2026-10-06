import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

/// A browser has no filesystem: `File` and `Directory` throw
/// `Unsupported operation`. Booting with no registry directory must never
/// reach them — not at boot, and not on the first knowledge query, which
/// used to load the registry lazily from `.`.
void main() {
  /// Runs [body] where touching the filesystem throws, as on the web.
  Future<T> withoutFilesystem<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(
        body,
        createFile: (path) =>
            throw UnsupportedError('no filesystem (File $path)'),
        createDirectory: (path) =>
            throw UnsupportedError('no filesystem (Directory $path)'),
      );

  test('boot and a knowledge query need no filesystem without a directory',
      () async {
    final hits = await withoutFilesystem(() async {
      final app = await KernelApp.boot(
        workspaceId: 'ws',
        kvStorage: InMemoryKvStoragePort(),
      );
      addTearDown(app.shutdown);
      await app.bundleRegistry.upsert(mbdPath: 'mem://a', namespace: 'a');
      expect((await app.bundleRegistry.list()).single.namespace, 'a');
      return app.queryEngine.query('anything');
    });
    expect(hits, isEmpty);
  });

  test('with a directory the registry does use the filesystem', () async {
    // The override bites: the same boot with a directory reaches `File`.
    await expectLater(
      withoutFilesystem(() => KernelApp.boot(
            workspaceId: 'ws',
            kvStorage: InMemoryKvStoragePort(),
            bundleRegistryStorageDir: '/bundles',
          )),
      throwsUnsupportedError,
    );
  });
}
