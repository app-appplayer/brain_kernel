/// `bk.philosophy.*` — EthosStorePort wrappers (`put` / `list` /
/// `get` / `activate` / `get_active_id`). `PhilosophyFacade` has no
/// write methods, so writes go directly to the store.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, InProcessToolHandler> buildPhilosophyTools(KernelApp app) {
  mb.EthosStorePort? store() => app.system.ethosStore;

  Map<String, dynamic> ethosToJson(mb.EthosRecord e) => <String, dynamic>{
        'id': e.id,
        'name': e.name,
        'version': e.version,
        'payload': e.payload,
        'createdAt': e.createdAt.toIso8601String(),
        'active': e.active,
      };

  // Provenance discipline (judgment determinism). An ethos payload may carry an
  // optional block:
  //   payload['provenance'] = { 'kind': 'anchor'|'derived'|'workaround',
  //                             'serves': <principle id/name>,
  //                             'validWhile': <condition> }
  // `kind` defaults to 'anchor' when absent, so pre-existing records and the
  // stock seed (which carry no provenance) stay unconstrained. A `derived` or
  // `workaround` record is a transient judgment, not an original principle: it
  // must declare what principle it `serves`, and it may not be stored as
  // already-active — it becomes active only through an explicit `activate`
  // (the confirm step), mirroring the fact candidate→confirm lifecycle. The
  // payload map is preserved as-is by `putEthos`, so this rides the existing
  // store contract with no core type change.
  Map<String, dynamic>? provenanceOf(Map<String, dynamic> payload) {
    final prov = payload['provenance'];
    return prov is Map ? Map<String, dynamic>.from(prov) : null;
  }

  String provKind(Map<String, dynamic>? prov) {
    final k = (prov?['kind'] as String?)?.trim();
    return (k == null || k.isEmpty) ? 'anchor' : k;
  }

  bool isDerivedKind(String kind) => kind == 'derived' || kind == 'workaround';

  String? provServes(Map<String, dynamic>? prov) {
    final s = (prov?['serves'] as String?)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  Future<Object?> put(Map<String, dynamic> p) async {
    final s = store();
    if (s == null) return stdErr('EthosStorePort not configured');
    final raw = p['ethos'];
    if (raw is! Map) return stdErr('ethos object required');
    try {
      final input = Map<String, dynamic>.from(raw);
      // Accept either an EthosRecord envelope ({id,name,version,payload:{…}})
      // or a raw Ethos ({id,name,valuePriorities,prohibitions,metadata,…}).
      // The natural authoring shape (a host or an LLM via bk.philosophy.put)
      // is a raw Ethos; wrap it into the storage envelope so the body is
      // never silently lost to an empty payload.
      final isEnvelope = input['payload'] is Map;
      final ethosJson = isEnvelope
          ? Map<String, dynamic>.from(input['payload'] as Map)
          : input;

      // Validate the ethos body parses — a malformed ethos now yields a clear
      // field-named error (mcp_bundle 0.4.4) instead of a body that round-trips
      // to a crash at intervene/getEthos time.
      mb.Ethos.fromJson(ethosJson);

      // Provenance gate (write side): a derived/workaround ethos must declare
      // the principle it serves, and is forced inactive — it can only be made
      // active by an explicit `activate` call (confirm).
      final prov = provenanceOf(ethosJson);
      final kind = provKind(prov);
      final derived = isDerivedKind(kind);
      if (derived && provServes(prov) == null) {
        return stdErr(
          "ethos provenance.kind '$kind' requires a non-empty 'serves' "
          '(the principle this judgment serves)',
        );
      }

      final id = isEnvelope ? input['id'] : ethosJson['id'];
      if (id is! String || id.isEmpty) {
        return stdErr('ethos.id (non-empty String) required');
      }
      final name = (isEnvelope ? input['name'] : ethosJson['name']) as String?;
      final version = (isEnvelope
          ? input['version']
          : (ethosJson['metadata'] as Map?)?['version']) as String?;

      final record = mb.EthosRecord(
        id: app.scopeIdFor(id),
        name: name ?? id,
        version: version ?? '1.0.0',
        payload: ethosJson,
        createdAt: DateTime.now(),
        active: derived
            ? false
            : ((isEnvelope ? input['active'] : false) as bool? ?? false),
      );
      await s.putEthos(record);
      return <String, dynamic>{'ok': true, 'id': record.id};
    } on FormatException catch (e) {
      return stdErr('invalid ethos: ${e.message}');
    } catch (e) {
      return stdErr('putEthos failed: $e');
    }
  }

  Future<Object?> list(Map<String, dynamic> p) async {
    final s = store();
    if (s == null) return stdErr('EthosStorePort not configured');
    final limit = (p['limit'] as num?)?.toInt();
    try {
      final all = await s.listEthos(limit: limit);
      return <String, dynamic>{
        'ok': true,
        'ethos': all.map(ethosToJson).toList(),
      };
    } catch (e) {
      return stdErr('listEthos failed: $e');
    }
  }

  Future<Object?> get(Map<String, dynamic> p) async {
    final s = store();
    if (s == null) return stdErr('EthosStorePort not configured');
    final id = p['id'];
    if (id is! String || id.isEmpty) return stdErr('id required');
    try {
      final ethos = await s.getEthos(app.scopeIdFor(id));
      return <String, dynamic>{
        'ok': true,
        'ethos': ethos == null ? null : ethosToJson(ethos),
      };
    } catch (e) {
      return stdErr('getEthos failed: $e');
    }
  }

  Future<Object?> activate(Map<String, dynamic> p) async {
    final s = store();
    if (s == null) return stdErr('EthosStorePort not configured');
    final id = p['id'];
    if (id is! String || id.isEmpty) return stdErr('id required');
    final scopedId = app.scopeIdFor(id);
    try {
      // Confirm step: promoting a derived/workaround ethos to the active
      // principle requires the `serves` link — this keeps a transient judgment
      // from silently becoming the governing principle. Anchors activate freely.
      final existing = await s.getEthos(scopedId);
      if (existing != null) {
        final prov = provenanceOf(existing.payload);
        final kind = provKind(prov);
        if (isDerivedKind(kind) && provServes(prov) == null) {
          return stdErr(
            "cannot activate ethos '$id': provenance.kind '$kind' requires a "
            "'serves' link",
          );
        }
      }
      await s.activateEthos(scopedId);
      return <String, dynamic>{'ok': true, 'activeId': scopedId};
    } catch (e) {
      return stdErr('activateEthos failed: $e');
    }
  }

  Future<Object?> getActiveId(Map<String, dynamic> p) async {
    final s = store();
    if (s == null) return stdErr('EthosStorePort not configured');
    try {
      final id = await s.getActiveEthosId();
      return <String, dynamic>{'ok': true, 'activeId': id};
    } catch (e) {
      return stdErr('getActiveEthosId failed: $e');
    }
  }

  // Prohibition check — the read-side of philosophy (unlike put/get which go
  // to the store, this evaluates a proposed action against active ethos via
  // the PhilosophyFacade). Lets a behavior step gate on `hasHardViolation`.
  Future<Object?> check(Map<String, dynamic> p) async {
    final action = p['action'] as String?;
    final output = p['output'] as String?;
    if ((action == null || action.isEmpty) &&
        (output == null || output.isEmpty)) {
      return stdErr('action or output required');
    }
    final context = (p['context'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    try {
      final result = await app.system.philosophy.checkProhibitions(
        mb.ProhibitionCheckRequest(
          proposedAction: action,
          proposedOutput: output,
          context: context,
        ),
      );
      return <String, dynamic>{
        'ok': true,
        'hasHardViolation': result.hasHardViolation,
        'violations': result.checks
            .where((c) => c.violated)
            .map((c) => <String, dynamic>{
                  'prohibitionId': c.prohibitionId,
                  'severity': c.severity.name,
                  if (c.violationDetail != null) 'detail': c.violationDetail,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('checkProhibitions failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.philosophy.put': put,
    'bk.philosophy.list': list,
    'bk.philosophy.get': get,
    'bk.philosophy.activate': activate,
    'bk.philosophy.get_active_id': getActiveId,
    'bk.philosophy.check': check,
  };
}
