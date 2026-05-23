/// `.kbproj/` lifecycle owner (MOD-CORE-001).
///
/// Owns the canonical (`Canonical`) plus three sidecar files —
/// `prefs.json`, `chat.jsonl`, `history.jsonl`. `import` / `export` are
/// stubbed for a later round.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'sidecar/chat_log.dart';
import 'sidecar/history_log.dart';
import 'sidecar/prefs.dart';

/// Metadata persisted to `<kbproj>/project.json`.
class ProjectMeta {
  ProjectMeta({
    required this.name,
    required this.schemaVersion,
    required this.createdAt,
    this.lastOpenedAt,
    this.lastSavedAt,
    this.bundleSubdir = 'app.mbd',
    Map<String, dynamic>? extras,
  }) : extras = extras ?? <String, dynamic>{};

  factory ProjectMeta.fromJson(Map<String, dynamic> json) {
    return ProjectMeta(
      name: json['name'] as String? ?? 'Untitled',
      schemaVersion: json['schemaVersion'] as String? ?? '1.0.0',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now().toUtc(),
      lastOpenedAt:
          DateTime.tryParse(json['lastOpenedAt'] as String? ?? ''),
      lastSavedAt: DateTime.tryParse(json['lastSavedAt'] as String? ?? ''),
      bundleSubdir: json['bundleSubdir'] as String? ?? 'app.mbd',
      extras: (json['extras'] as Map?)?.cast<String, dynamic>(),
    );
  }

  String name;
  String schemaVersion;
  DateTime createdAt;
  DateTime? lastOpenedAt;
  DateTime? lastSavedAt;
  String bundleSubdir;
  Map<String, dynamic> extras;

  Map<String, dynamic> toJson() => {
        'name': name,
        'schemaVersion': schemaVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        if (lastOpenedAt != null)
          'lastOpenedAt': lastOpenedAt!.toUtc().toIso8601String(),
        if (lastSavedAt != null)
          'lastSavedAt': lastSavedAt!.toUtc().toIso8601String(),
        'bundleSubdir': bundleSubdir,
        if (extras.isNotEmpty) 'extras': extras,
      };
}

/// Thrown when the on-disk layout cannot be parsed as a `.kbproj/`.
class ProjectFormatException implements Exception {
  ProjectFormatException(this.path, this.message);
  final String path;
  final String message;
  @override
  String toString() => 'ProjectFormatException($path): $message';
}

/// Lifecycle owner for one `.kbproj/` directory. Holds the live
/// [Canonical], persisted [ProjectMeta], and three sidecars
/// (`prefs.json` / `chat.jsonl` / `history.jsonl`).
class Project {
  Project._({
    required this.path,
    required this.meta,
    required this.canonical,
    required this.prefs,
    required this.chatLog,
    required this.historyLog,
  });

  /// Open an existing `.kbproj/`. Throws [ProjectFormatException]
  /// when `project.json` is missing or malformed.
  static Future<Project> openAt(String projectPath) async {
    final metaFile = File(p.join(projectPath, 'project.json'));
    if (!await metaFile.exists()) {
      throw ProjectFormatException(
        projectPath,
        'project.json is missing',
      );
    }
    final meta = ProjectMeta.fromJson(
      jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>,
    );

    final mbdPath = p.join(projectPath, meta.bundleSubdir);
    if (!await Directory(mbdPath).exists()) {
      // Recover an empty bundle so the project is still openable.
      await McpBundleWriter.writeDirectory(
        McpBundle(
          manifest: BundleManifest(
            id: meta.name.toLowerCase().replaceAll(' ', '-'),
            name: meta.name,
            version: '0.0.0',
          ),
        ),
        mbdPath,
        overwrite: true,
      );
    }

    final draftPath = '$mbdPath.draft';
    final canonical =
        await Canonical.openAt(mbdPath, draftPath: draftPath);

    final prefs = await Prefs.load(projectPath);
    final chatLog = ChatLog.attach(projectPath);
    final historyLog = HistoryLog.attach(projectPath);
    historyLog.subscribe(canonical);

    meta.lastOpenedAt = DateTime.now().toUtc();
    await _writeMeta(projectPath, meta);

    return Project._(
      path: projectPath,
      meta: meta,
      canonical: canonical,
      prefs: prefs,
      chatLog: chatLog,
      historyLog: historyLog,
    );
  }

