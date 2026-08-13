/// The store a sidecar uses when its caller names none.
///
/// Shared by the four sidecars so they answer a missing decision the same
/// way, and the same way [Canonical.openAt] does: default to the platform's
/// store where there is one, and refuse by name where there is not. Sidecar
/// writes are deliberately non-fatal, so a store that silently did nothing
/// would be indistinguishable from one that worked — the first sign would be
/// preferences that never persist.
library;

import 'default_sidecar_store.dart';
import 'sidecar_store.dart';

/// [store] when given, otherwise this platform's default.
///
/// Throws a [StateError] naming [what] when the platform has no default and
/// the caller supplied none.
SidecarStore resolveSidecarStore(SidecarStore? store, String what) {
  if (store != null) return store;
  final resolved = defaultSidecarStore();
  if (resolved != null) return resolved;
  throw StateError(
    '$what needs a sidecar store on this platform: there is no filesystem to '
    'default to. Pass the one this host keeps project records in.',
  );
}
