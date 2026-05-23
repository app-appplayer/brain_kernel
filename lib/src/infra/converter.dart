/// Build / export dispatcher for `.kbproj/` canonicals (MOD-INFRA-005).
///
/// Drives DDD-16's four targets — `mbd`, `mcpb`, `embedded`,
/// `consumerPack` — from a single `BuildRequest`. This first-pass
/// implementation wires `mbd` and `mcpb` end-to-end and stubs the other
/// two with explicit warnings so downstream callers (CLI Build button,
/// MCP `kb_build` tool) already see the full surface.
library;

import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;

import '../core/asset_validator.dart';
import '../feat/gold_question_runner.dart';
import 'bundle/mcpb_packager.dart';
import 'embed/embedding_runner.dart';

/// Output kinds. Multiple may be requested in one run.
enum BuildTarget {
  /// Plain `<outDir>/mbd/` directory (`McpBundleWriter.writeDirectory`).
  mbd,

  /// Zip archive `<outDir>/mcpb/<name>.mcpb`.
  mcpb,

  /// Bundle with inline embeddings written to `<outDir>/embedded/`.
  embedded,

  /// Consumer-shape pack written to `<outDir>/consumer-pack/`. Selected
  /// variant determined by [BuildRequest.consumerPackVariant].
  consumerPack,
}

/// Shape of the consumer-pack output.
enum ConsumerPackVariant {
  /// Only `KnowledgeSection` plus a minimal manifest. Targets external
  /// LLMs that just want chunks for zero-key RAG.
  ragOnly,

  /// The full bundle as-is — every native section preserved. Targets a
  /// FlowBrain host that loads all six asset categories.
  flowBrainFull,

  /// Single markdown file flattening every asset for direct prompt
  /// injection into LLMs that don't speak our bundle format.
  promptPack,
}

/// User intent for one build run.
class BuildRequest {
  const BuildRequest({
    required this.outDir,
    required this.targets,
    this.runValidationFirst = true,
    this.embedding,
    this.consumerPackVariant,
  });

  /// Absolute (recommended) or relative path. Created if missing.
  final String outDir;
  final Set<BuildTarget> targets;

  /// When true (default) [Converter.run] calls [AssetValidator.validateAll]
  /// before producing any artifact and aborts on errors.
  final bool runValidationFirst;

  /// Required when [BuildTarget.embedded] is requested. The provider
  /// computes embeddings for every chunk; the runner attaches them to
  /// `KnowledgeDocument.metadata['embedding']`.
  final EmbeddingPlan? embedding;

  /// Selects the [BuildTarget.consumerPack] shape. Defaults to
  /// [ConsumerPackVariant.ragOnly] when the target is requested without
  /// an explicit choice.
  final ConsumerPackVariant? consumerPackVariant;
}

/// One emitted artifact.
class BuildArtifact {
  const BuildArtifact({
    required this.target,
    required this.absolutePath,
  });
  final BuildTarget target;
  final String absolutePath;
}

/// Outcome of [Converter.run].
class BuildResult {
  const BuildResult({
    required this.success,
    required this.artifacts,
    required this.warnings,
    this.validationReport,
    this.error,
  });

  /// `false` when validation produced errors or a target threw.
  final bool success;
  final List<BuildArtifact> artifacts;
  final List<String> warnings;
  final ValidationReport? validationReport;
  final Object? error;

  bool get isEmpty => artifacts.isEmpty;
}

/// Stateless dispatcher.
class Converter {
  const Converter();

