/// `.mcpb` packager — zip a `.mbd/` directory tree.
///
/// `.mcpb` is the compressed transport form of an mcp_bundle: same
/// content as the `.mbd/` directory, packed into a single archive
/// (deflate). This packager walks the directory and writes a flat
/// archive with relative entry paths.
///
/// **vibe_studio capabilities convention** — Extension API v1
/// (Phase Y3). Hosts read `manifest.capabilities` (existing field on
/// `BundleManifest`) to route a `.mcpb` into the right sub-system.
/// Packagers can call [computeCapabilities] to derive the full list
/// automatically by scanning the .mbd directory:
///
///   - `studio.shell`                   — `shell.json` present
///   - `studio.tool.<name>`             — `contributes.tools` inside
///                                        `*.builder_extension.json`
///   - `studio.agent.<id>`              — contributes.agents
///   - `studio.settings_section.<id>`   — contributes.settingsSections
///   - `studio.debug_view.<id>`         — contributes.debugViews
///   - `studio.knowledge.<namespace>`   — `knowledge/<namespace>/`
///                                        subdirectory present
///
/// Hosts (vibe_studio install router, AppPlayer Pro) only look at the
/// prefix to decide where to route the bundle.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:path/path.dart' as p;

class McpbPackager {
  /// Pack [mbdPath] (a `.mbd/` directory) into [mcpbPath] (a `.mcpb`
  /// file). Throws when the source doesn't exist, when [mcpbPath]
  /// exists and [overwrite] is false, or when no entries were found.
  ///
  /// Returns the absolute path of the produced `.mcpb` file.
  static Future<String> pack(
    String mbdPath,
    String mcpbPath, {
    bool overwrite = false,
  }) async {
    final src = Directory(mbdPath);
    if (!await src.exists()) {
      throw ArgumentError('source .mbd not found: $mbdPath');
    }
    final out = File(mcpbPath);
    if (await out.exists() && !overwrite) {
      throw StateError(
        'refusing to overwrite existing .mcpb (pass overwrite: true): '
        '$mcpbPath',
      );
    }
    final archive = Archive();
    final entries = await src
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    if (entries.isEmpty) {
      throw StateError('no files found under $mbdPath');
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final file in entries) {
      final rel = p
          .relative(file.path, from: mbdPath)
          .replaceAll(Platform.pathSeparator, '/');
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(rel, bytes.length, bytes));
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('zip encoder returned null for $mbdPath');
    }
    await out.parent.create(recursive: true);
    await out.writeAsBytes(encoded, flush: true);
    return out.absolute.path;
  }

  /// Walk [mbdPath] and derive the capabilities every vibe_studio
  /// host needs to route this .mbd. Returns deterministic order
  /// (sorted) so two packs of the same source give equal capability
  /// lists. See the library doc for the prefix convention.
  ///
  /// Robust against malformed contributions JSON — bad files are
  /// silently skipped (a packager should warn, but `.mcpb` install
  /// must not crash on noise).
  static Future<List<String>> computeCapabilities(String mbdPath) async {
    final src = Directory(mbdPath);
    if (!await src.exists()) return const <String>[];
    final caps = <String>{};

    // shell.json detection.
    if (await File(p.join(mbdPath, 'shell.json')).exists()) {
      caps.add('studio.shell');
    }

    // *.builder_extension.json scan.
    await for (final entity in src.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.builder_extension.json')) continue;
      try {
        final json = jsonDecode(await entity.readAsString());
        if (json is! Map) continue;
        final contrib = json['contributes'];
        if (contrib is! Map) continue;
        final tools = contrib['tools'];
        if (tools is List) {
          for (final t in tools) {
            if (t is Map && t['name'] is String) {
              caps.add('studio.tool.${t['name']}');
            }
          }
        }
        final agents = contrib['agents'];
        if (agents is List) {
          for (final a in agents) {
            if (a is Map && a['id'] is String) {
              caps.add('studio.agent.${a['id']}');
            }
          }
        }
        final settings = contrib['settingsSections'];
        if (settings is List) {
          for (final s in settings) {
            if (s is Map && s['viewId'] is String) {
              caps.add('studio.settings_section.${s['viewId']}');
            }
          }
        }
        final debugViews = contrib['debugViews'];
        if (debugViews is List) {
          for (final d in debugViews) {
            if (d is Map && d['viewId'] is String) {
              caps.add('studio.debug_view.${d['viewId']}');
            }
          }
        }
      } catch (_) {
        // Bad JSON — skip silently, packager warns elsewhere.
      }
    }

    // knowledge/<namespace>/ subdirectories.
    final knowledgeDir = Directory(p.join(mbdPath, 'knowledge'));
    if (await knowledgeDir.exists()) {
      await for (final entity in knowledgeDir.list()) {
        if (entity is! Directory) continue;
        final ns = p.basename(entity.path);
        if (ns.isEmpty || ns.startsWith('.')) continue;
        caps.add('studio.knowledge.$ns');
      }
    }

    final list = caps.toList()..sort();
    return list;
  }
}
