/// Read a `.mbd/` directory's `manifest.json` and parse it back to an
/// `McpBundle`. Used by the `add` subcommand to load an existing bundle
/// before merging new sources in.
///
/// Mirrors the symmetric write path in `KnowledgeWriter` —
/// `manifest.json` at the directory root carries the entire structure
/// (knowledge / skills / profiles / philosophy sections inline). When
/// downstream tooling moves any of those into reserved subfolders we'll
/// need to extend this reader to merge them back; the current
/// knowledge_builder writer always inlines, so a single-file read is
/// faithful.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;
import 'package:path/path.dart' as p;

class BundleReader {
  /// Read [mbdPath] and return its parsed `McpBundle`. Throws
  /// [ArgumentError] when the directory or manifest is missing,
  /// [FormatException] when the manifest is not valid JSON.
  static Future<McpBundle> read(String mbdPath) async {
    final dir = Directory(mbdPath);
    if (!await dir.exists()) {
      throw ArgumentError('mbd directory not found: $mbdPath');
    }
    final manifest = File(p.join(mbdPath, 'manifest.json'));
    if (!await manifest.exists()) {
      throw ArgumentError('manifest.json missing under $mbdPath');
    }
    final raw = await manifest.readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return McpBundle.fromJson(json);
  }
}
