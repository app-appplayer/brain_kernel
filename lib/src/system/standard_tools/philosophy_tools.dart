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

  Future<Object?> put(Map<String, dynamic> p) async {
    final s = store();
    if (s == null) return stdErr('EthosStorePort not configured');
    final raw = p['ethos'];
    if (raw is! Map) return stdErr('ethos object required');
    try {
      final m = Map<String, dynamic>.from(raw);
      m['id'] = app.scopeIdFor(m['id'] as String);
      final record = mb.EthosRecord.fromJson(m);
      await s.putEthos(record);
      return <String, dynamic>{'ok': true, 'id': record.id};
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
