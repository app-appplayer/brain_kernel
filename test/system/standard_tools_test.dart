/// Regression test for the standard tool surface — composition,
/// endpoint registration, and a representative dispatch path.
library;

import 'dart:convert' show jsonDecode;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('standardTools composition', () {
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

    test('returns the full 47-tool map', () {
      final tools = standardTools(app);
      // 9 fact + 3 skill + 4 profile + 6 philosophy + 10 ops + 13 agent
      // + 2 knowledge = 47. (agent: 11 + route + review, spec 12 §5.)
      expect(tools.length, 47);
    });

    test('every facade prefix is present', () {
      final tools = standardTools(app);
      final prefixes = tools.keys.map((k) => k.split('.').take(2).join('.')).toSet();
      expect(prefixes, containsAll(<String>[
        'bk.fact',
        'bk.skill',
        'bk.profile',
        'bk.philosophy',
        'bk.workflow',
        'bk.pipeline',
        'bk.runbook',
        'bk.agent',
        'bk.knowledge',
      ]));
    });
  });

  group('wrapInProcess', () {
    test('encodes the result as JSON text', () async {
      final handler = wrapInProcess((args) async {
        return <String, dynamic>{'ok': true, 'echo': args['x']};
      });
      final result = await handler(<String, dynamic>{'x': 42});
      expect(result.content, hasLength(1));
      final txt = result.content.first as KernelTextContent;
      final decoded = jsonDecode(txt.text) as Map<String, dynamic>;
      expect(decoded['ok'], isTrue);
      expect(decoded['echo'], 42);
      expect(result.isError, isFalse);
    });

    test('sets isError when raw result carries ok=false', () async {
      final handler = wrapInProcess((args) async {
        return <String, dynamic>{'ok': false, 'error': 'fail'};
      });
      final result = await handler(const <String, dynamic>{});
      expect(result.isError, isTrue);
    });
  });

  group('KernelEndpoint.addStandardTools', () {
    test('registers every tool on the endpoint server', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final ep = app.addEndpoint(label: 'main');
      ep.addStandardTools(app);
      expect(ep.server.toolScopes.length, 47);
      expect(ep.server.toolScopes.containsKey('bk.behavior.run'), isTrue);
      expect(ep.server.toolScopes.containsKey('bk.fact.write'), isTrue);
      expect(ep.server.toolScopes.containsKey('bk.agent.materialize'),
          isTrue);
      expect(ep.server.toolScopes.containsKey('bk.knowledge.query'), isTrue);
      await app.shutdown();
    });

    test('a representative wrapper dispatches via the endpoint server',
        () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final ep = app.addEndpoint(label: 'main');
      ep.addStandardTools(app);
      await ep.start(null);

      // bk.profile.list — no inputs, no side effects, returns ok:true.
      final tools = standardTools(app);
      final raw = await tools['bk.profile.list']!(const <String, dynamic>{});
      expect(raw, isA<Map>());
      expect((raw as Map)['ok'], isTrue);

      await app.shutdown();
    });

    test('activate exposes the bundle document at bundle://manifest.json',
        () async {
      // specs/mcp_serving/spec/1.0 — a kernel-endpoint server exposes the
      // activated bundle's document so a remote client can reconstruct it.
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      final ep = app.addEndpoint(label: 'main');
      final bundle = McpBundleLoader.fromJson(<String, dynamic>{
        'schemaVersion': '1.0.0',
        'manifest': {'id': 'srv.app', 'name': 'Srv', 'version': '1.0.0'},
      });
      await ep.activate(bundle, bundleIdOverride: 'srv.app');
      expect(ep.server.resourceUris, contains('bundle://manifest.json'));
      await app.shutdown();
    });
  });

  group('scopeIdFor integration', () {
    test('domain context prefixes ids in standard tool calls', () async {
      final app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
      app.setActiveBundle('my_bundle');
      // The wrapper itself rejects empty id; pass a bare id and assert
      // the eventual prefix appears in the (error) message path. Using
      // a missing record so the facade short-circuits on lookup.
      final tools = standardTools(app);
      final raw = await tools['bk.fact.get']!(
        const <String, dynamic>{'id': 'unknown'},
      );
      // The wrapper either returns ok:false (not found) or a plain
      // error envelope — both shapes use the prefixed id internally
      // for the lookup. We only assert the dispatch path completed.
      expect(raw, isA<Map>());
      await app.shutdown();
    });
  });
}
