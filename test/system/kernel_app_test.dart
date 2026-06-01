/// Regression test for `KernelApp` boot assembly + active context
/// scoping + endpoint isolation + Null port defaults.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('KernelApp.boot', () {
    test('boots with minimal arguments (in-memory KV)', () async {
      final app = await KernelApp.boot(
        workspaceId: 'test_app',
        kvStorage: InMemoryKvStoragePort(),
      );
      expect(app.workspaceId, 'test_app');
      expect(app.system, isNotNull);
      expect(app.endpoints, isEmpty);
      expect(app.activeBundleId, isNull);
      await app.shutdown();
    });

    test('uses Null* port defaults', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      expect(app.config, same(NullConfig.instance));
      expect(app.uiResource, same(NullUiResource.instance));
      expect(app.observability, same(NullObservability.instance));
      expect(app.bundleSource, isA<InMemoryBundleSource>());
      await app.shutdown();
    });

    test('Null* port operations are no-op safe', () async {
      // load / patch / register / event / cost / metric all complete
      // without throwing.
      await NullConfig.instance.load();
      await NullConfig.instance.patch(const <String, dynamic>{'k': 'v'});
      expect(
        await NullConfig.instance.watch().isEmpty,
        isTrue,
      );

      await NullUiResource.instance.list();
      await NullUiResource.instance.register('p', 'c');
      expect(
        await NullUiResource.instance.events().isEmpty,
        isTrue,
      );
      expect(
        () => NullUiResource.instance.read('p'),
        throwsStateError,
      );

      NullObservability.instance.event('e');
      NullObservability.instance.cost(
        model: 'm',
        tokensIn: 1,
        tokensOut: 1,
      );
      NullObservability.instance.metric('m', 1);
      expect(
        await NullObservability.instance.stream().isEmpty,
        isTrue,
      );
    });
  });

  group('Active context + scopeIdFor', () {
    late KernelApp app;

    setUp(() async {
      app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
    });

    tearDown(() async {
      await app.shutdown();
    });

    test('master context passes ids through', () {
      expect(app.activeBundleId, isNull);
      expect(app.scopeIdFor('foo'), 'foo');
      expect(app.scopeIdFor('a.b'), 'a.b');
    });

    test('domain context auto-prefixes bare ids', () {
      app.setActiveBundle('app_builder');
      expect(app.activeBundleId, 'app_builder');
      expect(app.scopeIdFor('manager'), 'app_builder.manager');
    });

    test('already-prefixed ids in domain context pass through', () {
      app.setActiveBundle('app_builder');
      expect(
        app.scopeIdFor('app_builder.specialist'),
        'app_builder.specialist',
      );
    });

    test(
        'ids qualified with a different namespace pass through unchanged',
        () {
      app.setActiveBundle('app_builder');
      expect(app.scopeIdFor('ops.thing'), 'ops.thing');
    });

    test('setActiveBundle(null) restores master pass-through', () {
      app.setActiveBundle('app_builder');
      app.setActiveBundle(null);
      expect(app.activeBundleId, isNull);
      expect(app.scopeIdFor('manager'), 'manager');
    });

    test('setActiveBundle with same value is idempotent', () {
      app.setActiveBundle('x');
      app.setActiveBundle('x');
      expect(app.activeBundleId, 'x');
    });
  });

  group('Endpoints', () {
    test('addEndpoint registers and lookup works', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final a = app.addEndpoint(label: 'studio');
      final b = app.addEndpoint(label: 'app_builder');
      expect(a.label, 'studio');
      expect(b.label, 'app_builder');
      expect(app.endpoint('studio'), same(a));
      expect(app.endpoint('app_builder'), same(b));
      expect(app.endpoints.length, 2);
      await app.shutdown();
    });

    test('addEndpoint idempotent on duplicate label', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final a = app.addEndpoint(label: 'x');
      final b = app.addEndpoint(label: 'x');
      expect(identical(a, b), isTrue);
      await app.shutdown();
    });

    test('addResource registers + removeResource is idempotent on missing uri',
        () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final ep = app.addEndpoint(label: 'r');
      ep.addResource(
        uri: 'studio://test/r1',
        name: 'r1',
        description: 'test resource',
        mimeType: 'text/plain',
        handler: (uri, params) async => KernelReadResourceResult(
          contents: <KernelResourceContent>[
            KernelResourceContent(uri: uri, text: 'hello', mimeType: 'text/plain'),
          ],
        ),
      );
      // removeResource returns true on first removal, false on retry.
      expect(ep.removeResource('studio://test/r1'), isTrue);
      expect(ep.removeResource('studio://test/missing'), isFalse);
      await app.shutdown();
    });

    test('tools registered on one endpoint do not leak to another',
        () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final a = app.addEndpoint(label: 'a');
      final b = app.addEndpoint(label: 'b');
      a.addTool(
        name: 'a_tool',
        description: 'A tool',
        inputSchema: const <String, dynamic>{'type': 'object'},
        handler: (_) async => throw UnimplementedError(),
      );
      expect(a.server.toolScopes.containsKey('a_tool'), isTrue);
      expect(b.server.toolScopes.containsKey('a_tool'), isFalse);
      await app.shutdown();
    });

    test('in-process start (transport == null) marks endpoint started',
        () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final ep = app.addEndpoint(label: 'in_process');
      await ep.start(null);
      expect(ep.isStarted, isTrue);
      await app.shutdown();
    });

    test('start is idempotent (second call no-op)', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final ep = app.addEndpoint(label: 'x');
      await ep.start(null);
      await ep.start(null);
      expect(ep.isStarted, isTrue);
      await app.shutdown();
    });
  });

  group('Shutdown', () {
    test('shutdown is idempotent', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      await app.shutdown();
      await app.shutdown();
    });

    test('shutdown tears down endpoints', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      app.addEndpoint(label: 'x');
      app.addEndpoint(label: 'y');
      expect(app.endpoints.length, 2);
      await app.shutdown();
      expect(app.endpoints, isEmpty);
    });
  });

  group('InMemoryBundleSource', () {
    test('fetch throws when ref missing', () async {
      const src = InMemoryBundleSource();
      expect(() => src.fetch('missing'), throwsStateError);
    });

    test('list reports registered refs', () async {
      const src = InMemoryBundleSource();
      final listing = await src.list();
      expect(listing, isEmpty);
    });
  });
}
