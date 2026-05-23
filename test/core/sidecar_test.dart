import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('kb_sidecar_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('Prefs', () {
    test('returns defaults when prefs.json is missing', () async {
      final prefs = await Prefs.load(tmp.path);
      expect(prefs.snapshot.focusedCategory, isNull);
      expect(prefs.snapshot.chatVisible, isTrue);
      expect(prefs.snapshot.previewState, isEmpty);
    });

    test('save then load round-trips snapshot', () async {
      final prefs = await Prefs.load(tmp.path);
      prefs.update(const PrefsSnapshot(
        focusedCategory: AssetCategory.skill,
        selectedAssetId: 'sk-1',
        chatVisible: false,
        previewState: {'topK': 7},
        lastQuery: 'binding',
      ));
      await prefs.save();

      final reload = await Prefs.load(tmp.path);
      expect(reload.snapshot.focusedCategory, AssetCategory.skill);
      expect(reload.snapshot.selectedAssetId, 'sk-1');
      expect(reload.snapshot.chatVisible, isFalse);
      expect(reload.snapshot.previewState['topK'], 7);
      expect(reload.snapshot.lastQuery, 'binding');
    });

    test('corrupt prefs.json falls back to defaults', () async {
      await File(p.join(tmp.path, 'prefs.json'))
          .writeAsString('not json');
      final prefs = await Prefs.load(tmp.path);
      expect(prefs.snapshot.focusedCategory, isNull);
      expect(prefs.snapshot.chatVisible, isTrue);
    });
  });

  group('ChatLog', () {
    test('append + readAll + clear', () async {
      final log = ChatLog.attach(tmp.path);
      expect(await log.readAll(), isEmpty);

      await log.append(ChatTurn(
        id: 't1',
        role: ChatRole.user,
        text: 'hello',
        ts: DateTime.utc(2026, 5, 5, 10),
      ));
      await log.append(ChatTurn(
        id: 't2',
        role: ChatRole.assistant,
        text: 'hi',
        ts: DateTime.utc(2026, 5, 5, 10, 0, 1),
      ));

      final all = await log.readAll();
      expect(all, hasLength(2));
      expect(all.first.role, ChatRole.user);
      expect(all.last.text, 'hi');

      await log.clear();
      expect(await log.readAll(), isEmpty);
    });

    test('skips a corrupt line and preserves the rest', () async {
      final file = File(p.join(tmp.path, 'chat.jsonl'));
      await file.writeAsString(
        [
          '{"id":"t1","role":"user","text":"a","ts":"2026-05-05T10:00:00Z"}',
          'corrupt-line',
          '{"id":"t2","role":"assistant","text":"b","ts":"2026-05-05T10:00:01Z"}',
        ].join('\n'),
      );
      final log = ChatLog.attach(tmp.path);
      final all = await log.readAll();
      expect(all.map((t) => t.id), ['t1', 't2']);
    });
  });

  group('HistoryLog', () {
    test('records canonical patch events but not open / revert',
        () async {
      final mbd = p.join(tmp.path, 'app.mbd');
      await McpBundleWriter.writeDirectory(
        McpBundle(
          manifest: BundleManifest(id: 't', name: 'T', version: '0.0.0'),
        ),
        mbd,
      );
      final canonical =
          await Canonical.openAt(mbd, draftPath: '$mbd.draft');

      final log = HistoryLog.attach(tmp.path);
      log.subscribe(canonical);

      await canonical.applyAtomicBundle(
        McpBundle(
          manifest: BundleManifest(
              id: 't', name: 'Renamed', version: '0.0.0'),
        ),
        changedPointers: const ['/manifest/name'],
        originator: const UserOriginator(note: 'rename'),
      );

      // open / revert events should NOT be recorded.
      await canonical.revert();

      // Allow any pending stream events to flush.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final entries = await log.readAll();
      expect(entries, hasLength(1));
      expect(entries.single.kind, 'patch');
      expect(entries.single.changedPaths, ['/manifest/name']);
      expect(entries.single.originator?['kind'], 'user');
      expect(entries.single.originator?['note'], 'rename');

      await log.dispose();
      await canonical.dispose();
    });
  });

  group('Project sidecar integration', () {
    test('newAt initialises empty sidecars + open rehydrates', () async {
      final path = p.join(tmp.path, 'P.kbproj');
      final project = await Project.newAt(path);
      await project.chatLog.append(ChatTurn(
        id: 't1',
        role: ChatRole.user,
        text: 'note',
        ts: DateTime.utc(2026, 5, 5),
      ));
      project.prefs.update(const PrefsSnapshot(
        focusedCategory: AssetCategory.philosophy,
      ));
      await project.prefs.save();
      await project.close();

      final reopened = await Project.openAt(path);
      expect(reopened.prefs.snapshot.focusedCategory,
          AssetCategory.philosophy);
      expect((await reopened.chatLog.readAll()).single.text, 'note');
      await reopened.close();
    });

    test('saveAs duplicates sidecars and rebinds historyLog', () async {
      final path = p.join(tmp.path, 'A.kbproj');
      final newPath = p.join(tmp.path, 'B.kbproj');
      final project = await Project.newAt(path);

      await project.chatLog.append(ChatTurn(
        id: 't1',
        role: ChatRole.user,
        text: 'before',
        ts: DateTime.utc(2026, 5, 5),
      ));

      await project.canonical.applyAtomicBundle(
        McpBundle(
          manifest: BundleManifest(
              id: 'a', name: 'A2', version: '0.0.0'),
        ),
        changedPointers: const ['/manifest/name'],
        originator: const UserOriginator(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await project.saveAs(newPath);

      // Sidecars copied over to new path.
      expect(File(p.join(newPath, 'chat.jsonl')).existsSync(), isTrue);
      expect(File(p.join(newPath, 'history.jsonl')).existsSync(), isTrue);
      expect((await project.chatLog.readAll()).single.text, 'before');

      // historyLog now writes to the new path. Trigger another patch
      // and confirm the entry lands under the new directory.
      await project.canonical.applyAtomicBundle(
        McpBundle(
          manifest: BundleManifest(
              id: 'a', name: 'A3', version: '0.0.0'),
        ),
        changedPointers: const ['/manifest/name'],
        originator: const UserOriginator(note: 'after-saveAs'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final entries = await project.historyLog.readAll();
      expect(entries, hasLength(2));
      expect(entries.last.originator?['note'], 'after-saveAs');
      expect(project.historyLog.path,
          p.join(newPath, 'history.jsonl'));

      await project.close();
    });
  });
}
