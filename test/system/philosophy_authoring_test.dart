/// Integration — `bk.philosophy.put` authoring round-trip (dogfood fix).
///
/// A host / LLM authors an Ethos via `bk.philosophy.put`. The
/// put → store → get path must preserve the body so the downstream
/// `Ethos.fromJson(record.payload)` (at `getEthos` / `intervene` time)
/// reconstructs the real prohibitions — the old code dropped a raw Ethos to
/// `payload: {}` and the body was lost. Malformed input must yield a clear,
/// field-named error rather than an opaque `Null is not a subtype of String`.
///
/// Uses a real `KvEthosStoreAdapter` (wired by `KernelApp.boot` over the
/// in-memory KV) — a real store round-trip, not a stubbed port.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

Map<String, dynamic> _rawEthos() => <String, dynamic>{
      'id': 'pr_ethos',
      'name': 'PR Ethos',
      'valuePriorities': <Map<String, dynamic>>[
        {
          'id': 'vp1',
          'rank': 1,
          'higherValue': 'safety',
          'lowerValue': 'speed',
          'rationale': 'safety first',
        },
      ],
      'prohibitions': <Map<String, dynamic>>[
        {
          'id': 'p1',
          'statement': 'never leak secrets',
          'severity': 'hard',
          'rationale': 'confidentiality',
        },
      ],
      'metadata': <String, dynamic>{
        'version': '1.0.0',
        'createdAt': '2026-06-23T00:00:00.000Z',
        'updatedAt': '2026-06-23T00:00:00.000Z',
      },
    };

void main() {
  group('bk.philosophy.put authoring round-trip', () {
    late KernelApp app;

    setUp(() async {
      app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
    });

    tearDown(() async {
      await app.shutdown();
    });

    test('a RAW Ethos put preserves the body (no payload loss)', () async {
      final tools = standardTools(app);
      final putRes =
          await tools['bk.philosophy.put']!(<String, dynamic>{'ethos': _rawEthos()})
              as Map;
      expect(putRes['ok'], isTrue);

      final getRes =
          await tools['bk.philosophy.get']!(<String, dynamic>{'id': 'pr_ethos'})
              as Map;
      expect(getRes['ok'], isTrue);
      final payload = (getRes['ethos'] as Map)['payload'] as Map;
      // Body preserved — NOT the old empty {} loss.
      expect(payload['prohibitions'], isNotEmpty);
      // And it reconstructs into a real Ethos with the authored prohibition.
      final ethos = Ethos.fromJson(Map<String, dynamic>.from(payload));
      expect(ethos.hardProhibitions.single.statement, 'never leak secrets');
    });

    test('an envelope-shaped put still works (back-compat)', () async {
      final tools = standardTools(app);
      final envelope = <String, dynamic>{
        'id': 'env_ethos',
        'name': 'Env',
        'version': '2.0.0',
        'payload': _rawEthos(),
      };
      final putRes = await tools['bk.philosophy.put']!(
          <String, dynamic>{'ethos': envelope}) as Map;
      expect(putRes['ok'], isTrue);
      final getRes =
          await tools['bk.philosophy.get']!(<String, dynamic>{'id': 'env_ethos'})
              as Map;
      final payload = (getRes['ethos'] as Map)['payload'] as Map;
      expect(payload['prohibitions'], isNotEmpty);
    });

    test('a malformed ethos yields a clear field-named error (not opaque)',
        () async {
      final tools = standardTools(app);
      final bad = _rawEthos();
      // Prohibition missing the required `rationale`.
      bad['prohibitions'] = <Map<String, dynamic>>[
        {'id': 'p1', 'statement': 'x', 'severity': 'hard'},
      ];
      final putRes =
          await tools['bk.philosophy.put']!(<String, dynamic>{'ethos': bad})
              as Map;
      expect(putRes['ok'], isFalse);
      expect(putRes['error'].toString(),
          allOf(contains('rationale'), contains('Prohibition')));
    });
  });

  group('bk.philosophy provenance discipline (judgment determinism)', () {
    late KernelApp app;

    setUp(() async {
      app = await KernelApp.boot(
        workspaceId: 't',
        kvStorage: InMemoryKvStoragePort(),
      );
    });

    tearDown(() async {
      await app.shutdown();
    });

    test('an anchor (no provenance) is unconstrained and activates', () async {
      final tools = standardTools(app);
      final e = _rawEthos()..['active'] = true;
      final putRes =
          await tools['bk.philosophy.put']!(<String, dynamic>{'ethos': e})
              as Map;
      expect(putRes['ok'], isTrue);
      final actRes =
          await tools['bk.philosophy.activate']!(<String, dynamic>{'id': 'pr_ethos'})
              as Map;
      expect(actRes['ok'], isTrue);
    });

    test('a derived ethos without `serves` is rejected at put', () async {
      final tools = standardTools(app);
      final e = _rawEthos()
        ..['id'] = 'd_ethos'
        ..['provenance'] = <String, dynamic>{'kind': 'derived'};
      final putRes =
          await tools['bk.philosophy.put']!(<String, dynamic>{'ethos': e})
              as Map;
      expect(putRes['ok'], isFalse);
      expect(putRes['error'].toString(),
          allOf(contains('serves'), contains('derived')));
    });

    test('a derived ethos with `serves` is stored INACTIVE even if active:true',
        () async {
      final tools = standardTools(app);
      final e = _rawEthos()
        ..['id'] = 'd2_ethos'
        ..['active'] = true
        ..['provenance'] = <String, dynamic>{
          'kind': 'derived',
          'serves': 'pr_ethos',
        };
      final putRes =
          await tools['bk.philosophy.put']!(<String, dynamic>{'ethos': e})
              as Map;
      expect(putRes['ok'], isTrue);
      final getRes =
          await tools['bk.philosophy.get']!(<String, dynamic>{'id': 'd2_ethos'})
              as Map;
      // Forced inactive — a judgment cannot self-promote to active principle.
      expect((getRes['ethos'] as Map)['active'], isFalse);
      // Provenance survives the store round-trip with no core type change.
      final payload = (getRes['ethos'] as Map)['payload'] as Map;
      expect((payload['provenance'] as Map)['serves'], 'pr_ethos');
    });

    test('a workaround with `serves` can be confirmed via activate', () async {
      final tools = standardTools(app);
      final e = _rawEthos()
        ..['id'] = 'd3_ethos'
        ..['provenance'] = <String, dynamic>{
          'kind': 'workaround',
          'serves': 'pr_ethos',
          'validWhile': 'agents_unsplit',
        };
      expect(
          ((await tools['bk.philosophy.put']!(<String, dynamic>{'ethos': e}))
              as Map)['ok'],
          isTrue);
      final actRes =
          await tools['bk.philosophy.activate']!(<String, dynamic>{'id': 'd3_ethos'})
              as Map;
      expect(actRes['ok'], isTrue);
      final activeRes =
          await tools['bk.philosophy.get_active_id']!(<String, dynamic>{})
              as Map;
      expect(activeRes['activeId'].toString(), contains('d3_ethos'));
    });
  });
}
