/// Filesystem default. See `default_canonical_storage.dart`.
library;

import 'canonical_storage_port.dart';
import 'manifest_only_canonical_storage.dart';

/// The kernel's manifest storage, reading and writing real files.
CanonicalStoragePort? defaultCanonicalStorage() =>
    const ManifestOnlyCanonicalStorage();
