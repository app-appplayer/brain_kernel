import 'dart:async';

import 'package:brain_kernel/mcp_host.dart' show SharedResourceSubscriptions;
import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

/// A subscription over a shared client belongs to the LINK, not to whoever
/// asked for it — the server knows only "subscribed" or not.
///
/// Once one connection per device is shared, a device's own screen and a
/// composed tile naming the same device end up on one subscription, and the
/// first to release it stopped the other's stream. Observed as a tile that
/// streamed until the device's own screen was visited and closed, then froze
/// and moved one step per manual Subscribe.
void main() {
  test('the wire call happens once for the first and last consumer', () async {
    final client = _RecordingClient();

    await SharedResourceSubscriptions.subscribe(client, 'sensor://uptime');
    await SharedResourceSubscriptions.subscribe(client, 'sensor://uptime');
    expect(client.subscribed, <String>['sensor://uptime'],
        reason: 'a second consumer must not re-subscribe on the wire');
    expect(SharedResourceSubscriptions.countFor(client, 'sensor://uptime'), 2);

    // One consumer leaves — the other is still watching.
    await SharedResourceSubscriptions.unsubscribe(client, 'sensor://uptime');
    expect(client.unsubscribed, isEmpty,
        reason: 'releasing one consumer must not stop the other stream');

    await SharedResourceSubscriptions.unsubscribe(client, 'sensor://uptime');
    expect(client.unsubscribed, <String>['sensor://uptime'],
        reason: 'the last release ends the subscription');
    expect(SharedResourceSubscriptions.countFor(client, 'sensor://uptime'), 0);
  });

  test('separate uris are counted separately', () async {
    final client = _RecordingClient();
    await SharedResourceSubscriptions.subscribe(client, 'a://x');
    await SharedResourceSubscriptions.subscribe(client, 'b://y');
    await SharedResourceSubscriptions.unsubscribe(client, 'a://x');
    expect(client.unsubscribed, <String>['a://x']);
    expect(SharedResourceSubscriptions.countFor(client, 'b://y'), 1);
  });

  test('two clients do not share a count', () async {
    final a = _RecordingClient();
    final b = _RecordingClient();
    await SharedResourceSubscriptions.subscribe(a, 'sensor://uptime');
    expect(SharedResourceSubscriptions.countFor(b, 'sensor://uptime'), 0);
    expect(b.subscribed, isEmpty);
  });

  test('a failed subscribe leaves no count behind', () async {
    final client = _RecordingClient(failSubscribe: true);
    await expectLater(
      SharedResourceSubscriptions.subscribe(client, 'sensor://uptime'),
      throwsA(anything),
    );
    expect(SharedResourceSubscriptions.countFor(client, 'sensor://uptime'), 0,
        reason: 'a consumer that never got its subscription holds no count — '
            'otherwise a later release drops a live subscriber');
  });

  test('an unbalanced release does not go negative', () async {
    final client = _RecordingClient();
    await SharedResourceSubscriptions.unsubscribe(client, 'sensor://uptime');
    expect(SharedResourceSubscriptions.countFor(client, 'sensor://uptime'), 0);
    await SharedResourceSubscriptions.subscribe(client, 'sensor://uptime');
    expect(client.subscribed, hasLength(1),
        reason: 'the next real subscribe still reaches the wire');
  });
}

class _RecordingClient implements Client {
  _RecordingClient({this.failSubscribe = false});

  final bool failSubscribe;
  final List<String> subscribed = <String>[];
  final List<String> unsubscribed = <String>[];

  @override
  Future<void> subscribeResource(String uri) async {
    if (failSubscribe) throw StateError('nope');
    subscribed.add(uri);
  }

  @override
  Future<void> unsubscribeResource(String uri) async => unsubscribed.add(uri);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
