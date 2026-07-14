import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:test/test.dart';

/// `McpClientKernelHost._openTransport` credential wiring — the token/header
/// options must reach the HTTP wire. Regression for the marketplace
/// service-connect `-32001 Authentication required` (options.accessToken
/// was dropped on the streamableHttp path).
void main() {
  test('streamableHttp connect sends Authorization: Bearer from accessToken',
      () async {
    final received = <String, String>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverDone = server.first.then((req) async {
      req.headers.forEach((k, v) => received[k.toLowerCase()] = v.join(','));
      // Minimal well-formed JSON-RPC error unblocks the client handshake.
      final resp = req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json;
      resp.write(jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'code': -32000, 'message': 'test stub'},
      }));
      await resp.close();
    });

    final host = McpClientKernelHost();
    try {
      await host
          .connect(
            id: 'probe',
            transport: KernelTransportKind.streamableHttp,
            endpoint: 'http://127.0.0.1:${server.port}',
            options: {
              'accessToken': 'tok-123',
              'headers': {'X-Extra': 'yes'},
            },
          )
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Handshake against the stub fails — only the wire headers matter.
    }
    await serverDone.timeout(const Duration(seconds: 5));
    await host.shutdown();
    await server.close(force: true);

    expect(received['authorization'], 'Bearer tok-123');
    expect(received['x-extra'], 'yes');
  });
}
