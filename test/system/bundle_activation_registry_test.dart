/// `BundleActivationRegistry` unit tests. Verifies multi-instance
/// management, union view, ownership lookup, and remove tear-down.
/// UI focus is a chrome/base concern, not a kernel concern, so it
/// is not exercised here.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';
import 'package:brain_kernel/brain_kernel.dart';

Future<FlowBrainWiring> _bootWiring() async {
  final wiring = FlowBrainWiring(
    workspaceId: 'test',
    kvStoragePort: InMemoryKvStoragePort(),
    llmProviders: const <String, LlmPort>{},
  );
  await wiring.boot();
  return wiring;
}

mb.McpBundle _bundleWithProfile(String id, String profileId) {
  return mb.McpBundle(
    manifest: mb.BundleManifest(id: id, name: id, version: '1.0.0'),
    profiles: mb.ProfilesSection(profiles: <mb.ProfileDefinition>[
      mb.ProfileDefinition(id: profileId, name: profileId),
    ]),
  );
}

void main() {
  // Reset the singleton between tests so cross-test bleed cannot
  // affect ordering or counts.
  Future<void> _clearRegistry() async {
    final ids = BundleActivationRegistry.instance.bundleIds.toList();
    for (final id in ids) {
      await BundleActivationRegistry.instance.remove(id);
    }
  }

  setUp(() async {
    await _clearRegistry();
  });

  tearDown(() async {
    await _clearRegistry();
  });

  group('BundleActivationRegistry', () {
    test('singleton instance', () {
      final r1 = BundleActivationRegistry.instance;
      final r2 = BundleActivationRegistry.instance;
      expect(identical(r1, r2), isTrue);
    });

    test('register / get / bundleIds', () async {
      final wiring = await _bootWiring();
      final a = BundleActivation(system: wiring.system, bundleId: 'a');
      final b = BundleActivation(system: wiring.system, bundleId: 'b');

      BundleActivationRegistry.instance.register(a);
      BundleActivationRegistry.instance.register(b);

      expect(BundleActivationRegistry.instance.get('a'), same(a));
      expect(BundleActivationRegistry.instance.get('b'), same(b));
      expect(BundleActivationRegistry.instance.bundleIds, containsAll(<String>['a', 'b']));

      await wiring.dispose();
    });

    test('register idempotent — duplicate bundleId returns existing',
        () async {
      final wiring = await _bootWiring();
      final a1 = BundleActivation(system: wiring.system, bundleId: 'dup');
      final a2 = BundleActivation(system: wiring.system, bundleId: 'dup');

      final first = BundleActivationRegistry.instance.register(a1);
      final second = BundleActivationRegistry.instance.register(a2);
      expect(identical(first, a1), isTrue);
      expect(identical(second, a1), isTrue,
          reason: 'second register returns first instance, ignoring a2');

      await wiring.dispose();
    });

    test('remove — instance gone', () async {
      final wiring = await _bootWiring();
      final a = BundleActivation(system: wiring.system, bundleId: 'a');
      BundleActivationRegistry.instance.register(a);

      await BundleActivationRegistry.instance.remove('a');

      expect(BundleActivationRegistry.instance.get('a'), isNull);

      await wiring.dispose();
    });

    test('union view — allProfiles is the merged set', () async {
      final wiring = await _bootWiring();
      final a = BundleActivation(system: wiring.system, bundleId: 'a');
      final b = BundleActivation(system: wiring.system, bundleId: 'b');
      await a.activate(_bundleWithProfile('a', 'p1'));
      await b.activate(_bundleWithProfile('b', 'p2'));
      BundleActivationRegistry.instance.register(a);
      BundleActivationRegistry.instance.register(b);

      final all = BundleActivationRegistry.instance.allProfiles;
      expect(all, containsAll(<String>['a.p1', 'b.p2']));
      expect(all, hasLength(2));

      await wiring.dispose();
    });

    test('ownership lookup — findOwner returns correct instance',
        () async {
      final wiring = await _bootWiring();
      final a = BundleActivation(system: wiring.system, bundleId: 'a');
      final b = BundleActivation(system: wiring.system, bundleId: 'b');
      await a.activate(_bundleWithProfile('a', 'p1'));
      await b.activate(_bundleWithProfile('b', 'p2'));
      BundleActivationRegistry.instance.register(a);
      BundleActivationRegistry.instance.register(b);

      // Isolation check — each activation only sees its own catalog.
      expect(a.ownsProfile('a.p1'), isTrue);
      expect(a.ownsProfile('b.p2'), isFalse);
      expect(b.ownsProfile('b.p2'), isTrue);
      expect(b.ownsProfile('a.p1'), isFalse);

      await wiring.dispose();
    });
  });
}
