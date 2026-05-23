/// Auto-sync helper — derives per-asset touch events from a [Canonical]'s
/// change stream. UI hosts (vibe_studio_base / vibe builders) subscribe to
/// drive automatic mode/category swap and highlight scrolling whenever an
/// external or internal LLM mutates an asset via MCP tools.
///
/// Headless: pure `dart:async` Stream surface. No Flutter dependency.
library;

import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';

import '../core/asset_category_map.dart';
import '../core/canonical.dart';
import '../core/types.dart';

/// One asset touch — derived from a single pointer in a
/// [CanonicalChange.changedPointers] list.
class AssetTouch {
  const AssetTouch({
    required this.category,
    required this.id,
    required this.pointer,
    required this.kind,
    required this.timestamp,
  });

  /// Category that the touched pointer falls under.
  final AssetCategory category;

  /// Resolved asset id when extractable from the pointer + current bundle,
  /// else `null` (e.g. RFC 6902 `add` to `-` with empty list, or pointer
  /// landing on a section root rather than a specific asset).
  final String? id;

  /// The raw JSON pointer that produced this touch.
  final String pointer;

  /// The originating change kind. Defaults exclude open/saveAs/revert.
  final CanonicalChangeKind kind;

  /// Timestamp inherited from the [CanonicalChange].
  final DateTime timestamp;

  @override
  String toString() =>
      'AssetTouch(${category.name}/${id ?? '?'} @ $pointer · ${kind.name})';
}

/// Subscribes to a [Canonical] and emits one [AssetTouch] per pointer that
/// can be resolved to a known asset category. Hosts wire this to UI to
/// auto-swap mode/category and scroll-into-view.
///
/// Default behaviour ignores `open` / `saveAs` / `revert` (bulk events that
/// would otherwise spam mode swaps); set `patchOnly: false` to receive all
/// kinds.
class AssetTouchObserver {
  AssetTouchObserver({
    required this.canonical,
    this.patchOnly = true,
  }) {
    _subscription = canonical.changes.listen(_onChange);
  }

  final Canonical canonical;
  final bool patchOnly;

  late final StreamSubscription<CanonicalChange> _subscription;
  final StreamController<AssetTouch> _controller =
      StreamController<AssetTouch>.broadcast();
  AssetTouch? _last;
  bool _disposed = false;

  /// Broadcast stream of touches. Multiple listeners allowed.
  Stream<AssetTouch> get touches => _controller.stream;

  /// Most recent touch, or `null` before any patch has landed. Useful for
  /// late subscribers that want to read the current sync target without
  /// waiting for the next event.
  AssetTouch? get last => _last;

  void _onChange(CanonicalChange change) {
    if (patchOnly && change.kind != CanonicalChangeKind.patch) return;
    for (final pointer in change.changedPointers) {
      final touch = _resolve(pointer, change);
      if (touch != null) {
        _last = touch;
        _controller.add(touch);
      }
    }
  }

  AssetTouch? _resolve(String pointer, CanonicalChange change) {
    // Match by sectionKey root (`/skills`, `/agents`, ...) so we catch
    // both the deep-pointer case (`/skills/modules/0/name`) and the
    // section-init case (`/skills` when the entire section gets
    // provisioned in one op). The list-root prefix (`jsonPointerPrefix`,
    // e.g. `/skills/modules`) is used afterward for index extraction.
    AssetCategoryDescriptor? best;
    for (final desc in AssetCategoryMap.all) {
      final sectionRoot = '/${desc.sectionKey}';
      if (pointer == sectionRoot || pointer.startsWith('$sectionRoot/')) {
        if (best == null ||
            desc.sectionKey.length > best.sectionKey.length) {
          best = desc;
        }
      }
    }
    if (best == null) return null;
    return AssetTouch(
      category: best.category,
      id: _resolveId(canonical.bundle, best, pointer),
      pointer: pointer,
      kind: change.kind,
      timestamp: change.timestamp,
    );
  }

  String? _resolveId(
    McpBundle bundle,
    AssetCategoryDescriptor desc,
    String pointer,
  ) {
    // Section-init add (`add /skills` with the whole subtree): the
    // section was empty before, so the only asset present after the
    // patch is the new one — return its id.
    if (pointer == '/${desc.sectionKey}') {
      final ids = AssetCategoryMap.currentIds(bundle, desc.category);
      return ids.isNotEmpty ? ids.first : null;
    }

    // Otherwise the pointer must drill into the asset list root
    // (`/skills/modules/...`). Anything else (e.g. `/skills/something`)
    // is not asset-addressable.
    if (!pointer.startsWith('${desc.jsonPointerPrefix}/')) return null;
    final remainder = pointer.substring(desc.jsonPointerPrefix.length);
    final parts = remainder.substring(1).split('/');
    if (parts.isEmpty) return null;

    switch (desc.category) {
      case AssetCategory.skill:
        return _atIndex(bundle.skills?.modules, parts[0], (m) => m.id);
      case AssetCategory.profile:
        return _atIndex(bundle.profiles?.profiles, parts[0], (p) => p.id);
      case AssetCategory.philosophy:
        return _atIndex(
          bundle.philosophy?.philosophies,
          parts[0],
          (p) => p.id,
        );
      case AssetCategory.agent:
        return _atIndex(bundle.agents?.agents, parts[0], (a) => a.id);
      case AssetCategory.fact:
        // /factGraphSection/embedded/facts/<N>
        if (parts.length < 2 || parts[0] != 'facts') return null;
        return _atIndex(
          bundle.factGraphSection?.embedded?.facts,
          parts[1],
          (f) => f.id,
        );
      case AssetCategory.chunks:
        // /knowledge/sources/<S>/documents/<D>
        if (parts.length < 3 || parts[1] != 'documents') return null;
        final sources = bundle.knowledge?.sources;
        if (sources == null) return null;
        final s = int.tryParse(parts[0]);
        if (s == null || s < 0 || s >= sources.length) return null;
        final docs = sources[s].documents ?? const <KnowledgeDocument>[];
        final d = _resolveTailIndex(parts[2], docs.length);
        if (d == null || d < 0 || d >= docs.length) return null;
        return docs[d].id;
    }
  }

  String? _atIndex<T>(
    List<T>? list,
    String token,
    String Function(T) idOf,
  ) {
    if (list == null || list.isEmpty) return null;
    final i = _resolveTailIndex(token, list.length);
    if (i == null || i < 0 || i >= list.length) return null;
    return idOf(list[i]);
  }

  /// RFC 6902 array tokens. Numeric → that index. `-` (append target) →
  /// the last element after the patch was applied.
  int? _resolveTailIndex(String token, int? listLength) {
    if (token == '-') {
      if (listLength == null || listLength == 0) return null;
      return listLength - 1;
    }
    return int.tryParse(token);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await _controller.close();
  }
}
