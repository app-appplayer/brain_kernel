/// I/O abstraction for [Canonical].
///
/// Decouples the canonical container from the underlying storage shape so
/// each domain can plug its own bundle-on-disk strategy:
///
///   * **Manifest-only** (the kernel's default, in
///     `manifest_only_canonical_storage.dart`) reads
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

/// Strategy that knows how to read, write, and delete a canonical bundle
/// directory. All [Canonical] disk-side I/O routes through this port —
/// no direct `dart:io` or `McpBundleWriter` calls leak into the
/// canonical itself.
///
/// **This file declares the port and nothing else.** It imports no
/// platform library, so a host that supplies its own implementation — a
/// browser storing into the account rather than onto a disk — can name the
/// type without dragging `dart:io` into a build that has none. The
/// filesystem implementation lives beside it in
/// `manifest_only_canonical_storage.dart`.
///
/// `dirPath` is an opaque address, not necessarily a filesystem path: an
/// implementation is free to read it as a key.
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
