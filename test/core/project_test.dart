import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_project_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('newAt creates project.json + sources/ + empty app.mbd/', () async {
    final path = p.join(tmp.path, 'My.kbproj');
    final project = await Project.newAt(path, name: 'My');
    expect(File(p.join(path, 'project.json')).existsSync(), isTrue);
    expect(Directory(p.join(path, 'sources')).existsSync(), isTrue);
    expect(Directory(p.join(path, 'app.mbd')).existsSync(), isTrue);
    expect(project.meta.name, 'My');
    expect(project.canonical.bundle.manifest.id, 'my');
    await project.close();
  });

  test('save commits canonical to app.mbd and updates lastSavedAt',
      () async {
    final path = p.join(tmp.path, 'My.kbproj');
    final project = await Project.newAt(path);

    await project.canonical.applyAtomicBundle(
      McpBundle(
        manifest: BundleManifest(
          id: 'my',
          name: 'Renamed',
          version: '0.0.0',
        ),
      ),
      changedPointers: const ['/manifest/name'],
    );
    await project.save();
    expect(project.meta.lastSavedAt, isNotNull);

    final reloaded = await McpBundleLoader.loadDirectory(
      p.join(path, 'app.mbd'),
    );
    expect(reloaded.manifest.name, 'Renamed');
    await project.close();
  });

  test('saveAs duplicates the project to a new path', () async {
    final path = p.join(tmp.path, 'Original.kbproj');
    final newPath = p.join(tmp.path, 'Copy.kbproj');
    final project = await Project.newAt(path);
    await project.saveAs(newPath);

    expect(File(p.join(newPath, 'project.json')).existsSync(), isTrue);
    expect(Directory(p.join(newPath, 'app.mbd')).existsSync(), isTrue);
    expect(File(p.join(path, 'project.json')).existsSync(), isTrue,
        reason: 'original should remain');
    await project.close();
  });

  test('openAt rehydrates an existing .kbproj', () async {
    final path = p.join(tmp.path, 'Reopen.kbproj');
    final created = await Project.newAt(path, name: 'Reopen');
    await created.close();

    final reopened = await Project.openAt(path);
    expect(reopened.meta.name, 'Reopen');
    expect(reopened.canonical.bundle.manifest.id, 'reopen');
    await reopened.close();
  });

  test('revert discards uncommitted changes', () async {
    final path = p.join(tmp.path, 'Revert.kbproj');
    final project = await Project.newAt(path, name: 'Original');
    await project.canonical.applyAtomicBundle(
      McpBundle(
        manifest: BundleManifest(
          id: 'original',
          name: 'Tweaked',
          version: '0.0.0',
        ),
      ),
      changedPointers: const ['/manifest/name'],
    );
    await project.revert();
    expect(project.canonical.bundle.manifest.name, 'Original');
    expect(project.canonical.isDirty, isFalse);
    await project.close();
  });
}
