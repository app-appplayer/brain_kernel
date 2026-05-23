/// Maps the six [AssetCategory] values to the `mcp_bundle` section that
/// owns them, plus the JSON-Pointer prefix used by the patch pipeline.
///
/// Implements MOD-CORE-005 (SDD §2.1 / DDD-01 §2.1).
library;

import 'package:mcp_bundle/mcp_bundle.dart';

import 'types.dart';

/// Resolution result for one [AssetCategory].
class AssetCategoryDescriptor {
  const AssetCategoryDescriptor({
    required this.category,
    required this.jsonPointerPrefix,
    required this.sectionKey,
    required this.displayName,
  });

  /// The category itself.
  final AssetCategory category;

  /// JSON-Pointer prefix into the bundle JSON (e.g. `/skills/modules`).
  /// Patches against this category land under this prefix.
  final String jsonPointerPrefix;

  /// The top-level section key inside the manifest JSON
  /// (e.g. `'skills'`, `'philosophy'`). Useful for raw JSON inspection.
  final String sectionKey;

  /// Human-readable label used in UI (English source — host can localise).
  final String displayName;
}

/// Static catalogue. Lookup is O(1).
class AssetCategoryMap {
  AssetCategoryMap._();

  static const Map<AssetCategory, AssetCategoryDescriptor> _byCategory = {
    AssetCategory.chunks: AssetCategoryDescriptor(
      category: AssetCategory.chunks,
      jsonPointerPrefix: '/knowledge/sources',
      sectionKey: 'knowledge',
      displayName: 'Knowledge chunks',
    ),
    AssetCategory.fact: AssetCategoryDescriptor(
      category: AssetCategory.fact,
      jsonPointerPrefix: '/factGraphSection/embedded',
      sectionKey: 'factGraphSection',
      displayName: 'Fact',
    ),
    AssetCategory.skill: AssetCategoryDescriptor(
      category: AssetCategory.skill,
      jsonPointerPrefix: '/skills/modules',
      sectionKey: 'skills',
      displayName: 'Skill',
    ),
    AssetCategory.profile: AssetCategoryDescriptor(
      category: AssetCategory.profile,
      jsonPointerPrefix: '/profiles/profiles',
      sectionKey: 'profiles',
      displayName: 'Profile',
    ),
    AssetCategory.philosophy: AssetCategoryDescriptor(
      category: AssetCategory.philosophy,
      jsonPointerPrefix: '/philosophy/philosophies',
      sectionKey: 'philosophy',
      displayName: 'Philosophy',
    ),
    AssetCategory.agent: AssetCategoryDescriptor(
      category: AssetCategory.agent,
      jsonPointerPrefix: '/agents/agents',
      sectionKey: 'agents',
      displayName: 'Agent',
    ),
  };

  static AssetCategoryDescriptor of(AssetCategory category) =>
      _byCategory[category]!;

  static List<AssetCategoryDescriptor> get all =>
      List.unmodifiable(_byCategory.values);

  /// Read the typed list of asset ids that the bundle currently exposes
  /// for [category]. Empty list when the section is missing or empty.
  /// Used by cross-ref validation and Properties pane id pickers.
  static List<String> currentIds(McpBundle bundle, AssetCategory category) {
    switch (category) {
      case AssetCategory.chunks:
        final out = <String>[];
        for (final src in bundle.knowledge?.sources ?? const []) {
          for (final doc in src.documents) {
            out.add(doc.id);
          }
        }
        return out;
      case AssetCategory.fact:
        final ids = <String>[
          // Typed schema names — entity / fact type definitions.
          for (final ent in bundle.factGraphSchema?.entityTypes ??
              const <EntityTypeDefinition>[])
            ent.name,
          for (final f in bundle.factGraphSchema?.factTypes ??
              const <FactTypeDefinition>[])
            f.name,
        ];
        // Embedded mode — SPO triple instances live under
        // `factGraphSection.embedded.facts` (typed `EmbeddedFact` records)
        // and carry their own `id`.
        final embedded = bundle.factGraphSection?.embedded;
        if (embedded != null) {
          for (final fact in embedded.facts) {
            ids.add(fact.id);
          }
        }
        return ids;
      case AssetCategory.skill:
        return [for (final m in bundle.skills?.modules ?? const []) m.id];
      case AssetCategory.profile:
        return [
          for (final p in bundle.profiles?.profiles ?? const []) p.id,
        ];
      case AssetCategory.philosophy:
        return [
          for (final p in bundle.philosophy?.philosophies ?? const []) p.id,
        ];
      case AssetCategory.agent:
        return [for (final a in bundle.agents?.agents ?? const []) a.id];
    }
  }
}
