/// A [SidecarStore] over the browser's origin-private file system.
///
/// **Web only.** This file names `dart:js_interop`, which has no
/// implementation off the web compilers, so it must never be reached from a
/// VM or native build. It is not exported from the package barrel; a browser
/// host reaches it through `brain_kernel_web.dart`, and the conditional
/// default in `default_sidecar_store.dart` is what keeps platform-neutral
/// code from naming it at all.
///
/// ## Why OPFS and not IndexedDB
///
/// Three of the four sidecar records — undo, history, chat — are append-only
/// logs, and appending is the operation the two media do not share. OPFS
/// writes at an offset, so a line costs a line. IndexedDB stores a value
/// whole: appending means reading the log back, concatenating, and putting
/// all of it, so a chat that reaches a megabyte pays a megabyte per turn and
/// a session pays the square of its own length. Everything else is a tie —
/// both draw on the same origin quota, and both clear in one call — and a
/// path-shaped `ref` lands on a directory tree without translation.
///
/// The cost is reach: OPFS needs a secure context, and some embedded webviews
/// do not have it. That surfaces as a failure to construct rather than as a
/// store that quietly drops writes, which is the trade this port was split
/// for.
///
/// ## Scope
///
/// OPFS is keyed by **origin, not by person**. Two people using the same
/// browser share it. So the account is part of the root path and not
/// optional — [OpfsSidecarStore.forAccount] is the only constructor, and
/// [wipe] is what a host calls when a session ends so nothing of the previous
/// person is left for the next one.
///
/// This is a browser-local store, which is to say a cache. It is not where
/// state that has to reach another device lives — that is the account, and
/// deciding which records go there belongs to the host, not here.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'sidecar_store.dart';

/// Sidecar records in the origin-private file system, under one account.
class OpfsSidecarStore implements SidecarStore {
  OpfsSidecarStore._(this._rootSegments);

  /// A store rooted at [accountKey].
  ///
  /// [accountKey] is whatever the host uses to tell one signed-in person from
  /// another; it is only ever a directory name here. It may not be empty, and
  /// it may not contain a separator — a key that walked up out of its own
  /// root would put one person's records where another's are read.
  factory OpfsSidecarStore.forAccount(String accountKey) {
    if (accountKey.isEmpty ||
        accountKey.contains('/') ||
        accountKey.contains('\\') ||
        accountKey == '.' ||
        accountKey == '..') {
      throw ArgumentError.value(
        accountKey,
        'accountKey',
        'must be a single non-empty path segment',
      );
    }
    return OpfsSidecarStore._(<String>[_rootDirName, accountKey]);
  }

  /// Top-level directory, so the store shares the origin with whatever else
  /// the host keeps there instead of assuming it owns the root.
  static const String _rootDirName = 'brain_kernel_sidecar';

  final List<String> _rootSegments;

  @override
  Future<String?> read(String ref) async {
    final file = await _fileHandle(ref, create: false);
    if (file == null) return null;
    final blob = await file.getFile().toDart;
    return (await blob.text().toDart).toDart;
  }

  @override
  Future<void> write(String ref, String contents) async {
    final file = await _fileHandle(ref, create: true);
    final writable = await file!.createWritable().toDart;
    // The default truncates, and the spec has the stream land on the real
    // file only at close — so a torn write leaves the previous contents
    // rather than half of the new ones.
    await writable.write(contents.toJS).toDart;
    await writable.close().toDart;
  }

  @override
  Future<void> append(String ref, String line) async {
    final file = await _fileHandle(ref, create: true);
    final existing = await file!.getFile().toDart;
    final end = existing.size;
    final writable = await file
        .createWritable(web.FileSystemCreateWritableOptions(
          keepExistingData: true,
        ))
        .toDart;
    await writable.seek(end).toDart;
    await writable.write(line.toJS).toDart;
    await writable.close().toDart;
  }

  @override
  Future<bool> exists(String ref) async => await _fileHandle(
        ref,
        create: false,
      ) !=
      null;

  @override
  Future<void> remove(String ref) async {
    final segments = _resolve(ref);
    final parent = await _directory(
      segments.sublist(0, segments.length - 1),
      create: false,
    );
    if (parent == null) return;
    try {
      await parent.removeEntry(segments.last).toDart;
    } catch (_) {
      // Already absent, which the port defines as a no-op.
    }
  }

  @override
  Future<void> copy(String from, String to) async {
    final contents = await read(from);
    if (contents == null) return;
    await write(to, contents);
  }

  /// Drop everything this account has written.
  ///
  /// For the end of a session. OPFS belongs to the origin rather than to a
  /// person, so without this the next person on the same browser inherits the
  /// previous one's records.
  Future<void> wipe() async {
    final parent = await _directory(
      _rootSegments.sublist(0, _rootSegments.length - 1),
      create: false,
    );
    if (parent == null) return;
    try {
      await parent
          .removeEntry(
            _rootSegments.last,
            web.FileSystemRemoveOptions(recursive: true),
          )
          .toDart;
    } catch (_) {
      // Nothing was ever written under this account.
    }
  }

  /// [ref] split into path segments beneath the account root.
  ///
  /// A `ref` is opaque above this layer and path-shaped below it. Empty and
  /// `.` segments drop out; `..` is refused rather than followed, since a ref
  /// that climbed out of the root would read another account's records.
  List<String> _resolve(String ref) {
    final parts = ref.split(RegExp(r'[/\\]'));
    final segments = <String>[..._rootSegments];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        throw ArgumentError.value(ref, 'ref', 'must not climb out of its root');
      }
      segments.add(part);
    }
    if (segments.length == _rootSegments.length) {
      throw ArgumentError.value(ref, 'ref', 'names no record');
    }
    return segments;
  }

  /// The directory at [segments], or null when [create] is false and some
  /// part of the path has never been written.
  Future<web.FileSystemDirectoryHandle?> _directory(
    List<String> segments, {
    required bool create,
  }) async {
    var dir = await web.window.navigator.storage.getDirectory().toDart;
    for (final segment in segments) {
      try {
        dir = await dir
            .getDirectoryHandle(
              segment,
              web.FileSystemGetDirectoryOptions(create: create),
            )
            .toDart;
      } catch (_) {
        // With create: false this is the ordinary "not written yet". With
        // create: true it is a real failure, and rethrowing keeps it from
        // being reported as absence.
        if (create) rethrow;
        return null;
      }
    }
    return dir;
  }

  /// The file at [ref], or null when [create] is false and it is absent.
  /// Never null when [create] is true.
  Future<web.FileSystemFileHandle?> _fileHandle(
    String ref, {
    required bool create,
  }) async {
    final segments = _resolve(ref);
    final parent = await _directory(
      segments.sublist(0, segments.length - 1),
      create: create,
    );
    if (parent == null) return null;
    try {
      return await parent
          .getFileHandle(
            segments.last,
            web.FileSystemGetFileOptions(create: create),
          )
          .toDart;
    } catch (_) {
      if (create) rethrow;
      return null;
    }
  }
}
