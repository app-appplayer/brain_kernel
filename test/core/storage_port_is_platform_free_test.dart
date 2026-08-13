/// The storage port must be nameable without a filesystem.
///
/// A host that supplies its own storage — a browser keeping state in the
/// account rather than on a disk — has to implement [CanonicalStoragePort].
/// If declaring that port drags `dart:io` into the import graph, that host
/// cannot build at all, and the failure is a compile error far from its
/// cause.
///
/// Asserted on the **import graph**, not by compiling. On the web `dart:io`
/// resolves to a stub that throws at run time rather than failing the build,
/// so "it compiles for web" is true of the filesystem implementation too and
/// proves nothing.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

/// Everything reachable from [entry] by `import` / `export`, within this
/// package. Returns the platform libraries and external packages found.
({Set<String> dartLibs, Set<String> packages, int files}) reachableFrom(
  String entry,
) {
  final importPattern =
      RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
  final seen = <String>{};
  final dartLibs = <String>{};
  final packages = <String>{};
  final stack = <String>[entry];

  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (!seen.add(current)) continue;
    final file = File(current);
    if (!file.existsSync()) continue;

    for (final match in importPattern.allMatches(file.readAsStringSync())) {
      final uri = match.group(1)!;
      if (uri.startsWith('dart:')) {
        dartLibs.add(uri);
      } else if (uri.startsWith('package:brain_kernel/')) {
        stack.add('lib/${uri.substring('package:brain_kernel/'.length)}');
      } else if (uri.startsWith('package:')) {
        packages.add(uri.split('/').first);
      } else {
        stack.add(Uri.file(current).resolve(uri).toFilePath());
      }
    }
  }
  return (dartLibs: dartLibs, packages: packages, files: seen.length);
}

void main() {
  const port = 'lib/src/core/canonical_storage_port.dart';
  const filesystemImpl = 'lib/src/core/manifest_only_canonical_storage.dart';
  const sidecarPort = 'lib/src/core/sidecar/store/sidecar_store.dart';

  test('declaring a storage port pulls in no platform library', () {
    for (final declaration in <String>[port, sidecarPort]) {
      final reached = reachableFrom(declaration);

      expect(reached.dartLibs, isEmpty,
          reason: '$declaration — a host implementing this port must not be '
              'handed a platform dependency for doing so');
      expect(reached.packages, isEmpty, reason: declaration);
    }
  });

  test('and no other file either', () {
    // One file each, so nothing can quietly grow an import later without this
    // failing.
    expect(reachableFrom(port).files, 1);
    expect(reachableFrom(sidecarPort).files, 1);
  });

  group('what the kernel can reach without a filesystem', () {
    // These are the types a host on a platform with no `dart:io` has to name.
    // Each one used to drag the filesystem in through a convenience default,
    // which is the shape worth pinning: the coupling was never an import
    // anyone wrote on purpose.
    const platformFree = <String>[
      'lib/src/core/canonical.dart',
      'lib/src/core/sidecar/prefs.dart',
      'lib/src/core/sidecar/undo_log.dart',
      'lib/src/core/sidecar/history_log.dart',
      'lib/src/core/sidecar/chat_log.dart',
    ];

    for (final source in platformFree) {
      test('${source.split('/').last} reaches no dart:io', () {
        expect(reachableFrom(source).dartLibs, isNot(contains('dart:io')));
      });
    }
  });

  group('the browser adapter stays off every other platform', () {
    // `dart:js_interop` has no implementation outside the web compilers, so
    // unlike `dart:io` it cannot be reached and then fail at run time — a VM
    // build that reaches it does not build. The barrel is the way it would
    // get there by accident.
    const opfs = 'lib/src/core/sidecar/store/opfs_sidecar_store.dart';

    for (final barrel in <String>[
      'lib/brain_kernel.dart',
      'lib/mcp_client.dart',
      'lib/mcp_host.dart',
    ]) {
      test('$barrel reaches no web library', () {
        final reached = reachableFrom(barrel).dartLibs;

        expect(reached, isNot(contains('dart:js_interop')));
        expect(reached, isNot(contains('dart:js_interop_unsafe')));
      });
    }

    test('and the adapter is where the web lives', () {
      // The mirror of the above. If this came back clean the adapter would
      // have moved, and the barrel tests would be passing for a reason that
      // has nothing to do with containment.
      final reached = reachableFrom(opfs);

      expect(reached.dartLibs, contains('dart:js_interop'));
      expect(reached.packages, contains('package:web'));
    });

    test('the web barrel is how a browser host reaches it', () {
      // Containment is not the same as unreachability. Without a barrel of
      // its own the adapter can only be had by importing `src/`, which is
      // not a surface this package offers anyone.
      expect(reachableFrom('lib/brain_kernel_web.dart').dartLibs,
          contains('dart:js_interop'));
    });
  });

  group('a sidecar store can be named and obtained from outside', () {
    // Every sidecar constructor takes a store. A caller outside the package
    // that cannot name the type, or cannot get the one for its platform,
    // cannot call them at all — and the barrel is the only surface it has.
    final barrel = File('lib/brain_kernel.dart').readAsStringSync();

    for (final export in <String>[
      'src/core/sidecar/store/sidecar_store.dart',
      'src/core/sidecar/store/default_sidecar_store.dart',
    ]) {
      test('the barrel exports $export', () {
        expect(barrel, contains("export '$export';"));
      });
    }
  });

  test('the filesystem implementation is where the platform lives', () {
    // The other half of the split. If this ever came back clean, the
    // implementation would have moved somewhere else and the first test
    // would be passing for the wrong reason.
    final reached = reachableFrom(filesystemImpl);

    expect(reached.dartLibs, contains('dart:io'));
    expect(reached.packages, contains('package:mcp_bundle'));
  });
}
