/// The browser-only surface of the kernel.
///
/// Kept apart from `brain_kernel.dart` because everything here reaches
/// `dart:js_interop`, which has no implementation off the web compilers: a VM
/// or native build that reaches it does not compile at all. A browser host
/// imports this barrel; every other host imports the main one and never sees
/// these types.
library;

export 'src/core/sidecar/store/opfs_sidecar_store.dart';
