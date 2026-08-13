/// The store sidecar records use when the host names none.
///
/// Same shape, and same reason, as `default_canonical_storage.dart`: a
/// convenient default must not bind the platform for every caller that
/// touches a project.
library;

export 'default_sidecar_store_web.dart'
    if (dart.library.io) 'default_sidecar_store_io.dart';
