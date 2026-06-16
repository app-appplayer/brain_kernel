/// Tests for `client_tools` — the kernel-provided `mcp.*` capability
/// (mcp_client as host tools). The app drives connections through the
/// host; the host only relays. Registered through [HostToolRegistry]
/// (general-tool path), never the `bk.*` facade surface.
library;

import 'dart:convert' show jsonDecode;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('client_tools (mcp.* — app-driven)', () {
    late Map<String, KernelToolHandler> dispatcher;
    late InProcessKernelServerHost endpoint;
    late HostToolRegistry registry;

    setUp(() {
      dispatcher = <String, KernelToolHandler>{};
      endpoint = InProcessKernelServerHost(
        name: 'client_tools_test',
        version: '0.0.1',
      );
      registry = HostToolRegistry(
        endpoint: endpoint,
        attachToDispatcher: (name, handler) => dispatcher[name] = handler,
        detachFromDispatcher: dispatcher.remove,
      );
    });

    test('registers the mcp.* surface under the namespace', () {
      final exposed = registerClientTools(registry, _FakeHost());
      expect(
        exposed,
        containsAll(<String>[
          'mcp.connect',
          'mcp.list_tools',
          'mcp.call_tool',
          'mcp.read_resource',
          'mcp.list_resources',
          'mcp.disconnect',
        ]),
      );
      expect(
        endpoint.toolDefinitions.map((d) => d.name),
        contains('mcp.call_tool'),
      );
    });

    test('app drives connect → call_tool; host only relays', () async {
      final host = _FakeHost();
      registerClientTools(registry, host);

      final connected = await dispatcher['mcp.connect']!(<String, dynamic>{
        'id': 'weather',
        'transport': 'streamableHttp',
        'endpoint': 'https://example.test/mcp',
      });
      expect(connected.isError, isFalse);

      final called = await dispatcher['mcp.call_tool']!(<String, dynamic>{
        'id': 'weather',
        'tool': 'forecast',
        'args': <String, dynamic>{'city': 'X'},
      });
      expect(called.isError, isFalse);
      expect(host.lastCall, <String, dynamic>{
        'tool': 'forecast',
        'args': <String, dynamic>{'city': 'X'},
      });
    });

    test('read_resource pulls a remote document', () async {
      final host = _FakeHost();
      registerClientTools(registry, host);
      await dispatcher['mcp.connect']!(<String, dynamic>{
        'id': 'dash',
        'transport': 'sse',
      });
      final read = await dispatcher['mcp.read_resource']!(<String, dynamic>{
        'id': 'dash',
        'uri': 'ui://dashboard',
      });
      expect(read.isError, isFalse);
      final decoded = jsonDecode(
        (read.content.first as KernelTextContent).text,
      ) as Map<String, dynamic>;
      expect((decoded['contents'] as List).first['uri'], 'ui://dashboard');
    });

    test('unknown connection id is a coded error, not a throw', () async {
      registerClientTools(registry, _FakeHost());
      final result = await dispatcher['mcp.call_tool']!(<String, dynamic>{
        'id': 'missing',
        'tool': 'x',
      });
      expect(result.isError, isTrue);
      final decoded = jsonDecode(
        (result.content.first as KernelTextContent).text,
      ) as Map<String, dynamic>;
      expect(decoded['code'], 'mcp.not_connected');
    });

    test('bad transport is a coded error', () async {
      registerClientTools(registry, _FakeHost());
      final result = await dispatcher['mcp.connect']!(<String, dynamic>{
        'id': 'x',
        'transport': 'carrier-pigeon',
      });
      expect(result.isError, isTrue);
      final decoded = jsonDecode(
        (result.content.first as KernelTextContent).text,
      ) as Map<String, dynamic>;
      expect(decoded['code'], 'mcp.bad_transport');
    });

    test('clientTools() exposes full-name handlers for direct wiring', () {
      final tools = clientTools(_FakeHost());
      expect(tools.keys, contains('mcp.connect'));
      expect(tools.keys, contains('mcp.disconnect'));
    });

    test('clientTools() handlers are raw InProcessToolHandlers — the '
        'shape a host dispatcher (e.g. AppPlayer ToolDispatcher) consumes',
        () async {
      // Mirror AppPlayer: register the raw map straight into an
      // in-process dispatcher and call it — result is the JSON-shaped
      // map, not a wrapped envelope.
      final host = _FakeHost();
      final raw = clientTools(host);
      final connected = await raw['mcp.connect']!(<String, dynamic>{
        'id': 'srv',
        'transport': 'stdio',
      });
      expect((connected! as Map)['ok'], isTrue);

      final called = await raw['mcp.call_tool']!(<String, dynamic>{
        'id': 'srv',
        'tool': 'forecast',
        'args': <String, dynamic>{'city': 'X'},
      });
      expect((called! as Map)['ok'], isTrue);
      expect(host.lastCall, <String, dynamic>{
        'tool': 'forecast',
        'args': <String, dynamic>{'city': 'X'},
      });
    });
  });
}

class _FakeHost implements KernelClientHost {
  final Map<String, _FakeConnection> _conns = <String, _FakeConnection>{};
  Map<String, dynamic>? lastCall;

  @override
  Future<KernelClientConnection> connect({
    required String id,
    required KernelTransportKind transport,
    String? endpoint,
    Map<String, dynamic>? options,
  }) async {
    final connection = _FakeConnection(
      id: id,
      onCall: (tool, args) =>
          lastCall = <String, dynamic>{'tool': tool, 'args': args},
    );
    _conns[id] = connection;
    return connection;
  }

  @override
  Iterable<KernelClientConnection> get connections => _conns.values;

  @override
  Future<void> shutdown() async => _conns.clear();
}

class _FakeConnection implements KernelClientConnection {
  _FakeConnection({required this.id, this.onCall});

  @override
  final String id;

  final void Function(String tool, Map<String, dynamic> args)? onCall;

  @override
  bool get isConnected => true;

  @override
  Future<List<KernelToolDescriptor>> listTools() async =>
      const <KernelToolDescriptor>[
        KernelToolDescriptor(name: 'forecast', description: 'weather'),
      ];

  @override
  Future<KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    onCall?.call(name, args);
    return KernelToolResult(
      content: <KernelContent>[KernelTextContent(text: '{"ok":true}')],
      isError: false,
    );
  }

  @override
  Future<KernelReadResourceResult> readResource(String uri) async =>
      KernelReadResourceResult(
        contents: <KernelResourceContent>[
          KernelResourceContent(
            uri: uri,
            text: '<dashboard/>',
            mimeType: 'text/html',
          ),
        ],
      );

  @override
  Future<List<KernelResourceDescriptor>> listResources() async =>
      const <KernelResourceDescriptor>[];

  @override
  Future<void> close() async {}
}
