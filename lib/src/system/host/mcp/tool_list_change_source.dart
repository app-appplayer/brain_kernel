/// `ToolListChangeSource` — capability interface for a connection that tells
/// its host when the server's tool list changed.
///
/// An additive interface beside [KernelClientConnection] rather than a member
/// of it: adding an abstract member would break every `implements` of the
/// connection, and a default that never fires would claim a support the
/// connection does not have. A host that mirrors a server's tools probes
/// `connection is ToolListChangeSource` — the type is the answer.
library;

/// A connection that reports `notifications/tools/list_changed`.
abstract class ToolListChangeSource {
  /// Fires each time the server says its tool list changed. Broadcast: more
  /// than one consumer may watch the same connection.
  Stream<void> get toolsChanged;
}
