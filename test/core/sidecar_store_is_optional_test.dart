/// A caller that names no store still works, exactly as before the port.
///
/// The store is what makes the sidecars runnable off a filesystem, but it is
/// an addition: code written against the kernel before the port existed calls
/// these four with a path and nothing else. Requiring the argument would break
/// every one of those calls for a capability they do not use, and the sibling
/// decision — `Canonical.openAt` — already takes its port as optional.
@TestOn('vm')
library;

import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sidecar_default_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('Prefs.load with no store reads and writes the filesystem', () async {
    final prefs = await Prefs.load(tmp.path);
    prefs.update(const PrefsSnapshot(selectedAssetId: 'a1'));
    await prefs.save();

    expect(File(p.join(tmp.path, 'prefs.json')).existsSync(), isTrue);
    expect((await Prefs.load(tmp.path)).snapshot.selectedAssetId, 'a1');
  });

  test('ChatLog.attach with no store appends to disk', () async {
    final log = ChatLog.attach(tmp.path);
    await log.append(
      ChatTurn(
        id: 't1',
        role: ChatRole.user,
        text: 'hello',
        ts: DateTime.utc(2026),
      ),
    );

    expect((await log.readAll()).single.text, 'hello');
    expect(File(p.join(tmp.path, 'chat.jsonl')).existsSync(), isTrue);
  });

  test('ChatLog.attachAgent with no store keeps the agent path', () async {
    final log = ChatLog.attachAgent(tmp.path, 'sara');
    await log.append(
      ChatTurn(
        id: 't2',
        role: ChatRole.user,
        text: 'hi',
        ts: DateTime.utc(2026),
      ),
    );

    expect(log.path, p.join(tmp.path, 'chat', 'sara.jsonl'));
    expect(File(log.path).existsSync(), isTrue);
  });

  test('UndoLog.attach with no store round-trips a snapshot', () async {
    final log = UndoLog.attach(tmp.path);
    await log.save(const UndoSnapshot(undoFrames: [], redoFrames: []));

    expect(await log.read(), isNotNull);
    expect(File(p.join(tmp.path, 'undo.json')).existsSync(), isTrue);
  });

  test('HistoryLog.attach with no store binds the project path', () {
    expect(HistoryLog.attach(tmp.path).path, p.join(tmp.path, 'history.jsonl'));
  });

  test('an explicit store still wins over the default', () async {
    final log = ChatLog.attach(tmp.path, store: const FileSidecarStore());
    await log.append(
      ChatTurn(
        id: 't3',
        role: ChatRole.assistant,
        text: 'from a store',
        ts: DateTime.utc(2026),
      ),
    );

    expect((await log.readAll()).single.text, 'from a store');
  });
}
