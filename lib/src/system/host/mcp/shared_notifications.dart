import 'package:mcp_client/mcp_client.dart' show Client;

/// Fans a client's notifications out to several listeners.
///
/// `Client.onNotification` keeps **one handler per method** — registering a
/// second one silently replaces the first. That was harmless while every
/// consumer had its own client. Once one connection per device is shared, it
/// is not: a device's own screen registering for
/// `notifications/resources/updated` took the slot from the composed tile
/// listening on the same link, and the tile stopped receiving updates for
/// good. Closing the screen did not give it back — the registration was not
/// lost, its owner had changed.
///
/// Nothing in the failure is visible: the subscription is still live on the
/// device, the socket is still up, and pressing the page's own `Subscribe`
/// moves the reading exactly one step, because that step is the read the
/// subscribe action performs — not an update.
///
/// So the client is registered **once** per method here, and every listener
/// gets a copy. Registrations hang off the client (an [Expando]) so they are
/// shared without threading a registry through, and disappear with it.
class SharedClientNotifications {
  SharedClientNotifications._();

  static final Expando<Map<String, List<_Listener>>> _listeners =
      Expando<Map<String, List<_Listener>>>('mcp.sharedNotifications');

  static Map<String, List<_Listener>> _of(Client client) =>
      _listeners[client] ??= <String, List<_Listener>>{};

  /// Adds [handler] for [method] and returns a function that removes it.
  ///
  /// A listener that throws does not stop the others — one consumer's bad
  /// handler must not silence every other view on the same device.
  static void Function() add(
    Client client,
    String method,
    Future<void> Function(Map<String, dynamic> params) handler,
  ) {
    final byMethod = _of(client);
    final listeners = byMethod.putIfAbsent(method, () {
      // First listener for this method on this client: take the single slot.
      client.onNotification(method, (params) async {
        final current = _of(client)[method];
        if (current == null) return;
        for (final l in List<_Listener>.of(current)) {
          try {
            await l.handler(params);
          } catch (_) {
            // Deliberately swallowed — see the class doc.
          }
        }
      });
      return <_Listener>[];
    });

    final listener = _Listener(handler);
    listeners.add(listener);
    return () {
      final current = _of(client)[method];
      current?.remove(listener);
    };
  }

  /// How many listeners [method] currently has. For tests and diagnostics.
  static int countFor(Client client, String method) =>
      _of(client)[method]?.length ?? 0;
}

class _Listener {
  _Listener(this.handler);
  final Future<void> Function(Map<String, dynamic> params) handler;
}
