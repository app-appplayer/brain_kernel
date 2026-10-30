import 'dart:async';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart';
import 'package:brain_kernel/mcp_host.dart';
import 'package:mcp_client/mcp_client.dart' as cli;
import 'package:test/test.dart';

/// A server's own hints about its tools reach the host, a tool-list change is
/// reported, and a program started over stdio receives its environment.
void main() {
  group('tool hints and list changes', () {
    late _FakeClient client;
    late McpClientKernelHost host;

    setUp(() {
      client = _FakeClient();
      host = McpClientKernelHost();
    });

    test('the descriptors carry destructiveHint and readOnlyHint as the server '
        'said them, and null when it said nothing', () async {
      client.tools = [
        cli.Tool(
          name: 'wipe',
          inputSchema: const {'type': 'object'},
          annotations: cli.ToolAnnotations(destructiveHint: true),
        ),
        cli.Tool(
          name: 'probe',
          inputSchema: const {'type': 'object'},
          annotations: cli.ToolAnnotations(readOnlyHint: true),
        ),
        cli.Tool(name: 'plain', inputSchema: const {'type': 'object'}),
      ];
      final conn = await host.adoptClient(id: 'x', client: client);
      final byName = {for (final t in await conn.listTools()) t.name: t};

      expect(byName['wipe']!.destructiveHint, isTrue);
      expect(byName['wipe']!.readOnlyHint, isNull);
      expect(byName['probe']!.readOnlyHint, isTrue);
      expect(byName['probe']!.destructiveHint, isNull);
      expect(byName['plain']!.destructiveHint, isNull);
      expect(byName['plain']!.readOnlyHint, isNull);
    });

    test('a connection reports the server changing its tool list', () async {
      final conn = await host.adoptClient(id: 'x', client: client);
      expect(conn, isA<ToolListChangeSource>());
      var changes = 0;
      final sub = (conn as ToolListChangeSource).toolsChanged.listen((_) => changes++);

      await client.fire('notifications/tools/list_changed');
      await client.fire('notifications/tools/list_changed');
      await Future<void>.delayed(Duration.zero);
      expect(changes, 2);

      await sub.cancel();
      await conn.close();
    });

    test('a connection that has been closed no longer reports', () async {
      final conn = await host.adoptClient(id: 'x', client: client);
      final events = <void>[];
      (conn as ToolListChangeSource).toolsChanged.listen(events.add);
      await conn.close();
      await client.fire('notifications/tools/list_changed');
      expect(events, isEmpty);
    });
  });

  group('stdio environment', () {
    test('a program started over stdio receives options.env', () async {
      // A one-reply MCP server that names itself after the variable it was
      // given: if the variable did not arrive, the name says so.
      const server = r'''
import json, os, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "serverInfo": {"name": os.environ.get("PLUGIN_TEST_VAR", "MISSING"), "version": "1"}}}), flush=True)
    elif msg.get("id") is not None:
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {}}), flush=True)
''';
      final host = McpClientKernelHost();
      final conn = await host.connect(
        id: 'env-test',
        transport: KernelTransportKind.stdio,
        options: {
          'command': Platform.isWindows ? 'python' : 'python3',
          'args': ['-u', '-c', server],
          'env': {'PLUGIN_TEST_VAR': 'arrived'},
        },
      );
      addTearDown(host.shutdown);

      final info = (conn as dynamic).client.serverInfo as Map<String, dynamic>?;
      expect(info?['name'], 'arrived');
    });
  });
}

class _FakeClient implements cli.Client {
  final Map<String, Function(Map<String, dynamic>)> _handlers = {};
  List<cli.Tool> tools = const [];

  @override
  bool get isConnected => true;

  @override
  void onNotification(String method, Function(Map<String, dynamic>) handler) {
    _handlers[method] = handler;
  }

  Future<void> fire(String method) async {
    final h = _handlers[method];
    if (h != null) await h(<String, dynamic>{});
  }

  @override
  Future<List<cli.Tool>> listTools({
    Map<String, dynamic>? meta,
    cli.RequestOptions? options,
  }) async =>
      tools;

  @override
  void disconnect() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
