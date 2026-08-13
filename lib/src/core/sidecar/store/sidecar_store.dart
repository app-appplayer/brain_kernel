/// Where a project's sidecar records live.
///
/// The sidecar files — preferences, undo, history, chat — are the kernel's
/// own bookkeeping beside a project. Each one reads a whole document, writes a
/// whole document, or appends a line. Nothing more, and nothing that needs a
/// filesystem in particular.
///
/// Declaring that as a port is what lets the kernel run where there is no
/// filesystem. **This file names no platform library**, so importing it does
/// not drag one in — the implementations do that, and a host that has neither
/// supplies its own.
///
/// `ref` is an opaque address. On a disk it is a path; elsewhere it is a key,
/// and nothing above this layer reads it either way.
library;

/// Read, write, and append the records that sit beside a project.
///
/// Every method is total: a missing record reads as null rather than throwing,
/// because "nothing has been written yet" is the ordinary first state and not
/// a failure worth an exception.
abstract interface class SidecarStore {
  /// The whole record, or null when it has never been written.
  Future<String?> read(String ref);

  /// Replace the whole record.
  ///
  /// Implementations that can, write atomically — a half-written preferences
  /// file is worse than an absent one, because the absent one is recoverable
  /// by the same code path that handles a first run.
  Future<void> write(String ref, String contents);

  /// Add one line to the end.
  ///
  /// Separate from [write] because history and chat are append-only, and
  /// rewriting the whole record to add a line costs the whole record on every
  /// turn.
  Future<void> append(String ref, String line);

  /// Whether anything has been written at [ref].
  Future<bool> exists(String ref);

  /// Remove the record. No-op when it is already absent.
  Future<void> remove(String ref);

  /// Copy [from] onto [to], overwriting. No-op when [from] is absent.
  ///
  /// Here rather than composed from read + write because an implementation
  /// may be able to do it without materialising the contents.
  Future<void> copy(String from, String to);
}
