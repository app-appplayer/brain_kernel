import 'package:brain_kernel/src/core/_inverse_patch.dart';
import 'package:test/test.dart';

void main() {
  group('applyPatch', () {
    test('add into a map', () {
      final json = <String, dynamic>{'a': 1};
      applyPatch(json, JsonPatchSet([
        const PatchOp(op: 'add', path: '/b', value: 2),
      ]));
      expect(json, {'a': 1, 'b': 2});
    });

    test('add at end of list with "-"', () {
      final json = <String, dynamic>{
        'list': [1, 2, 3]
      };
      applyPatch(json, JsonPatchSet([
        const PatchOp(op: 'add', path: '/list/-', value: 4),
      ]));
      expect(json['list'], [1, 2, 3, 4]);
    });

    test('replace a value', () {
      final json = <String, dynamic>{'a': 1};
      applyPatch(json, JsonPatchSet([
        const PatchOp(op: 'replace', path: '/a', value: 9),
      ]));
      expect(json['a'], 9);
    });

    test('remove a key', () {
      final json = <String, dynamic>{'a': 1, 'b': 2};
      applyPatch(json, JsonPatchSet([
        const PatchOp(op: 'remove', path: '/b'),
      ]));
      expect(json, {'a': 1});
    });

    test('throws on missing parent', () {
      final json = <String, dynamic>{};
      expect(
        () => applyPatch(json, JsonPatchSet([
          const PatchOp(op: 'replace', path: '/missing/leaf', value: 1),
        ])),
        throwsA(isA<PatchApplyException>()),
      );
    });
  });

  group('computeInverse', () {
    test('add → remove', () {
      final before = <String, dynamic>{};
      final patch = JsonPatchSet([
        const PatchOp(op: 'add', path: '/a', value: 1),
      ]);
      final inverse = computeInverse(before, patch);
      expect(inverse.ops, hasLength(1));
      expect(inverse.ops.first.op, 'remove');
      expect(inverse.ops.first.path, '/a');
    });

    test('replace preserves old value', () {
      final before = <String, dynamic>{'a': 1};
      final patch = JsonPatchSet([
        const PatchOp(op: 'replace', path: '/a', value: 9),
      ]);
      final inverse = computeInverse(before, patch);
      expect(inverse.ops.first.op, 'replace');
      expect(inverse.ops.first.value, 1);
    });

    test('remove preserves old value as add', () {
      final before = <String, dynamic>{'a': 1, 'b': 2};
      final patch = JsonPatchSet([
        const PatchOp(op: 'remove', path: '/b'),
      ]);
      final inverse = computeInverse(before, patch);
      expect(inverse.ops.first.op, 'add');
      expect(inverse.ops.first.value, 2);
    });

    test('round-trip apply+inverse restores state', () {
      final before = <String, dynamic>{'a': 1, 'b': 2, 'list': [10, 20]};
      final patch = JsonPatchSet([
        const PatchOp(op: 'replace', path: '/a', value: 9),
        const PatchOp(op: 'add', path: '/list/-', value: 30),
        const PatchOp(op: 'remove', path: '/b'),
      ]);
      final cloned = <String, dynamic>{
        'a': 1,
        'b': 2,
        'list': [10, 20],
      };
      final inverse = computeInverse(before, patch);
      applyPatch(cloned, patch);
      applyPatch(cloned, inverse);
      expect(cloned, before);
    });
  });
}
