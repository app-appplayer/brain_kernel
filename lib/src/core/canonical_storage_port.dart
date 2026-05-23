/// I/O abstraction for [Canonical] (DDD-03).
///
/// Decouples the canonical container from the underlying storage shape so
/// each domain can plug its own bundle-on-disk strategy:
///
///   * **Manifest-only** (default, [ManifestOnlyCanonicalStorage]) reads
///     and writes `manifest.json` directly via `McpBundle.fromJson` /
///     `McpBundleWriter.writeDirectory`. Preserves every typed section
///     mcp_bundle models — knowledge-graph hosts (philosophy, agents,
///     factGraph, ...) round-trip without touching reserved folders.
///   * **Full-directory** (vibe-side, lives outside the kernel) reads
///     `manifest.json` plus the `ui/` reserved folder (`app.json` and
///     `pages/<id>.json`) and merges both into the JSON map. On write,
///     splits the `ui` key out of the map and emits it as reserved files
///     so `ApplicationDefinition` fields outside mcp_bundle's typed
///     `UiSection` survive the round-trip.
///
/// Both surface as [Map<String, dynamic>] so [Canonical] stays JSON-first
/// — typed [McpBundle] views are derived on demand and may be lossy for
/// content outside the schema.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;

/// Strategy that knows how to read, write, and delete a canonical bundle
/// directory. All [Canonical] disk-side I/O routes through this port —
/// no direct `dart:io` or `McpBundleWriter` calls leak into the
/// canonical itself.
abstract interface class CanonicalStoragePort {
  /// Read the canonical at [dirPath] as a raw JSON map. Returns null
  /// when the directory is missing or has no recoverable bundle.
  /// Implementations may throw when the directory exists but is corrupt
  /// — callers decide whether to surface or fall through to a fresh
  /// canonical.
  Future<Map<String, dynamic>?> readJson(String dirPath);

  /// Write [json] to [dirPath] atomically. Implementations choose how to
  /// distribute the map across files (manifest only, or manifest +
  /// reserved folders).
  Future<void> writeJson(Map<String, dynamic> json, String dirPath);

  /// True when [dirPath] exists on the underlying storage.
  Future<bool> dirExists(String dirPath);

  /// Recursively delete [dirPath]. No-op when the directory is absent.
  Future<void> deleteDir(String dirPath);
}

/// Default kernel-side storage. Reads `manifest.json` directly via
/// `McpBundle.fromJson` so every typed section round-trips. Writes via
/// `McpBundleWriter.writeDirectory` (no reserved folders).
///
/// Domains that store content outside the typed schema (notably vibe's
/// `ApplicationDefinition` ui content) provide their own port impl.
class ManifestOnlyCanonicalStorage implements CanonicalStoragePort {
  const ManifestOnlyCanonicalStorage();

  @override
  Future<Map<String, dynamic>?> readJson(String dirPath) async {
    final manifestFile = File(p.join(dirPath, 'manifest.json'));
    if (!await manifestFile.exists()) return null;
    final raw = await manifestFile.readAsString();
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    return decoded;
  }

  @override
  Future<void> writeJson(
    Map<String, dynamic> json,
    String dirPath,
  ) async {
    final bundle = McpBundle.fromJson(json);
    await McpBundleWriter.writeDirectory(
      bundle,
      dirPath,
      overwrite: true,
    );
  }

  @override
  Future<bool> dirExists(String dirPath) => Directory(dirPath).exists();

  @override
  Future<void> deleteDir(String dirPath) async {
    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
