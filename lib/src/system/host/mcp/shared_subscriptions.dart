import 'package:mcp_client/mcp_client.dart' show Client;

/// Reference-counted `resources/subscribe` over a client several consumers
/// share.
///
/// A device subscription is a property of the LINK, not of whoever asked for
/// it: the server knows only "subscribed" or "not". Once one connection per
/// device is shared — a device's own screen and a composed tile naming the same
/// device — two consumers end up on one subscription, and the first to release
/// it stops the stream for the other. Observed as a composed tile that streamed
/// until the device's own screen was visited and closed, after which it froze
/// and only moved one step per manual `Subscribe`.
///
/// So the wire call is made when the count goes 0 → 1, and again when it
/// returns to 0. Everything in between is bookkeeping.
///
/// Counts hang off the client itself (an [Expando]), so they are shared by
/// every consumer of that client without threading a registry through, and
/// they disappear with it — no map to clean up when a device goes away.
class SharedResourceSubscriptions {
  SharedResourceSubscriptions._();

  static final Expando<Map<String, int>> _counts =
      Expando<Map<String, int>>('mcp.sharedSubscriptions');

  static Map<String, int> _of(Client client) =>
      _counts[client] ??= <String, int>{};

  /// Subscribes on the wire only for the FIRST consumer of [uri].
  static Future<void> subscribe(Client client, String uri) async {
    final counts = _of(client);
    final next = (counts[uri] ?? 0) + 1;
    counts[uri] = next;
    if (next > 1) return;
    try {
      await client.subscribeResource(uri);
    } catch (_) {
      // The consumer never got its subscription, so it must not hold a count —
      // otherwise a later release would drop the count of a live subscriber.
      final c = _of(client);
      final back = (c[uri] ?? 1) - 1;
      if (back <= 0) {
        c.remove(uri);
      } else {
        c[uri] = back;
      }
      rethrow;
    }
  }

  /// Unsubscribes on the wire only when the LAST consumer of [uri] releases.
  static Future<void> unsubscribe(Client client, String uri) async {
    final counts = _of(client);
    final current = counts[uri] ?? 0;
    if (current <= 1) {
      counts.remove(uri);
      await client.unsubscribeResource(uri);
      return;
    }
    counts[uri] = current - 1;
  }

  /// How many consumers currently hold [uri]. For tests and diagnostics.
  static int countFor(Client client, String uri) => _of(client)[uri] ?? 0;
}
