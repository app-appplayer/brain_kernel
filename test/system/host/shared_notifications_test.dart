import 'dart:async';

import 'package:brain_kernel/mcp_host.dart' show SharedClientNotifications;
import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// `Client.onNotification` keeps ONE handler per method, so on a client shared
/// by several consumers the last registration silences the rest.
///
/// That is what stopped a composed tile the moment the device's own screen was
/// opened: the tile's subscription stayed live, the socket stayed up, and no
/// layer reported anything — the tile simply never received another update.
/// Pressing its `Subscribe` moved the reading exactly one step, because that
/// step is the read the subscribe action performs, not an update.
void main() {
  test('every listener receives the notification, not just the last',
      () async {
    final client = _FakeClient();
    final seen = <String>[];

    SharedClientNotifications.add(client, 'm', (p) async => seen.add('a'));
    SharedClientNotifications.add(client, 'm', (p) async => seen.add('b'));

    expect(client.registrations, 1,
        reason: 'the single slot is taken once, not per listener');
    await client.fire('m', <String, dynamic>{'uri': 'x'});
    expect(seen, <String>['a', 'b']);
  });

  test('removing one listener leaves the others receiving', () async {
    final client = _FakeClient();
    final seen = <String>[];
    final removeA =
        SharedClientNotifications.add(client, 'm', (p) async => seen.add('a'));
    SharedClientNotifications.add(client, 'm', (p) async => seen.add('b'));

    removeA();
    await client.fire('m', <String, dynamic>{});
    expect(seen, <String>['b'],
        reason: 'one consumer leaving must not silence the other');
  });

  test('a listener that throws does not silence the rest', () async {
    final client = _FakeClient();
    final seen = <String>[];
    SharedClientNotifications.add(client, 'm', (p) async {
      throw StateError('boom');
    });
    SharedClientNotifications.add(client, 'm', (p) async => seen.add('b'));

    await client.fire('m', <String, dynamic>{});
    expect(seen, <String>['b']);
  });

  test('methods and clients are kept apart', () async {
    final a = _FakeClient();
    final b = _FakeClient();
    SharedClientNotifications.add(a, 'm', (p) async {});
    expect(SharedClientNotifications.countFor(a, 'm'), 1);
    expect(SharedClientNotifications.countFor(a, 'other'), 0);
    expect(SharedClientNotifications.countFor(b, 'm'), 0);
  });
}

class _FakeClient implements Client {
  final Map<String, Function(Map<String, dynamic>)> _handlers = {};
  int registrations = 0;

  @override
  void onNotification(
      String method, Function(Map<String, dynamic>) handler) {
    registrations++;
    _handlers[method] = handler;
  }

  Future<void> fire(String method, Map<String, dynamic> params) async {
    final h = _handlers[method];
    if (h != null) await h(params);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
