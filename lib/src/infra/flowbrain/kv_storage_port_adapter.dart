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
///
/// Optional workspace-scope enforcement: when [workspaceId] is non-null,
/// keys beginning with `ws/` must begin with `ws/<workspaceId>/`
/// (anything else throws); keys without the `ws/` prefix are treated as
/// global and bypass the check. When [workspaceId] is null (default) no
/// enforcement happens — the plain file-KV behaviour. This lets a host
/// adopt the single canonical file KV (replacing bespoke per-tool
/// adapters) while preserving per-workspace isolation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:path/path.dart' as p;

class KvStoragePortAdapter implements mb.KvStoragePort {
  KvStoragePortAdapter({required this.rootDir, String? workspaceId})
      : _workspaceId = workspaceId;

  final String rootDir;

  /// Active workspace id for scope enforcement; null disables it.
  /// Mutable so a host can re-point the same adapter on workspace switch.
  String? _workspaceId;

  String? get workspaceId => _workspaceId;
  set workspaceId(String? value) => _workspaceId = value;

  String _filePathFor(String key) {
    final clean = key.replaceAll(RegExp(r'^/+'), '');
    return p.join(rootDir, '$clean.json');
  }

  /// Throws [ArgumentError] when [key] targets a different workspace than
  /// the active [workspaceId]. No-op when enforcement is disabled or the
  /// key is global (no `ws/` prefix).
  void _assertScope(String key) {
    final ws = _workspaceId;
    if (ws == null) return;
    if (!key.startsWith('ws/')) return; // global keys allowed
    final required = 'ws/$ws/';
    if (!key.startsWith(required)) {
      throw ArgumentError(
        'workspace scope violation: $key (active=$ws)',
      );
    }
  }

  /// `jsonEncode` fallback for non-JSON-native values (e.g. flowbrain
  /// envelopes). Duck-typed `toJson()` first; otherwise `toString()` so a
  /// write never fails on an opaque value (lossy round-trip accepted).
  Object? _encodeFallback(Object? value) {
    try {
      return (value as dynamic).toJson();
    } catch (_) {
      return value?.toString();
    }
  }

  @override
  Future<void> set(String key, dynamic value) async {
    _assertScope(key);
    final file = File(_filePathFor(key));
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode(value, toEncodable: _encodeFallback),
        flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<dynamic> get(String key) async {
    _assertScope(key);
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
    _assertScope(key);
    final file = File(_filePathFor(key));
    if (await file.exists()) await file.delete();
  }

  @override
  Future<bool> exists(String key) async {
    _assertScope(key);
    return File(_filePathFor(key)).exists();
  }

  @override
  Future<List<String>> keys({String? prefix}) async {
    final base = Directory(rootDir);
    if (!await base.exists()) return const <String>[];
    final hasPrefix = prefix != null && prefix.isNotEmpty;
    final out = <String>[];
    await for (final entity
        in base.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      final rel = p
          .relative(entity.path, from: rootDir)
          .replaceAll(RegExp(r'\.json$'), '');
      final key = rel.replaceAll(p.separator, '/');
      // String-prefix contract (matches the in-memory reference
      // KvStoragePort: `k.startsWith(prefix)`). The prefix must NOT be
      // treated as a directory: a directory-scoped walk drops flat
      // colon-namespaced keys (e.g. `philosophy.ethos:<id>`, stored as a
      // single file) whose prefix is not a real subdirectory, and it also
      // misses partial-segment prefixes. Hierarchical slash-namespaced
      // keys still match because reconstructed keys use `/` separators.
      if (hasPrefix && !key.startsWith(prefix)) continue;
      out.add(key);
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
