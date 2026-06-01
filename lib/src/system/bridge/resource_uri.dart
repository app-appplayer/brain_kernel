/// `kb://<facade>/<id>` — the bridge's resource URI scheme. Eight
/// kernel facade categories map 1:1 to a fixed scheme so any host's
/// LLM / bundle / agent can read knowledge assets without first
/// learning a host-specific catalog.
///
/// Knowledge-operations §14.3 — bridge's `readResource(uri)` parses
/// the URI, applies `scopeId` on the local-id segment (so the bundle
/// code can write `kb://fact/foo` and the bridge resolves it to
/// `kb://fact/<bundleId>.foo`), and looks up the matching kernel
/// facade.
library;

/// Eight kernel-facade categories. The exact set matches the §1
/// taxonomy.
enum KbFacade {
  fact,
  skill,
  profile,
  philosophy,
  workflow,
  pipeline,
  runbook,
  agent,
}

extension KbFacadeName on KbFacade {
  String get scheme {
    switch (this) {
      case KbFacade.fact:
        return 'fact';
      case KbFacade.skill:
        return 'skill';
      case KbFacade.profile:
        return 'profile';
      case KbFacade.philosophy:
        return 'philosophy';
      case KbFacade.workflow:
        return 'workflow';
      case KbFacade.pipeline:
        return 'pipeline';
      case KbFacade.runbook:
        return 'runbook';
      case KbFacade.agent:
        return 'agent';
    }
  }

  static KbFacade? fromScheme(String scheme) {
    for (final f in KbFacade.values) {
      if (f.scheme == scheme) return f;
    }
    return null;
  }
}

/// Parsed `kb://<facade>/<id>` reference. `id` is the LOCAL id as the
/// caller wrote it — `scopeId` has NOT been applied yet. The bridge
/// applies scoping at resolution time so cross-bundle reads (where
/// the caller wrote `kb://fact/other_bundle.foo`) pass through
/// without rewrite.
class KbResourceRef {
  const KbResourceRef({
    required this.facade,
    required this.id,
  });

  final KbFacade facade;
  final String id;

  /// Parse a `kb://...` URI. Returns null on invalid scheme,
  /// unknown facade, or empty id.
  static KbResourceRef? parse(String uri) {
    if (!uri.startsWith('kb://')) return null;
    final rest = uri.substring(5); // drop "kb://"
    final slash = rest.indexOf('/');
    if (slash <= 0 || slash == rest.length - 1) return null;
    final scheme = rest.substring(0, slash);
    final id = rest.substring(slash + 1);
    if (id.isEmpty) return null;
    final facade = KbFacadeName.fromScheme(scheme);
    if (facade == null) return null;
    return KbResourceRef(facade: facade, id: id);
  }

  /// Serialise back to canonical form. Useful after `scopeId`
  /// rewrites the local id so callers can log / cite the
  /// canonical full URI.
  String toUri() => 'kb://${facade.scheme}/$id';

  @override
  String toString() => toUri();
}
