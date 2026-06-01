/// `DispatchSession` — one bundle activation = one session. A session
/// carries the `bundleId` (catalog prefix), a per-activation
/// `sessionId` (for tracking / response routing / lifecycle), and the
/// list of resources the session owns (UI mounts, stream
/// subscriptions, scratch state).
///
/// The host owns activation timing; the bridge owns session
/// bookkeeping. Bundle code (JS / DSL / agent / workflow / matter
/// runtime) never sees a session — it dispatches via the host's
/// bridge helpers and the bridge resolves caller via the Zone.
///
/// Knowledge-operations §14.4 — lifecycle: open → runScoped (Zone fork
/// for each dispatch entry) → attach UI mount / subscription → close
/// (all attached handles cleaned in one pass).
library;

import 'dart:async';

import '../bundle_activation.dart';
import 'package:meta/meta.dart';

/// Lightweight handle for a stream subscription / UI mount / scratch
/// resource owned by a session. The bridge calls [close] in bulk on
/// `session.close()` so background streams don't leak when a tab
/// closes or an app deactivates.
abstract class SessionHandle {
  /// Stable id for diagnostics. Not used by isolation — that's
  /// what the session's bundleId is for.
  String get id;

  /// Best-effort tear-down. Implementations should swallow errors
  /// and return — the bridge calls many of these in a row at
  /// session close and one bad handle must not block the rest.
  FutureOr<void> close();
}

class DispatchSession {
  DispatchSession({
    required this.sessionId,
    required this.bundleId,
    this.activation,
    this.master = false,
  });

  /// Unique per activation. Two activations of the same bundle get
  /// two sessions. Used for routing responses back to the surface
  /// that opened the session, and for lifecycle hooks.
  final String sessionId;

  /// The catalog prefix the session is bound to. Always present —
  /// host surfaces use a marker bundleId (e.g. 'host') when they
  /// don't have a real activation. `scopeId` checks `master` first
  /// so the marker doesn't accidentally prefix host home tab calls.
  final String bundleId;

  /// Optional kernel-side activation handle. Present for normal
  /// bundle activation; null for host home / admin master sessions
  /// that don't own a catalog instance.
  final BundleActivation? activation;

  /// Host-level master flag. Surfaces that need union access to
  /// every bundle (host home tab, sudo / dev mode, admin tools)
  /// open a session with `master: true` — `scopeId` then
  /// pass-throughs every id.
  final bool master;

  /// Whether the session has been closed. `runScoped` and `attach`
  /// short-circuit after close so a late-arriving async tail
  /// doesn't try to dispatch into a torn-down catalog.
  bool _closed = false;
  bool get isClosed => _closed;

  final List<SessionHandle> _handles = <SessionHandle>[];

  /// Register a handle (UI mount / subscription / scratch resource)
  /// with the session. Bulk-closed when the session closes.
  void attach(SessionHandle handle) {
    if (_closed) {
      // Best-effort: tear down immediately rather than silently
      // dropping. The caller's intent was "tie this to the
      // session"; the session being gone means the handle
      // should be too.
      try {
        final r = handle.close();
        if (r is Future) unawaited(r);
      } catch (_) {/* swallow */}
      return;
    }
    _handles.add(handle);
  }

  /// Remove a handle without closing it. The caller has taken
  /// ownership of its lifetime instead.
  void detach(SessionHandle handle) {
    _handles.remove(handle);
  }

  /// Close every attached handle in attach-order. The bridge
  /// drives this from `closeSession`; bundle code never calls it
  /// directly.
  Future<void> closeAttached() async {
    for (final h in List<SessionHandle>.from(_handles)) {
      try {
        final r = h.close();
        if (r is Future) await r;
      } catch (_) {/* swallow — best-effort, see SessionHandle.close */}
    }
    _handles.clear();
    _closed = true;
  }

  @override
  String toString() => 'DispatchSession($sessionId, '
      'bundleId=$bundleId, master=$master, '
      'handles=${_handles.length}${_closed ? ", closed" : ""})';
}

/// In-test helper. Production code creates sessions via the
/// `BundleSessionBridge.openSession` helper, never directly.
@visibleForTesting
class TestSessionHandle implements SessionHandle {
  TestSessionHandle(this.id, {this.onClose});

  @override
  final String id;
  final FutureOr<void> Function()? onClose;
  bool closed = false;

  @override
  FutureOr<void> close() async {
    closed = true;
    if (onClose != null) await onClose!();
  }
}
