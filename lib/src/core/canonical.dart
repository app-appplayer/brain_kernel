/// In-memory representation of a `.kbproj/app.mbd/` plus its draft mirror.
///
/// Implements MOD-CORE-002 (SDD §2.1 / DDD-03). Holds the bundle as a raw
/// JSON map (the authoritative form — round-trips reserved-folder
/// content) and exposes a typed [McpBundle] projection on demand. All
/// disk I/O routes through a [CanonicalStoragePort]; the default
/// `ManifestOnlyCanonicalStorage` matches the kernel's previous direct
/// `McpBundleWriter` behaviour, while domains that carry content outside
/// mcp_bundle's typed schema (e.g. vibe's `ApplicationDefinition` ui
/// content) inject their own port impl.
library;

import 'dart:async';

import 'package:mcp_bundle/mcp_bundle.dart';

import '_canonical_hash.dart';
import 'canonical_storage_port.dart';

/// Why a [CanonicalChange] was emitted.
enum CanonicalChangeKind { patch, open, saveAs, revert }

/// One change event broadcast on [Canonical.changes].
class CanonicalChange {
  const CanonicalChange({
    required this.kind,
    required this.beforeHash,
    required this.afterHash,
    required this.changedPointers,
    required this.timestamp,
    this.originator,
  });

  final CanonicalChangeKind kind;
  final String beforeHash;
  final String afterHash;
  final List<String> changedPointers;
  final DateTime timestamp;

  /// Free-form originator descriptor — `PatchPipeline` populates it from
  /// the typed `PatchOriginator` sealed class. Kept dynamic here so this
  /// module does not depend on `patch_pipeline.dart`.
  final Object? originator;
}

/// In-memory canonical with draft mirror. Single-thread (Flutter UI tick)
/// — concurrent access is queued by callers (see DDD-03 §9).
class Canonical {
  Canonical._({
    required Map<String, dynamic> bundleJson,
    required String mbdPath,
    required String draftPath,
    required bool restoredDraft,
    required CanonicalStoragePort storage,
  })  : _bundleJson = bundleJson,
        _mbdPath = mbdPath,
        _draftPath = draftPath,
        _restoredDraft = restoredDraft,
        _storage = storage;

  /// Open the canonical at [mbdPath]. When [draftPath] holds a different
  /// hash than the committed bundle the draft is loaded into memory and
  /// [hasRestoredDraft] becomes `true`.
  ///
  /// [storage] decides how `manifest.json` and any reserved folders are
  /// read off disk — defaults to the manifest-only impl that matches the
  /// kernel's prior direct `McpBundle.fromJson` behaviour.
  static Future<Canonical> openAt(
    String mbdPath, {
    required String draftPath,
    CanonicalStoragePort storage = const ManifestOnlyCanonicalStorage(),
  }) async {
    final committed = await storage.readJson(mbdPath);
    if (committed == null) {
      throw StateError('Canonical bundle not found at $mbdPath');
    }
    final committedHash = canonicalHashOfJson(committed);

    var bundleJson = committed;
    var restored = false;

    if (await storage.dirExists(draftPath)) {
      try {
        final draftJson = await storage.readJson(draftPath);
        if (draftJson != null &&
            canonicalHashOfJson(draftJson) != committedHash) {
          bundleJson = draftJson;
          restored = true;
        } else {
          await storage.deleteDir(draftPath);
        }
      } catch (_) {
        // Corrupt draft — fall back to committed, leave the dir for a
        // human to inspect rather than silently deleting.
      }
    }

    return Canonical._(
      bundleJson: bundleJson,
      mbdPath: mbdPath,
      draftPath: draftPath,
      restoredDraft: restored,
      storage: storage,
    );
  }

  final StreamController<CanonicalChange> _controller =
      StreamController<CanonicalChange>.broadcast();
  final Set<String> _dirtyPointers = <String>{};
  Map<String, dynamic> _bundleJson;
  McpBundle? _cachedBundle;
  String _mbdPath;
  String _draftPath;
  bool _restoredDraft;
  bool _disposed = false;
  final CanonicalStoragePort _storage;

  /// Typed [McpBundle] projection. May drop fields outside mcp_bundle's
  /// schema — consumers that need full fidelity should read [bundleJson]
  /// directly. Cached until the next mutation invalidates it.
  McpBundle get bundle => _cachedBundle ??= _decodeBundle(_bundleJson);

  /// Authoritative raw JSON view. Round-trips every on-disk field,
  /// including reserved-folder content the typed [bundle] projection
  /// drops. Returned as an unmodifiable view — mutations must go
  /// through [applyAtomic].
  Map<String, dynamic> get bundleJson => Map.unmodifiable(_bundleJson);

