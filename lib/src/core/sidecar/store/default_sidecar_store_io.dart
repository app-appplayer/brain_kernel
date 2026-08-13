/// Filesystem default. See `default_sidecar_store.dart`.
library;

import 'file_sidecar_store.dart';
import 'sidecar_store.dart';

/// Sidecar records as files.
SidecarStore? defaultSidecarStore() => const FileSidecarStore();
