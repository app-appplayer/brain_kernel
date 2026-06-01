/// `DispatchContext` — Zone-scoped caller resolution. The bridge wraps
/// every dispatch entry (JS bridge / agent ask / workflow runner / UI
/// mount / scheduler tick) in `runScoped(session, body)`, which forks
/// a Dart Zone with the session stored as a zone value. `current`
/// inside any handler — no matter how many async hops away — returns
/// that session because Dart's Zone follows the async chain.
///
/// Singleton fallback (`_foreground`) covers the host home tab and
/// system surfaces that aren't tied to a single bundle. Concurrent
/// background dispatchers should always use `runScoped`; the
/// foreground singleton must not be relied on outside the visible
/// tab path.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import 'dispatch_session.dart';

/// Zone key. Symbol literal so two imports of this library see the
/// same value.
const Symbol _kSessionZoneKey = #brainKernel.bridge.session;
const Symbol _kMasterZoneKey = #brainKernel.bridge.master;

class DispatchContext {
  DispatchContext._();

  static final DispatchContext instance = DispatchContext._();

  /// Singleton-level marker for the visible foreground tab. Chrome
  /// updates this on tab switch / launcher focus change. Background
  /// dispatchers (JS bridge / workflow runner / agent loop) MUST use
  /// `runScoped` instead so concurrent calls don't fight over this
  /// slot.
  DispatchSession? _foregroundSession;
  bool _foregroundMaster = false;

  /// Active session — Zone wins, foreground singleton fallback,
  /// null when neither is set.
  DispatchSession? get currentSession {
    final z = Zone.current[_kSessionZoneKey];
    if (z is DispatchSession) return z;
    return _foregroundSession;
  }

  /// Whether the active context has master (union) access.
  bool get isMaster {
    final z = Zone.current[_kMasterZoneKey];
    if (z is bool) return z;
    final s = currentSession;
    if (s != null) return s.master;
    return _foregroundMaster;
  }

  /// The bundleId of the active session, or null in host /
  /// master context.
  String? get currentBundleId => currentSession?.bundleId;

  /// Chrome-side foreground setter. Used by host chromes
  /// (vibe_studio's `_setActiveContext`, AppPlayer's launcher focus
  /// change) to update the visible tab marker.
  void setForeground({DispatchSession? session, bool master = false}) {
    _foregroundSession = session;
    _foregroundMaster = master;
  }

  /// Run [body] inside [session]'s zone. Every nested `scopeId`,
  /// `currentSession` read, or `currentBundleId` read inside [body]
  /// (and its async tail) returns this session, regardless of what
  /// the foreground singleton happens to be.
  Future<T> runScoped<T>(
    DispatchSession session,
    Future<T> Function() body,
  ) {
    return runZoned<Future<T>>(
      body,
      zoneValues: <Object?, Object?>{
        _kSessionZoneKey: session,
        _kMasterZoneKey: session.master,
      },
    );
  }

  /// Sync variant — only the synchronous portion of [body] sees
  /// the session. The async tail (anything after the first
  /// `await`) falls back to whatever the outer zone had.
  T runScopedSync<T>(DispatchSession session, T Function() body) {
    return runZoned<T>(
      body,
      zoneValues: <Object?, Object?>{
        _kSessionZoneKey: session,
        _kMasterZoneKey: session.master,
      },
    );
  }

  /// Run [body] as a master-context call (full union access).
  /// Used for host home tab dispatch / admin / sudo. No session,
  /// so `scopeId` pass-throughs every id.
  Future<T> runAsMaster<T>(Future<T> Function() body) {
    return runZoned<Future<T>>(
      body,
      zoneValues: <Object?, Object?>{
        _kSessionZoneKey: null,
        _kMasterZoneKey: true,
      },
    );
  }

  /// Scope a local id according to the active context.
  ///
  /// Rules (4):
  /// 1. master  → pass-through.
  /// 2. no session → pass-through (host home / boot / probes).
  /// 3. id already has '.' → pass-through (caller meant cross-bundle).
  /// 4. otherwise → "<bundleId>.<id>".
  String scopeId(String id) {
    if (id.isEmpty) return id;
    if (isMaster) return id;
    if (id.contains('.')) return id;
    final b = currentBundleId;
    if (b == null || b.isEmpty) return id;
    return '$b.$id';
  }

  List<String> scopeIds(Iterable<String> ids) =>
      <String>[for (final id in ids) scopeId(id)];

  /// Whether the active context should see only its own catalog
  /// entries on `list` / `query` style calls. True for a normal
  /// bundle context, false for master (union) and host-level (no
  /// bundle) callers.
  bool get shouldFilterToOwn {
    if (isMaster) return false;
    final b = currentBundleId;
    return b != null && b.isNotEmpty;
  }

  /// Filter a list of catalog entries down to the active bundle's
  /// own ids. The [idOf] selector pulls the entry's stored id —
  /// which is the full `<bundleId>.<localId>` after prefix scoping.
  /// In master / host context this is a pass-through.
  List<T> filterToOwn<T>(Iterable<T> items, String Function(T) idOf) {
    if (!shouldFilterToOwn) return items.toList(growable: false);
    final prefix = '${currentBundleId!}.';
    return <T>[for (final e in items) if (idOf(e).startsWith(prefix)) e];
  }

  @visibleForTesting
  void resetForTesting() {
    _foregroundSession = null;
    _foregroundMaster = false;
  }
}
