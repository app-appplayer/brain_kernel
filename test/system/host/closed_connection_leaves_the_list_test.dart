/// A closed connection is no longer listed as open.
///
/// `connections` is what a host reads to know who still uses a device. Closing
/// used to leave the entry behind, so a link a lending session adopted once
/// looked like a live consumer for the rest of the run — measured 2026-09-17,
/// a removed H723 card kept its serial port because of it.
library;

import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:mcp_client/mcp_client.dart' as cli;
import 'package:test/test.dart';

cli.Client _client() => cli.Client(
      name: 'test',
      version: '0.0.1',
      capabilities: const cli.ClientCapabilities(),
    );

void main() {
  test('an adopted connection leaves the list when it is closed', () async {
    final host = McpClientKernelHost(name: 'host', version: '1');
    final conn = await host.adoptClient(id: 'stm32.h723', client: _client());
    expect(host.connections.map((c) => c.id), ['stm32.h723']);

    await conn.close();

    expect(host.connections, isEmpty);
  });

  test('closing a replaced connection does not take its replacement off the '
      'list', () async {
    final host = McpClientKernelHost(name: 'host', version: '1');
    final first = await host.adoptClient(id: 'esp32.node', client: _client());
    // The first client is not connected, so a second adoption replaces it.
    final second = await host.adoptClient(id: 'esp32.node', client: _client());
    expect(identical(first, second), isFalse, reason: 'premise: replaced');

    await first.close();

    expect(host.connections.map((c) => c.id), ['esp32.node']);
    expect(identical(host.connections.single, second), isTrue);
  });
}
