/// The storage a [Canonical] uses when the host names none.
///
/// Exists so that `Canonical.open` can keep its convenient default without
/// that default binding the platform. Importing the port used to be enough to
/// pull in a filesystem implementation, which meant every caller of Canonical
/// carried `dart:io` whether it wanted one or not.
///
/// Where there is a filesystem the default is the kernel's own manifest
/// storage. Where there is not, there is **no default** — a host that keeps
/// canonicals somewhere else has to say where, and being told that is better
/// than a filesystem call that fails later with a path nobody chose.
library;

export 'default_canonical_storage_web.dart'
    if (dart.library.io) 'default_canonical_storage_io.dart';
