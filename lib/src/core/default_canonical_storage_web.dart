/// No default where there is no filesystem. See
/// `default_canonical_storage.dart`.
library;

import 'canonical_storage_port.dart';

/// Null — the host must supply a storage.
///
/// Returning null rather than a stub that throws on first use: the failure
/// then happens where the canonical is opened, naming the missing decision,
/// instead of somewhere deep in a read whose path nobody chose.
CanonicalStoragePort? defaultCanonicalStorage() => null;