  /// Create a fresh `.kbproj/` at [projectPath]. Returns the opened
  /// project so callers can immediately edit it.
  static Future<Project> newAt(
    String projectPath, {
    String? name,
  }) async {
    final dir = Directory(projectPath);
    if (await dir.exists()) {
      final entries = await dir.list().toList();
      if (entries.isNotEmpty) {
        throw ProjectFormatException(
          projectPath,
          'Directory is not empty — refusing to overwrite',
        );
      }
    } else {
      await dir.create(recursive: true);
    }
    await Directory(p.join(projectPath, 'sources')).create(recursive: true);

    final resolvedName = name ?? p.basenameWithoutExtension(projectPath);
    final meta = ProjectMeta(
      name: resolvedName,
      schemaVersion: '1.0.0',
      createdAt: DateTime.now().toUtc(),
    );
    await _writeMeta(projectPath, meta);

    final mbdPath = p.join(projectPath, meta.bundleSubdir);
    await McpBundleWriter.writeDirectory(
      McpBundle(
        manifest: BundleManifest(
          id: resolvedName.toLowerCase().replaceAll(' ', '-'),
          name: resolvedName,
          version: '0.0.0',
        ),
      ),
      mbdPath,
      overwrite: true,
    );

    return openAt(projectPath);
  }

  final String path;
  final ProjectMeta meta;
  final Canonical canonical;
  final Prefs prefs;
  ChatLog chatLog;
  HistoryLog historyLog;

  /// Commit memory → disk (`<path>/<bundleSubdir>/`). Updates `lastSavedAt`.
  Future<void> save() async {
    await canonical.commit();
    meta.lastSavedAt = DateTime.now().toUtc();
    await _writeMeta(path, meta);
  }

  /// Copy the project to [newProjectPath] and re-target the live
  /// canonical + sidecars at it. The previous path is left untouched on
  /// disk.
  Future<void> saveAs(String newProjectPath) async {
    final dir = Directory(newProjectPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final newMeta = ProjectMeta(
      name: meta.name,
      schemaVersion: meta.schemaVersion,
      createdAt: meta.createdAt,
      lastOpenedAt: DateTime.now().toUtc(),
      lastSavedAt: DateTime.now().toUtc(),
      bundleSubdir: meta.bundleSubdir,
      extras: meta.extras,
    );
    await _writeMeta(newProjectPath, newMeta);

    final newMbdPath = p.join(newProjectPath, newMeta.bundleSubdir);
    await canonical.commitAs(newMbdPath);

    // Move sidecars over so the new project starts with the same UI
    // state, chat history, and audit trail.
    await prefs.copyTo(newProjectPath);
    await chatLog.copyTo(newProjectPath);
    await historyLog.copyTo(newProjectPath);

    // Re-attach sidecars rooted at the new project so subsequent writes
    // land on the new disk path.
    await historyLog.dispose();
    chatLog = ChatLog.attach(newProjectPath);
    historyLog = HistoryLog.attach(newProjectPath);
    historyLog.subscribe(canonical);

    meta.lastOpenedAt = newMeta.lastOpenedAt;
    meta.lastSavedAt = newMeta.lastSavedAt;
  }

  /// Reload the committed bundle into memory — discards uncommitted
  /// edits (and the draft mirror).
  Future<void> revert() => canonical.revert();

  Future<void> close() async {
    await prefs.save();
    await historyLog.dispose();
    await canonical.dispose();
  }

  static Future<void> _writeMeta(
    String projectPath,
    ProjectMeta meta,
  ) async {
    final encoder = const JsonEncoder.withIndent('  ');
    final tmp = File(p.join(projectPath, 'project.json.tmp'));
    await tmp.writeAsString(encoder.convert(meta.toJson()), flush: true);
    await tmp.rename(p.join(projectPath, 'project.json'));
  }
}
