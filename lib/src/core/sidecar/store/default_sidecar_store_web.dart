/// No default where there is no filesystem. See `default_sidecar_store.dart`.
library;

import 'sidecar_store.dart';

/// Null — the host must supply a store.
///
/// Sidecar writes are deliberately non-fatal (NFR-PERSIST-003), so a stub
/// that silently swallowed everything would look identical to working. Null
/// makes the missing decision visible where the project is opened.
///
/// There *is* an implementation for a browser — `opfs_sidecar_store.dart` —
/// and it is deliberately not returned here. It is keyed by origin rather
/// than by person, so it needs the account before it can be built, and
/// defaulting to it would put one person's records where the next person on
/// the same browser reads them. Which records belong in the browser at all,
/// and which have to reach the account to be seen from another device, is
/// the host's decision and not a default.
SidecarStore? defaultSidecarStore() => null;
