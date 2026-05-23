/// Knowledge bundle writer — assemble McpBundle (manifest +
/// KnowledgeSection) and persist to a `.mbd/` directory via
/// `McpBundleWriter.writeDirectory`.
library;

import 'package:mcp_bundle/mcp_bundle.dart';

class KnowledgeWriteSpec {
  const KnowledgeWriteSpec({
    required this.manifestId,
    required this.manifestName,
    required this.manifestVersion,
    this.manifestDescription,
    required this.sources,
    this.chunking,
  });

  final String manifestId;
  final String manifestName;
  final String manifestVersion;
  final String? manifestDescription;

  /// One [KnowledgeSource] per ingested directory group. Each holds
  /// the per-document chunks already prepared by the chunker(s).
  final List<KnowledgeSource> sources;

  /// Optional chunking config recorded in the bundle so a downstream
  /// re-chunker can replicate the original split policy. Pure
  /// metadata — the actual chunking already happened upstream.
  final ChunkingConfig? chunking;
}

class KnowledgeWriter {
  /// Build the McpBundle and write it to [mbdPath]. Returns the
  /// absolute path written. Pass [overwrite: true] to replace an
  /// existing `.mbd/`.
  static Future<String> write(
    KnowledgeWriteSpec spec,
    String mbdPath, {
    bool overwrite = false,
  }) async {
    final bundle = McpBundle(
      manifest: BundleManifest(
        id: spec.manifestId,
        name: spec.manifestName,
        version: spec.manifestVersion,
        description: spec.manifestDescription,
      ),
      knowledge: KnowledgeSection(
        sources: spec.sources
            .map((s) => spec.chunking == null
                ? s
                : KnowledgeSource(
                    id: s.id,
                    name: s.name,
                    description: s.description,
                    type: s.type,
                    documents: s.documents,
                    reference: s.reference,
                    chunking: spec.chunking,
                    embedding: s.embedding,
                    metadata: s.metadata,
                  ))
            .toList(),
      ),
    );
    return McpBundleWriter.writeDirectory(
      bundle,
      mbdPath,
      overwrite: overwrite,
    );
  }
}
