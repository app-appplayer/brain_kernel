/// MOD-RUNTIME-001 — file-backed `mcp_bundle.KvStoragePort`.
///
/// Same shape as the vibe KV adapter (`tools/builder/app_builder/
/// lib/src/infra/kv_storage_port_adapter.dart`) — atomic temp+rename
/// writes, prefix-scoped key listing, JSON value encoding. Knowledge
/// builder owns one instance under `<rootDir>` (typically a build
/// scratch directory or `~/.config/knowledge_builder/`) for any
/// FlowBrain ConversationStore / 4-axis state the future bundling
/// agent might persist.
///
/// Kept independent of vibe so the two tools' KV trees never collide.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;

class KvStoragePortAdapter implements mb.KvStoragePort {
  KvStoragePortAdapter({required this.rootDir});

  final String rootDir;

  String _filePathFor(String key) {
    final clean = key.replaceAll(RegExp(r'^/+'), '');
    return p.join(rootDir, '$clean.json');
  }

  @override
  Future<void> set(String key, dynamic value) async {
    final file = File(_filePathFor(key));
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<dynamic> get(String key) async {
    final file = File(_filePathFor(key));
    if (!await file.exists()) return null;
    try {
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> remove(String key) async {
    final file = File(_filePathFor(key));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> exists(String key) async {
    return File(_filePathFor(key)).exists();
  }

  @override
  Future<List<String>> keys({String? prefix}) async {
    final base = prefix == null || prefix.isEmpty
        ? Directory(rootDir)
        : Directory(p.join(rootDir, prefix));
    if (!await base.exists()) return const <String>[];
    final out = <String>[];
    await for (final entity
        in base.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      final rel = p
          .relative(entity.path, from: rootDir)
          .replaceAll(RegExp(r'\.json$'), '');
      out.add(rel.replaceAll(p.separator, '/'));
    }
    out.sort();
    return out;
  }

  @override
  Future<void> clear() async {
    final base = Directory(rootDir);
    if (!await base.exists()) return;
    await for (final entity in base.list(followLinks: false)) {
      try {
        if (entity is File) {
          await entity.delete();
        } else if (entity is Directory) {
          await entity.delete(recursive: true);
        }
      } catch (_) {/* best effort */}
    }
  }
}
