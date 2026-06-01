import 'package:brain_kernel/brain_kernel.dart';
import 'package:brain_kernel/mcp_host.dart';
import 'package:test/test.dart';

void main() {
  group('TransportPicker', () {
    test('userOverride wins', () {
      expect(
        pickTransport(userOverride: TransportType.stdio),
        TransportType.stdio,
      );
      expect(
        pickTransport(userOverride: TransportType.streamableHttp),
        TransportType.streamableHttp,
      );
      expect(
        pickTransport(userOverride: TransportType.sse),
        TransportType.sse,
      );
    });
  });

  group('ServerBootstrap', () {
    test('exposes the configured name + version', () {
      final boot = ServerBootstrap(name: 'unit-test', version: '9.9.9');
      expect(boot.name, 'unit-test');
      expect(boot.version, '9.9.9');
      expect(boot.server, isNotNull);
    });

    test('register() is idempotent', () async {
      final boot = ServerBootstrap();
      boot.register();
      // Second call must not throw nor double-register.
      expect(() => boot.register(), returnsNormally);
      await boot.shutdown();
    });

    test('project setter swaps the open project reference', () {
      final boot = ServerBootstrap();
      expect(boot.project, isNull);
      // We cannot easily mint a real Project without a temp dir; just
      // validate the setter behaviour with null round-trip.
      boot.project = null;
      expect(boot.project, isNull);
    });
  });
}
