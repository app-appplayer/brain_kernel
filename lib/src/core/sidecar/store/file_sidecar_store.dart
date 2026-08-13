/// Sidecar records on a filesystem.
///
/// Split from the port declaration so that importing the port does not import
/// `dart:io`. A host without a filesystem supplies its own store and never
/// reaches this file.
library;

import 'dart:io';

import 'sidecar_store.dart';

/// Reads and writes sidecar records as files at the given paths.
class FileSidecarStore implements SidecarStore {
  const FileSidecarStore();

  @override
  Future<String?> read(String ref) async {
    final file = File(ref);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String ref, String contents) async {
    final file = File(ref);
    await file.parent.create(recursive: true);
    // Write beside, then rename. A rename is atomic on the platforms this
    // runs on, so a crash mid-write leaves the previous record intact rather
    // than a truncated one — and a truncated preferences file is worse than
    // an absent one, which the first-run path already handles.
    final tmp = File('$ref.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(ref);
  }

  @override
  Future<void> append(String ref, String line) async {
    final file = File(ref);
    await file.parent.create(recursive: true);
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  @override
  Future<bool> exists(String ref) => File(ref).exists();

  @override
  Future<void> remove(String ref) async {
    final file = File(ref);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> copy(String from, String to) async {
    final source = File(from);
    if (!await source.exists()) return;
    final destination = File(to);
    await destination.parent.create(recursive: true);
    await source.copy(to);
  }
}
