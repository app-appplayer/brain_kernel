/// Append-only chat log sidecar (`<kbproj>/chat.jsonl`).
///
/// Stores one [ChatTurn] per line as JSON. Survives a host crash mid-write
/// because each line is committed independently — corrupt or partial
/// trailing lines are silently skipped on read (DDD-15 §2).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../types.dart';

class ChatLog {
  ChatLog._(this._path);

  /// Bind to `<projectPath>/chat.jsonl`. Does not read the file — call
  /// [readAll] when rehydrating a session. Used for the legacy / global
  /// pre-agent-scoping log; new code should prefer [attachAgent].
  static ChatLog attach(String projectPath) {
    return ChatLog._(p.join(projectPath, 'chat.jsonl'));
  }

  /// Bind to `<projectPath>/chat/<agentId>.jsonl` — the agent-scoped log
  /// path defined by FR-CHT-002. The directory is created lazily on first
  /// `append`.
  static ChatLog attachAgent(String projectPath, String agentId) {
    return ChatLog._(p.join(projectPath, 'chat', '$agentId.jsonl'));
  }

  final String _path;

  /// Path to the underlying file (absolute). Useful for [copyTo].
  String get path => _path;

  /// Read every line, decode it as a [ChatTurn], and return the list in
  /// file order. Corrupt lines (invalid JSON or wrong shape) are skipped
  /// rather than throwing.
  Future<List<ChatTurn>> readAll() async {
    final file = File(_path);
    if (!await file.exists()) return const [];
    final raw = await file.readAsString();
    final out = <ChatTurn>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          out.add(ChatTurn.fromJson(decoded));
        }
      } catch (_) {
        // Skip — partial / corrupt line.
      }
    }
    return out;
  }

  /// Append a single turn. IO failures are swallowed — UX over
  /// persistence guarantees (NFR-PERSIST-003).
  Future<void> append(ChatTurn turn) async {
    try {
      final file = File(_path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '${jsonEncode(turn.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Non-fatal — see NFR-PERSIST-003.
    }
  }

  /// Truncate the log file. Used when the user explicitly clears chat.
  Future<void> clear() async {
    final file = File(_path);
    if (await file.exists()) {
      await file.writeAsString('', flush: true);
    }
  }

  /// Copy chat log to the destination project (used by SaveAs). The path
  /// shape is preserved relative to the project root, so an agent-scoped
  /// log lands at `<dest>/chat/<agentId>.jsonl` and a global log lands at
  /// `<dest>/chat.jsonl`.
  Future<void> copyTo(String destProjectPath) async {
    final src = File(_path);
    if (!await src.exists()) return;
    final relParts = <String>[];
    final dir = p.basename(p.dirname(_path));
    if (dir == 'chat') {
      relParts
        ..add('chat')
        ..add(p.basename(_path));
    } else {
      relParts.add(p.basename(_path));
    }
    final destFile = File(p.joinAll(<String>[destProjectPath, ...relParts]));
    await destFile.parent.create(recursive: true);
    await src.copy(destFile.path);
  }
}
