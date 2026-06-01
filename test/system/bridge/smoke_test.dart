/// Smoke regression — bundle_host_bridge boots, scopes ids, dispatches
/// in-process tools, and tears down session handles.
library;

import 'package:brain_kernel/brain_kernel.dart';
// bridge is re-exported by brain_kernel barrel above
import 'package:test/test.dart';

void main() {
  setUp(() {
    DispatchContext.instance.resetForTesting();
    SessionRegistry.instance.clearForTesting();
  });

  test('KbResourceRef.parse / toUri round-trip', () {
    final ref = KbResourceRef.parse('kb://fact/my_bundle.foo')!;
    expect(ref.facade, KbFacade.fact);
    expect(ref.id, 'my_bundle.foo');
    expect(ref.toUri(), 'kb://fact/my_bundle.foo');
  });

  test('KbResourceRef.parse rejects invalid forms', () {
    expect(KbResourceRef.parse('http://foo/bar'), isNull);
    expect(KbResourceRef.parse('kb://nope/foo'), isNull);
    expect(KbResourceRef.parse('kb://fact/'), isNull);
  });

  test('DispatchContext.scopeId master pass-through', () async {
    final bridge = BundleSessionBridge();
    final master = bridge.openMasterSession();
    await bridge.runScoped(master, () async {
      expect(bridge.context.scopeId('foo'), 'foo');
    });
    await bridge.closeSession(master);
  });

  test('DispatchContext.scopeId domain auto-prefix', () async {
    final app = await KernelApp.boot(
      workspaceId: 't',
      kvStorage: InMemoryKvStoragePort(),
    );
    final activation = BundleActivation(system: app.system, bundleId: 'b1');
    final bridge = BundleSessionBridge();
    final session = bridge.openSession(activation);
    await bridge.runScoped(session, () async {
      expect(bridge.context.scopeId('foo'), 'b1.foo');
      expect(bridge.context.scopeId('b1.foo'), 'b1.foo');
      expect(bridge.context.scopeId('other.foo'), 'other.foo');
    });
    await bridge.closeSession(session);
    await app.shutdown();
  });

  test('registerTool / callTool dispatch + isError on unknown', () async {
    final app = await KernelApp.boot(
      workspaceId: 't',
      kvStorage: InMemoryKvStoragePort(),
    );
    final activation = BundleActivation(system: app.system, bundleId: 'b1');
    final bridge = BundleSessionBridge();
    final session = bridge.openSession(activation);
    // bridge.registerTool is knowledge-wrapping only — the name must
    // start with the `bk.` aliasable prefix so the alias publication
    // path is meaningful.
    bridge.registerTool(
      name: 'bk.demo.echo',
      handler: (args) async => KernelToolResult(content: <KernelContent>[
        KernelTextContent(text: 'echo:${args['x']}'),
      ]),
    );
    final ok = await bridge.callTool(session, 'bk.demo.echo',
        <String, dynamic>{'x': 42});
    expect((ok.content.first as KernelTextContent).text, 'echo:42');
    final err = await bridge.callTool(session, 'missing', <String, dynamic>{});
    expect(err.isError, isTrue);
    await bridge.closeSession(session);
    await app.shutdown();
  });

  test('registerTool rejects non-bk names', () async {
    final bridge = BundleSessionBridge();
    expect(
      () => bridge.registerTool(
        name: 'plain.tool',
        handler: (_) async => KernelToolResult(
          content: <KernelContent>[KernelTextContent(text: '')],
        ),
      ),
      throwsArgumentError,
    );
  });

  test('SessionHandle bulk close on session close', () async {
    final app = await KernelApp.boot(
      workspaceId: 't',
      kvStorage: InMemoryKvStoragePort(),
    );
    final activation = BundleActivation(system: app.system, bundleId: 'b1');
    final bridge = BundleSessionBridge();
    final session = bridge.openSession(activation);
    final h1 = TestSessionHandle('h1');
    final h2 = TestSessionHandle('h2');
    bridge.attach(session, h1);
    bridge.attach(session, h2);
    await bridge.closeSession(session);
    expect(h1.closed, isTrue);
    expect(h2.closed, isTrue);
    await app.shutdown();
  });

  test(
      'MCP Serving — bundle://manifest.json carries the document + reconstructs',
      () async {
    // specs/mcp_serving/spec/1.0 — the server registers the whole bundle
    // document at the well-known `bundle://manifest.json` resource; a client
    // reads it and reconstructs the same bundle (equivalence rule).
    final bridge = BundleSessionBridge();
    final bundle = McpBundleLoader.fromJson(<String, dynamic>{
      'schemaVersion': '1.0.0',
      'manifest': {'id': 'demo.app', 'name': 'Demo', 'version': '1.0.0'},
      // A sibling section travels inside the same document.
      'settings': {
        'groups': [
          {'key': 'general', 'label': 'General', 'fields': <dynamic>[]},
        ],
      },
    });
    bridge.registerResource(
      'bundle://manifest.json',
      (_) async => bundle.toJson(),
      mimeType: 'application/json',
    );
    expect(bridge.listResources(), contains('bundle://manifest.json'));

    final served = await bridge.readResource('bundle://manifest.json')
        as Map<String, dynamic>;
    // The document carries manifest metadata, not just a summary.
    expect((served['manifest'] as Map)['id'], 'demo.app');
    // Reconstruct → identical manifest (serve changes the source, not the run).
    final reconstructed = McpBundleLoader.fromJson(served);
    expect(reconstructed.manifest.id, 'demo.app');
    expect(reconstructed.manifest.version, '1.0.0');
  });

  test('MCP Serving — custom bundle:// resource precedes kb:// resolution',
      () async {
    final bridge = BundleSessionBridge();
    bridge.registerResource(
        'bundle://manifest.json', (_) async => <String, dynamic>{'ok': true});
    expect(await bridge.readResource('bundle://manifest.json'),
        <String, dynamic>{'ok': true});
    // kb:// without a wired system still resolves null-safe (no throw),
    // so existing servers that serve no bundle document are unaffected.
    expect(await bridge.readResource('kb://fact/none'), isNull);
  });

  test('SessionRegistry tracks open + remove', () async {
    final app = await KernelApp.boot(
      workspaceId: 't',
      kvStorage: InMemoryKvStoragePort(),
    );
    final activation = BundleActivation(system: app.system, bundleId: 'b1');
    final bridge = BundleSessionBridge();
    final session = bridge.openSession(activation);
    expect(SessionRegistry.instance.count, 1);
    expect(SessionRegistry.instance.get(session.sessionId), same(session));
    await bridge.closeSession(session);
    expect(SessionRegistry.instance.count, 0);
    await app.shutdown();
  });
}
