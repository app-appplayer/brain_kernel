/// `bk.fact.*` — FactFacade wrappers (9 tools): write / query / get /
/// delete / extract / candidates.list / candidates.confirm /
/// candidates.reject / entity.get.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, dynamic> _factToJson(mb.FactRecord r) => <String, dynamic>{
      'id': r.id,
      'workspaceId': r.workspaceId,
      'type': r.type,
      if (r.entityId != null) 'entityId': r.entityId,
      'content': r.content,
      if (r.confidence != null) 'confidence': r.confidence,
      'createdAt': r.createdAt.toIso8601String(),
    };

Map<String, InProcessToolHandler> buildFactTools(KernelApp app) {
  Future<Object?> write(Map<String, dynamic> p) async {
    final raw = p['facts'];
    if (raw is! List) return stdErr('facts array required');
    try {
      final records = <mb.FactRecord>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final m = Map<String, dynamic>.from(entry);
        records.add(mb.FactRecord(
          id: app.scopeIdFor(m['id'] as String),
          workspaceId: m['workspaceId'] as String? ?? app.workspaceId,
          type: m['type'] as String,
          entityId: m['entityId'] as String?,
          content: Map<String, dynamic>.from(
              (m['content'] as Map?) ?? const {}),
          confidence: (m['confidence'] as num?)?.toDouble(),
          createdAt: m['createdAt'] is String
              ? DateTime.tryParse(m['createdAt'] as String) ?? DateTime.now()
              : DateTime.now(),
        ));
      }
      await app.system.facts.writeFacts(records);
      return <String, dynamic>{'ok': true, 'count': records.length};
    } catch (e) {
      return stdErr('writeFacts failed: $e');
    }
  }

  Future<Object?> query(Map<String, dynamic> p) async {
    final raw = p['query'];
    if (raw is! Map) return stdErr('query object required');
    try {
      final m = Map<String, dynamic>.from(raw);
      final query = mb.FactQuery(
        workspaceId: m['workspaceId'] as String? ?? app.workspaceId,
        types: (m['types'] as List?)?.cast<String>(),
        entityId: m['entityId'] as String?,
        limit: (m['limit'] as num?)?.toInt(),
      );
      final result = await app.system.facts.queryFacts(query);
      return <String, dynamic>{
        'ok': true,
        'facts': result.map(_factToJson).toList(),
      };
    } catch (e) {
      return stdErr('queryFacts failed: $e');
    }
  }

  Future<Object?> get(Map<String, dynamic> p) async {
    final id = p['id'];
    if (id is! String) return stdErr('id string required');
    try {
      final record = await app.system.facts.getFact(app.scopeIdFor(id));
      if (record == null) return stdErr('not found');
      return <String, dynamic>{
        'ok': true,
        'fact': _factToJson(record),
      };
    } catch (e) {
      return stdErr('getFact failed: $e');
    }
  }

  Future<Object?> delete(Map<String, dynamic> p) async {
    final raw = p['ids'];
    if (raw is! List) return stdErr('ids array required');
    final ids = raw.cast<String>().map(app.scopeIdFor).toList();
    try {
      await app.system.facts.deleteFacts(ids);
      return <String, dynamic>{'ok': true, 'count': ids.length};
    } catch (e) {
      return stdErr('deleteFacts failed: $e');
    }
  }

  Future<Object?> extract(Map<String, dynamic> p) async {
    final text = p['text'];
    if (text is! String) return stdErr('text required');
    final mime = p['mimeType'] as String? ?? 'text/plain';
    try {
      final fragments =
          await app.system.facts.extractFragments(text, mime);
      return <String, dynamic>{
        'ok': true,
        'fragments': fragments
            .map((e) => <String, dynamic>{
                  'text': e.text,
                  'confidence': e.confidence,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('extract failed: $e');
    }
  }

  Future<Object?> candidatesList(Map<String, dynamic> p) async {
    try {
      final list = await app.system.facts.getPendingCandidates(
        workspaceId: p['workspaceId'] as String?,
        limit: (p['limit'] as num?)?.toInt(),
      );
      return <String, dynamic>{
        'ok': true,
        'candidates': list
            .map((c) => <String, dynamic>{
                  'id': c.id,
                  'workspaceId': c.workspaceId,
                  'type': c.type,
                  'content': c.content,
                  'status': c.status.name,
                  if (c.evidenceRefs.isNotEmpty)
                    'evidenceRefs': c.evidenceRefs,
                  if (c.confidence != null) 'confidence': c.confidence,
                  'createdAt': c.createdAt.toIso8601String(),
                  if (c.reviewerId != null) 'reviewerId': c.reviewerId,
                  if (c.rejectionReason != null)
                    'rejectionReason': c.rejectionReason,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('getPendingCandidates failed: $e');
    }
  }

  Future<Object?> candidatesConfirm(Map<String, dynamic> p) async {
    final id = p['candidateId'];
    if (id is! String || id.isEmpty) return stdErr('candidateId required');
    try {
      await app.system.facts.confirmCandidate(
        app.scopeIdFor(id),
        reviewerId: p['reviewerId'] as String?,
      );
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('confirmCandidate failed: $e');
    }
  }

  Future<Object?> candidatesReject(Map<String, dynamic> p) async {
    final id = p['candidateId'];
    if (id is! String || id.isEmpty) return stdErr('candidateId required');
    final reason = p['reason'];
    if (reason is! String) return stdErr('reason required');
    try {
      await app.system.facts.rejectCandidate(
        app.scopeIdFor(id),
        reason,
        reviewerId: p['reviewerId'] as String?,
      );
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('rejectCandidate failed: $e');
    }
  }

  Future<Object?> entityGet(Map<String, dynamic> p) async {
    final id = p['entityId'];
    if (id is! String || id.isEmpty) return stdErr('entityId required');
    try {
      final entity = await app.system.facts.getEntity(app.scopeIdFor(id));
      return <String, dynamic>{
        'ok': true,
        'entity': entity == null
            ? null
            : <String, dynamic>{
                'id': entity.id,
                'workspaceId': entity.workspaceId,
                'type': entity.type,
                'name': entity.name,
                'properties': entity.properties,
                'createdAt': entity.createdAt.toIso8601String(),
                if (entity.updatedAt != null)
                  'updatedAt': entity.updatedAt!.toIso8601String(),
              },
      };
    } catch (e) {
      return stdErr('getEntity failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.fact.write': write,
    'bk.fact.query': query,
    'bk.fact.get': get,
    'bk.fact.delete': delete,
    'bk.fact.extract': extract,
    'bk.fact.candidates.list': candidatesList,
    'bk.fact.candidates.confirm': candidatesConfirm,
    'bk.fact.candidates.reject': candidatesReject,
    'bk.fact.entity.get': entityGet,
  };
}
