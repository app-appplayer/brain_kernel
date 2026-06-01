/// `SessionRegistry` — bridge-level process singleton tracking every
/// open session. Independent of the kernel `BundleActivationRegistry`
/// (which tracks catalogs, not sessions). Two activations of the
/// same bundle yield two sessions, both attached to the same
/// BundleActivation.
///
/// Lifecycle hooks: the bridge calls `register` on `openSession` and
/// `remove` on `closeSession`. Hosts inspect the registry for admin
/// / debug surfaces (list active sessions, force-close, count
/// concurrent dispatches by bundle, etc.).
library;

import 'package:meta/meta.dart';

import 'dispatch_session.dart';

class SessionRegistry {
  SessionRegistry._();

  static final SessionRegistry instance = SessionRegistry._();

  final Map<String, DispatchSession> _sessions = <String, DispatchSession>{};

  Iterable<DispatchSession> get all => _sessions.values;

  int get count => _sessions.length;

  DispatchSession? get(String sessionId) => _sessions[sessionId];

  /// Sessions for a given bundleId. Empty when the bundle is not
  /// currently activated; multiple entries when the same bundle is
  /// activated more than once.
  List<DispatchSession> forBundle(String bundleId) => <DispatchSession>[
        for (final s in _sessions.values)
          if (s.bundleId == bundleId) s,
      ];

  void register(DispatchSession session) {
    _sessions[session.sessionId] = session;
  }

  /// Remove a session entry. Does not call `closeAttached` — the
  /// bridge's `closeSession` calls that first, then `remove`.
  void remove(String sessionId) {
    _sessions.remove(sessionId);
  }

  @visibleForTesting
  void clearForTesting() {
    _sessions.clear();
  }
}
