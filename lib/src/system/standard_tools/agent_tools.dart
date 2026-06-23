/// `bk.agent.*` — AgentFacade wrappers (13 tools): list / get / ask /
/// create / delete / history / assign_skill / assign_profile /
/// assign_philosophy / assign_facts / materialize / route / review.
/// route + review (spec `platform/12-flowbrain-runtime.md` §5) expose
/// manager routing + reviewer verdict as tools so workflows / agents can
/// drive rule-based agent→agent handoff.
library;

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, InProcessToolHandler> buildAgentTools(KernelApp app) {
  fb.AgentFacade facade() => app.system.agents;

  Map<String, dynamic> agentToJson(fb.Agent a) => <String, dynamic>{
        'id': a.id,
        'workspaceId': a.workspaceId,
        'displayName': a.displayName,
        'role': a.role.name,
        'model': <String, dynamic>{
          'provider': a.model.provider,
          'model': a.model.model,
        },
      };

  Future<Object?> list(Map<String, dynamic> p) async {
    try {
      final all = await facade().listAgents(
        role: p['role'] as String?,
        workspaceId: p['workspaceId'] as String?,
      );
      return <String, dynamic>{
        'ok': true,
        'agents': all.map(agentToJson).toList(),
      };
    } catch (e) {
      return stdErr('listAgents failed: $e');
    }
  }

  Future<Object?> get(Map<String, dynamic> p) async {
    final id = p['agentId'];
    if (id is! String || id.isEmpty) return stdErr('agentId required');
    try {
      final a = await facade().getAgent(app.scopeIdFor(id));
      return <String, dynamic>{
        'ok': true,
        'agent': a == null ? null : agentToJson(a),
      };
    } catch (e) {
      return stdErr('getAgent failed: $e');
    }
  }

  Future<Object?> ask(Map<String, dynamic> p) async {
    final id = p['agentId'];
    if (id is! String || id.isEmpty) return stdErr('agentId required');
    final message = p['message'];
    if (message is! String) return stdErr('message required');
    try {
      final reply = await facade().ask(app.scopeIdFor(id), message);
      return <String, dynamic>{
        'ok': true,
        'agentId': reply.agentId,
        'content': reply.content,
        if (reply.finishReason != null) 'finishReason': reply.finishReason,
      };
    } catch (e) {
      return stdErr('ask failed: $e');
    }
  }

  Future<Object?> create(Map<String, dynamic> p) async {
    final id = p['id'];
    if (id is! String || id.isEmpty) return stdErr('id required');
    final displayName = p['displayName'];
    if (displayName is! String) return stdErr('displayName required');
    final roleName = p['role'] as String?;
    final role = fb.AgentRole.values.firstWhere(
      (r) => r.name == roleName,
      orElse: () => fb.AgentRole.worker,
    );
    final modelRaw = p['model'] as Map?;
    final model = modelRaw != null
        ? fb.ModelSpec(
            provider: modelRaw['provider'] as String? ?? 'stub',
            model: modelRaw['model'] as String? ?? 'stub-1',
          )
        : fb.ModelSpec.stub();
    try {
      final agent = await facade().createAgent(
        workspaceId: p['workspaceId'] as String? ?? app.workspaceId,
        id: app.scopeIdFor(id),
        displayName: displayName,
        role: role,
        model: model,
      );
      return <String, dynamic>{'ok': true, 'agent': agentToJson(agent)};
    } catch (e) {
      return stdErr('createAgent failed: $e');
    }
  }

  Future<Object?> delete(Map<String, dynamic> p) async {
    final id = p['agentId'];
    if (id is! String || id.isEmpty) return stdErr('agentId required');
    try {
      await facade().deleteAgent(app.scopeIdFor(id));
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('deleteAgent failed: $e');
    }
  }

  Future<Object?> history(Map<String, dynamic> p) async {
    final id = p['agentId'];
    if (id is! String || id.isEmpty) return stdErr('agentId required');
    try {
      final turns = await facade().getHistory(app.scopeIdFor(id));
      return <String, dynamic>{
        'ok': true,
        'turns': turns
            .map((t) => <String, dynamic>{
                  'userMessage': t.userMessage,
                  'assistantReply': t.assistantReply,
                  'model': t.model,
                  'timestamp': t.timestamp.toIso8601String(),
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('getHistory failed: $e');
    }
  }

  Future<Object?> assignSkill(Map<String, dynamic> p) async {
    final agentId = p['agentId'];
    final skillId = p['skillId'];
    if (agentId is! String || skillId is! String) {
      return stdErr('agentId + skillId required');
    }
    try {
      await facade().assignSkillFromPool(
        app.scopeIdFor(agentId),
        app.scopeIdFor(skillId),
      );
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('assignSkill failed: $e');
    }
  }

  Future<Object?> assignProfile(Map<String, dynamic> p) async {
    final agentId = p['agentId'];
    final profileId = p['profileId'];
    if (agentId is! String || profileId is! String) {
      return stdErr('agentId + profileId required');
    }
    try {
      await facade().assignProfileFromPool(
        app.scopeIdFor(agentId),
        app.scopeIdFor(profileId),
      );
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('assignProfile failed: $e');
    }
  }

  Future<Object?> assignPhilosophy(Map<String, dynamic> p) async {
    final agentId = p['agentId'];
    final ethosId = p['ethosId'];
    if (agentId is! String || ethosId is! String) {
      return stdErr('agentId + ethosId required');
    }
    try {
      await facade().assignPhilosophyFromPool(
        app.scopeIdFor(agentId),
        app.scopeIdFor(ethosId),
      );
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('assignPhilosophy failed: $e');
    }
  }

  Future<Object?> assignFacts(Map<String, dynamic> p) async {
    final agentId = p['agentId'];
    if (agentId is! String) return stdErr('agentId required');
    final queryRaw = p['query'];
    if (queryRaw is! Map) return stdErr('query object required');
    final m = Map<String, dynamic>.from(queryRaw);
    try {
      final query = mb.FactQuery(
        workspaceId: m['workspaceId'] as String? ?? app.workspaceId,
        types: (m['types'] as List?)?.cast<String>(),
        entityId: m['entityId'] as String?,
        limit: (m['limit'] as num?)?.toInt(),
      );
      await facade().assignFacts(app.scopeIdFor(agentId), query);
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('assignFacts failed: $e');
    }
  }

  Future<Object?> materialize(Map<String, dynamic> p) async {
    final agentId = p['agentId'];
    final axisName = p['axis'];
    final forkedRef = p['forkedRef'];
    if (agentId is! String || axisName is! String || forkedRef is! String) {
      return stdErr('agentId + axis + forkedRef required');
    }
    final axis = fb.AgentAxis.values.firstWhere(
      (a) => a.name == axisName,
      orElse: () => fb.AgentAxis.skill,
    );
    try {
      await facade().materialize(app.scopeIdFor(agentId), axis, forkedRef);
      return <String, dynamic>{'ok': true};
    } catch (e) {
      return stdErr('materialize failed: $e');
    }
  }

  // §5 (orchestration): manager routes a request to the best worker.
  Future<Object?> route(Map<String, dynamic> p) async {
    final managerId = p['managerId'];
    final request = p['request'];
    if (managerId is! String || managerId.isEmpty) {
      return stdErr('managerId required');
    }
    if (request is! String) return stdErr('request required');
    final candidates = (p['candidateAgentIds'] as List?)
        ?.cast<String>()
        .map(app.scopeIdFor)
        .toList();
    try {
      final d = await facade().route(
        app.scopeIdFor(managerId),
        request,
        candidateAgentIds: candidates,
      );
      return <String, dynamic>{
        'ok': true,
        'targetAgentId': d.targetAgentId,
        'confidence': d.confidence,
        if (d.reason != null) 'reason': d.reason,
      };
    } catch (e) {
      return stdErr('route failed: $e');
    }
  }

  // §5 (orchestration): reviewer verdict over a target agent's reply.
  Future<Object?> review(Map<String, dynamic> p) async {
    final reviewerId = p['reviewerId'];
    final targetAgentId = p['targetAgentId'];
    final content = p['content'];
    if (reviewerId is! String || reviewerId.isEmpty) {
      return stdErr('reviewerId required');
    }
    if (targetAgentId is! String || content is! String) {
      return stdErr('targetAgentId + content required');
    }
    try {
      final reply = fb.AgentReply(
        id: '',
        agentId: app.scopeIdFor(targetAgentId),
        content: content,
        model: '',
        timestamp: DateTime.now(),
      );
      final r = await facade().review(app.scopeIdFor(reviewerId), reply);
      return <String, dynamic>{
        'ok': true,
        'verdict': r.verdict.name,
        if (r.severity != null) 'severity': r.severity!.name,
        if (r.comments != null) 'comments': r.comments,
      };
    } catch (e) {
      return stdErr('review failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.agent.list': list,
    'bk.agent.get': get,
    'bk.agent.ask': ask,
    'bk.agent.create': create,
    'bk.agent.delete': delete,
    'bk.agent.history': history,
    'bk.agent.assign_skill': assignSkill,
    'bk.agent.assign_profile': assignProfile,
    'bk.agent.assign_philosophy': assignPhilosophy,
    'bk.agent.assign_facts': assignFacts,
    'bk.agent.materialize': materialize,
    'bk.agent.route': route,
    'bk.agent.review': review,
  };
}
