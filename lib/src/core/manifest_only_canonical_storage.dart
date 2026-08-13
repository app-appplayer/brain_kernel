/// The kernel's filesystem implementation of [CanonicalStoragePort].
///
/// Split from the port declaration so that importing the port does not
/// import `dart:io`. A host without a filesystem supplies its own
/// implementation and never reaches this file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;

import 'canonical_storage_port.dart';

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