  Future<BuildResult> run({
    required McpBundle bundle,
    required BuildRequest request,
    AssetValidator validator = const AssetValidator(),
    RuntimeProbeFn? runtimeProbe,
    List<GoldQuestion>? goldSet,
  }) async {
    final artifacts = <BuildArtifact>[];
    final warnings = <String>[];
    ValidationReport? report;

    if (request.runValidationFirst) {
      report = await validator.validateAll(
        bundle,
        runtimeProbe: runtimeProbe,
        goldSet: goldSet,
      );
      if (report.errors.isNotEmpty) {
        return BuildResult(
          success: false,
          artifacts: const [],
          validationReport: report,
          warnings: const [],
        );
      }
    }

    try {
      await Directory(request.outDir).create(recursive: true);
      final name = bundle.manifest.id.isEmpty ? 'bundle' : bundle.manifest.id;

      String? mbdPath;
      if (request.targets.contains(BuildTarget.mbd)) {
        mbdPath = p.join(request.outDir, 'mbd');
        await McpBundleWriter.writeDirectory(
          bundle,
          mbdPath,
          overwrite: true,
        );
        artifacts.add(
          BuildArtifact(target: BuildTarget.mbd, absolutePath: mbdPath),
        );
      }

      if (request.targets.contains(BuildTarget.mcpb)) {
        final mcpbPath =
            p.join(request.outDir, 'mcpb', '$name.mcpb');
        await Directory(p.dirname(mcpbPath)).create(recursive: true);

        // Reuse the mbd we just wrote when the caller asked for both;
        // otherwise materialise a temporary one to feed the packer.
        Directory? tempDir;
        var sourceMbd = mbdPath;
        if (sourceMbd == null) {
          tempDir = await Directory.systemTemp.createTemp('kb_converter_');
          sourceMbd = tempDir.path;
          await McpBundleWriter.writeDirectory(
            bundle,
            sourceMbd,
            overwrite: true,
          );
        }
        try {
          await McpbPackager.pack(sourceMbd, mcpbPath, overwrite: true);
          artifacts.add(
            BuildArtifact(target: BuildTarget.mcpb, absolutePath: mcpbPath),
          );
        } finally {
          if (tempDir != null) await tempDir.delete(recursive: true);
        }
      }

      if (request.targets.contains(BuildTarget.embedded)) {
        final plan = request.embedding;
        if (plan == null) {
          warnings.add(
            'embedded target requires BuildRequest.embedding (provider + '
            'model + key); skipping',
          );
        } else {
          final embeddedDir = p.join(request.outDir, 'embedded');
          final embeddedBundle = await _withEmbeddings(bundle, plan);
          await McpBundleWriter.writeDirectory(
            embeddedBundle,
            embeddedDir,
            overwrite: true,
          );
          artifacts.add(BuildArtifact(
            target: BuildTarget.embedded,
            absolutePath: embeddedDir,
          ));
        }
      }
      if (request.targets.contains(BuildTarget.consumerPack)) {
        final variant =
            request.consumerPackVariant ?? ConsumerPackVariant.ragOnly;
        final consumerDir = p.join(request.outDir, 'consumer-pack');
        await Directory(consumerDir).create(recursive: true);
        switch (variant) {
          case ConsumerPackVariant.ragOnly:
            final ragBundle = _ragOnly(bundle);
            await McpBundleWriter.writeDirectory(
              ragBundle,
              consumerDir,
              overwrite: true,
            );
            break;
          case ConsumerPackVariant.flowBrainFull:
            await McpBundleWriter.writeDirectory(
              bundle,
              consumerDir,
              overwrite: true,
            );
            break;
          case ConsumerPackVariant.promptPack:
            final markdown = _promptPack(bundle);
            await File(p.join(consumerDir, 'prompt-pack.md'))
                .writeAsString(markdown, flush: true);
            break;
        }
        artifacts.add(BuildArtifact(
          target: BuildTarget.consumerPack,
          absolutePath: consumerDir,
        ));
      }

      return BuildResult(
        success: true,
        artifacts: artifacts,
        validationReport: report,
        warnings: warnings,
      );
    } catch (e) {
      return BuildResult(
        success: false,
        artifacts: artifacts,
        validationReport: report,
        warnings: warnings,
        error: e,
      );
    }
  }