  String get bundlePath => _mbdPath;
  String get draftPath => _draftPath;
  bool get isDirty => _dirtyPointers.isNotEmpty;
  List<String> get dirtyPointers => List.unmodifiable(_dirtyPointers);
  bool get hasRestoredDraft => _restoredDraft;
  Stream<CanonicalChange> get changes => _controller.stream;

  /// Replace the in-memory bundle with [next] (raw JSON form). Marks the
  /// affected pointer list dirty, mirrors to the draft directory via the
  /// storage port, and broadcasts a `patch` change. The actual diff /
  /// inverse calculation happens upstream in `PatchPipeline` — this
  /// method is the canonical mutation primitive.
  Future<void> applyAtomic(
    Map<String, dynamic> next, {
    required List<String> changedPointers,
    Object? originator,
  }) async {
    _ensureLive();
    final beforeHash = canonicalHashOfJson(_bundleJson);
    _bundleJson = next;
    _cachedBundle = null;
    final afterHash = canonicalHashOfJson(_bundleJson);
    _dirtyPointers.addAll(changedPointers);

    try {
      await _storage.writeJson(_bundleJson, _draftPath);
    } catch (_) {
      // Draft write failure is non-fatal (NFR-PERSIST-003) — the next
      // patch retries. Dirty state is preserved either way.
    }

    _controller.add(CanonicalChange(
      kind: CanonicalChangeKind.patch,
      beforeHash: beforeHash,
      afterHash: afterHash,
      changedPointers: List.unmodifiable(changedPointers),
      timestamp: DateTime.now().toUtc(),
      originator: originator,
    ));
  }

  /// Convenience overload for callers that already hold an [McpBundle].
  /// Routes through [applyAtomic] after `next.toJson()` — domains that
  /// carry data outside mcp_bundle's typed schema should call
  /// [applyAtomic] directly with the raw JSON form to avoid loss.
  Future<void> applyAtomicBundle(
    McpBundle next, {
    required List<String> changedPointers,
    Object? originator,
  }) {
    return applyAtomic(
      next.toJson(),
      changedPointers: changedPointers,
      originator: originator,
    );
  }

  /// Write the in-memory bundle to disk via the storage port. The draft
  /// directory is purged on success.
  Future<void> commit() async {
    _ensureLive();
    final beforeHash = canonicalHashOfJson(_bundleJson);
    await _storage.writeJson(_bundleJson, _mbdPath);
    await _storage.deleteDir(_draftPath);
    _dirtyPointers.clear();
    _restoredDraft = false;
    _controller.add(CanonicalChange(
      kind: CanonicalChangeKind.patch,
      beforeHash: beforeHash,
      afterHash: beforeHash,
      changedPointers: const [],
      timestamp: DateTime.now().toUtc(),
    ));
  }

  /// Re-target the canonical to [newMbdPath] and write both the new
  /// committed directory and a fresh draft mirror beside it.
  Future<void> commitAs(String newMbdPath) async {
    _ensureLive();
    final newDraft = '$newMbdPath.draft';
    await _storage.writeJson(_bundleJson, newMbdPath);
    await _storage.writeJson(_bundleJson, newDraft);
    await _storage.deleteDir(_draftPath);
    _mbdPath = newMbdPath;
    _draftPath = newDraft;
    _dirtyPointers.clear();
    _restoredDraft = false;
    final hash = canonicalHashOfJson(_bundleJson);
    _controller.add(CanonicalChange(
      kind: CanonicalChangeKind.saveAs,
      beforeHash: hash,
      afterHash: hash,
      changedPointers: const [],
      timestamp: DateTime.now().toUtc(),
    ));
  }

  /// Reload the committed directory into memory and discard the draft.
  Future<void> revert() async {
    _ensureLive();
    final committed = await _storage.readJson(_mbdPath);
    if (committed == null) {
      throw StateError('Cannot revert: bundle missing at $_mbdPath');
    }
    final beforeHash = canonicalHashOfJson(_bundleJson);
    _bundleJson = committed;
    _cachedBundle = null;
    final afterHash = canonicalHashOfJson(_bundleJson);
    await _storage.deleteDir(_draftPath);
    _dirtyPointers.clear();
    _restoredDraft = false;
    _controller.add(CanonicalChange(
      kind: CanonicalChangeKind.revert,
      beforeHash: beforeHash,
      afterHash: afterHash,
      changedPointers: const [],
      timestamp: DateTime.now().toUtc(),
    ));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }

  void _ensureLive() {
    if (_disposed) {
      throw StateError('Canonical has been disposed');
    }
  }

  /// Decode [json] into an [McpBundle], threading the directory metadata
  /// when known. The fall-through path keeps the projection working even
  /// when the storage impl couldn't supply a directory (e.g. test
  /// fakes) — typed access is best-effort.
  McpBundle _decodeBundle(Map<String, dynamic> json) {
    final raw = McpBundle.fromJson(json);
    return raw.copyWith(directory: _mbdPath);
  }
}
