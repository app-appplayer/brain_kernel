import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

McpBundle _emptyBundle({String id = 'test', String name = 'Test'}) {
  return McpBundle(
    manifest: BundleManifest(id: id, name: name, version: '0.0.0'),
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_canonical_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('openAt loads committed bundle when no draft exists', () async {
    final mbd = p.join(tmp.path, 'app.mbd');
    await McpBundleWriter.writeDirectory(_emptyBundle(), mbd);

    final canonical = await Canonical.openAt(
      mbd,
      draftPath: '$mbd.draft',
    );
    expect(canonical.isDirty, isFalse);
    expect(canonical.hasRestoredDraft, isFalse);
    expect(canonical.bundle.manifest.id, 'test');
    await canonical.dispose();
  });

  test('applyAtomic mirrors to draft and marks dirty', () async {
    final mbd = p.join(tmp.path, 'app.mbd');
    await McpBundleWriter.writeDirectory(_emptyBundle(), mbd);
    final canonical = await Canonical.openAt(
      mbd,
      draftPath: '$mbd.draft',
    );

    await canonical.applyAtomicBundle(
      _emptyBundle(name: 'Renamed'),
      changedPointers: const ['/manifest/name'],
    );

    expect(canonical.isDirty, isTrue);
    expect(canonical.dirtyPointers, contains('/manifest/name'));
    expect(await Directory('$mbd.draft').exists(), isTrue);
    expect(canonical.bundle.manifest.name, 'Renamed');
    await canonical.dispose();
  });

  test('commit writes to disk and purges draft', () async {
    final mbd = p.join(tmp.path, 'app.mbd');
    await McpBundleWriter.writeDirectory(_emptyBundle(), mbd);
    final canonical = await Canonical.openAt(
      mbd,
      draftPath: '$mbd.draft',
    );
    await canonical.applyAtomicBundle(
      _emptyBundle(name: 'Renamed'),
      changedPointers: const ['/manifest/name'],
    );
    await canonical.commit();
    expect(canonical.isDirty, isFalse);
    expect(await Directory('$mbd.draft').exists(), isFalse);

    final reloaded = await McpBundleLoader.loadDirectory(mbd);
    expect(reloaded.manifest.name, 'Renamed');
    await canonical.dispose();
  });

  test('open after applyAtomic without commit restores draft', () async {
    final mbd = p.join(tmp.path, 'app.mbd');
    await McpBundleWriter.writeDirectory(_emptyBundle(), mbd);
    final first = await Canonical.openAt(
      mbd,
      draftPath: '$mbd.draft',
    );
    await first.applyAtomicBundle(
      _emptyBundle(name: 'Drafted'),
      changedPointers: const ['/manifest/name'],
    );
    await first.dispose();

    final second = await Canonical.openAt(
      mbd,
      draftPath: '$mbd.draft',
    );
    expect(second.hasRestoredDraft, isTrue);
    expect(second.bundle.manifest.name, 'Drafted');
    await second.dispose();
  });

  test('revert reloads committed and clears dirty', () async {
    final mbd = p.join(tmp.path, 'app.mbd');
    await McpBundleWriter.writeDirectory(_emptyBundle(), mbd);
    final canonical = await Canonical.openAt(
      mbd,
      draftPath: '$mbd.draft',
    );
    await canonical.applyAtomicBundle(
      _emptyBundle(name: 'Drafted'),
      changedPointers: const ['/manifest/name'],
    );
    await canonical.revert();
    expect(canonical.isDirty, isFalse);
    expect(canonical.bundle.manifest.name, 'Test');
    expect(await Directory('$mbd.draft').exists(), isFalse);
    await canonical.dispose();
  });
}