  /// Run [plan] over every chunk in [bundle.knowledge] and return a new
  /// bundle whose KnowledgeSources record the computed `EmbeddingConfig`
  /// while each document carries `metadata['embedding']`.
  Future<McpBundle> _withEmbeddings(
    McpBundle bundle,
    EmbeddingPlan plan,
  ) async {
    final knowledge = bundle.knowledge;
    if (knowledge == null) return bundle;

    final runner = EmbeddingRunner(
      provider: plan.provider,
      batchSize: plan.batchSize,
    );
    final newSources = <KnowledgeSource>[];
    for (final src in knowledge.sources) {
      final docs = src.documents ?? const <KnowledgeDocument>[];
      final result = await runner.run(docs);
      newSources.add(KnowledgeSource(
        id: src.id,
        name: src.name,
        description: src.description,
        type: src.type,
        documents: result.documents,
        reference: src.reference,
        chunking: src.chunking,
        embedding: result.config,
        metadata: src.metadata,
      ));
    }

    return bundle.copyWith(
      knowledge: KnowledgeSection(
        schemaVersion: knowledge.schemaVersion,
        sources: newSources,
        retriever: knowledge.retriever,
        index: knowledge.index,
      ),
    );
  }

  /// Strip every section except `KnowledgeSection`. The result is the
  /// smallest possible RAG-ready bundle for an external LLM.
  McpBundle _ragOnly(McpBundle bundle) {
    return McpBundle(
      schemaVersion: bundle.schemaVersion,
      manifest: bundle.manifest,
      knowledge: bundle.knowledge,
    );
  }

  /// Flatten every asset into a single markdown document. Aimed at
  /// engines that don't understand `mcp_bundle` — paste the file into a
  /// prompt as-is.
  String _promptPack(McpBundle bundle) {
    final buf = StringBuffer()
      ..writeln('# ${bundle.manifest.name}')
      ..writeln()
      ..writeln(
          'Bundle id `${bundle.manifest.id}` · version `${bundle.manifest.version}`.')
      ..writeln();
    if (bundle.manifest.description != null) {
      buf.writeln(bundle.manifest.description);
      buf.writeln();
    }

    final knowledge = bundle.knowledge;
    if (knowledge != null && knowledge.sources.isNotEmpty) {
      buf.writeln('## Knowledge chunks');
      buf.writeln();
      for (final src in knowledge.sources) {
        buf.writeln('### Source `${src.id}` — ${src.name}');
        buf.writeln();
        for (final doc in src.documents ?? const <KnowledgeDocument>[]) {
          buf
            ..writeln('#### ${doc.title} (`${doc.id}`)')
            ..writeln()
            ..writeln(doc.content)
            ..writeln();
        }
      }
    }

    final philosophy = bundle.philosophy;
    if (philosophy != null && philosophy.philosophies.isNotEmpty) {
      buf.writeln('## Philosophies');
      buf.writeln();
      for (final phi in philosophy.philosophies) {
        buf
          ..writeln('### ${phi.name} (`${phi.id}`)')
          ..writeln()
          ..writeln(phi.statement)
          ..writeln();
        if (phi.examples.isNotEmpty) {
          buf.writeln('**Examples**');
          for (final ex in phi.examples) {
            buf.writeln('- ${ex.description}');
          }
          buf.writeln();
        }
        if (phi.counterexamples.isNotEmpty) {
          buf.writeln('**Counterexamples**');
          for (final cx in phi.counterexamples) {
            buf.writeln('- ${cx.description}');
          }
          buf.writeln();
        }
      }
    }

    final skills = bundle.skills;
    if (skills != null && skills.modules.isNotEmpty) {
      buf.writeln('## Skills');
      buf.writeln();
      for (final s in skills.modules) {
        buf
          ..writeln('### ${s.name} (`${s.id}`)')
          ..writeln()
          ..writeln(s.description ?? '_(no description)_')
          ..writeln();
      }
    }

    final profiles = bundle.profiles;
    if (profiles != null && profiles.profiles.isNotEmpty) {
      buf.writeln('## Profiles');
      buf.writeln();
      for (final pr in profiles.profiles) {
        buf
          ..writeln('### ${pr.name} (`${pr.id}`)')
          ..writeln()
          ..writeln(pr.description ?? '_(no description)_')
          ..writeln();
      }
    }

    final agents = bundle.agents;
    if (agents != null && agents.agents.isNotEmpty) {
      buf.writeln('## Agents');
      buf.writeln();
      for (final a in agents.agents) {
        buf
          ..writeln('### ${a.name} (`${a.id}`) — _${a.role}_')
          ..writeln()
          ..writeln(a.description ?? '_(no description)_')
          ..writeln();
      }
    }

    return buf.toString();
  }
}
