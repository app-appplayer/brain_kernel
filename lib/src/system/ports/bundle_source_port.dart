/// MOD-SYSTEM-007 — BundleSourcePort.
///
/// Host-supplied bundle origin — local filesystem, marketplace,
/// store, the host's own server, or any other distribution channel.
/// The kernel does not interpret `ref` semantics. Hosts that always
/// load bundles in-process use [InMemoryBundleSource].
library;

import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;

class BundleListing {
  const BundleListing({
    required this.ref,
    required this.name,
    this.version,
  });

  final String ref;
  final String name;
  final String? version;
}

abstract class BundleSourcePort {
  Future<McpBundle> fetch(String ref);
  Future<List<BundleListing>> list();
}

/// In-memory [BundleSourcePort] — useful for tests and hosts that
/// preload every bundle at boot time.
class InMemoryBundleSource implements BundleSourcePort {
  const InMemoryBundleSource({
    this.bundles = const <String, McpBundle>{},
  });

  final Map<String, McpBundle> bundles;

  @override
  Future<McpBundle> fetch(String ref) async {
    final bundle = bundles[ref];
    if (bundle == null) {
      throw StateError(
        'InMemoryBundleSource: no bundle registered for ref "$ref"',
      );
    }
    return bundle;
  }

  @override
  Future<List<BundleListing>> list() async {
    return <BundleListing>[
      for (final entry in bundles.entries)
        BundleListing(ref: entry.key, name: entry.key),
    ];
  }
}
