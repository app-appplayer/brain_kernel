/// `bk.workflow.*` · `bk.pipeline.*` · `bk.runbook.*` · `bk.behavior.*` —
/// OpsFacade / behavior-engine wrappers.
library;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, InProcessToolHandler> buildOpsTools(KernelApp app) {
  // ── Workflow ────────────────────────────────────────────────────

  Future<Object?> workflowRun(Map<String, dynamic> p) async {
    final id = p['workflowId'];
    if (id is! String || id.isEmpty) return stdErr('workflowId required');
    final params = (p['args'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    try {
      final handle =
          await app.system.ops.runWorkflow(app.scopeIdFor(id), params);
      return <String, dynamic>{
        'ok': true,
        'runId': handle.runId,
        'workflowId': handle.workflowId,
        'status': handle.status,
      };
    } catch (e) {
      return stdErr('runWorkflow failed: $e');
    }
  }

  Future<Object?> workflowList(Map<String, dynamic> p) async {
    try {
      final all = await app.system.ops.listWorkflows();
      return <String, dynamic>{
        'ok': true,
        'workflows': all
            .map((d) => <String, dynamic>{
                  'id': d.id,
                  'name': d.name,
                  'description': d.description,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('listWorkflows failed: $e');
    }
  }

  Future<Object?> workflowGetRun(Map<String, dynamic> p) async {
    final runId = p['runId'];
    if (runId is! String || runId.isEmpty) return stdErr('runId required');
    try {
      final handle = await app.system.ops.getWorkflowRun(runId);
      return <String, dynamic>{
        'ok': true,
        'run': handle == null
            ? null
            : <String, dynamic>{
                'runId': handle.runId,
                'workflowId': handle.workflowId,
                'status': handle.status,
              },
      };
    } catch (e) {
      return stdErr('getWorkflowRun failed: $e');
    }
  }

  // ── Pipeline ────────────────────────────────────────────────────

  Future<Object?> pipelineRun(Map<String, dynamic> p) async {
    final id = p['pipelineId'];
    if (id is! String || id.isEmpty) return stdErr('pipelineId required');
    final params = (p['args'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    try {
      final handle =
          await app.system.ops.runPipeline(app.scopeIdFor(id), params);
      return <String, dynamic>{
        'ok': true,
        'runId': handle.runId,
        'pipelineId': handle.pipelineId,
        'status': handle.status,
      };
    } catch (e) {
      return stdErr('runPipeline failed: $e');
    }
  }

  Future<Object?> pipelineGetRun(Map<String, dynamic> p) async {
    final runId = p['runId'];
    if (runId is! String || runId.isEmpty) return stdErr('runId required');
    try {
      final handle = await app.system.ops.getPipelineRun(runId);
      return <String, dynamic>{
        'ok': true,
        'run': handle == null
            ? null
            : <String, dynamic>{
                'runId': handle.runId,
                'pipelineId': handle.pipelineId,
                'status': handle.status,
              },
      };
    } catch (e) {
      return stdErr('getPipelineRun failed: $e');
    }
  }

  // ── Runbook ─────────────────────────────────────────────────────

  Future<Object?> runbookRun(Map<String, dynamic> p) async {
    final id = p['runbookId'];
    if (id is! String || id.isEmpty) return stdErr('runbookId required');
    final params = (p['args'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final scopedId = app.scopeIdFor(id);
    try {
      final exec = await app.system.ops.runRunbook(scopedId, params);
      return <String, dynamic>{
        'ok': true,
        'runbookId': scopedId,
        'status': exec.status,
      };
    } catch (e) {
      return stdErr('runRunbook failed: $e');
    }
  }

  Future<Object?> runbookList(Map<String, dynamic> p) async {
    try {
      final all = await app.system.ops.listRunbooks();
      return <String, dynamic>{
        'ok': true,
        'runbooks': all
            .map((d) => <String, dynamic>{
                  'id': d.id,
                  'name': d.name,
                  'description': d.description,
                })
            .toList(),
      };
    } catch (e) {
      return stdErr('listRunbooks failed: $e');
    }
  }

  // ── Behavior (unified "behavior definition" engine) ─────────────
  // Routed through the OpsFacade (`app.system.ops`) like workflow/runbook —
  // this tools layer (and the kernel) hold no mcp_knowledge_ops dependency.

  Future<Object?> behaviorRun(Map<String, dynamic> p) async {
    final id = p['behaviorId'];
    if (id is! String || id.isEmpty) return stdErr('behaviorId required');
    final params = (p['args'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    try {
      final result = await app.system.ops.runBehavior(
        app.scopeIdFor(id),
        runId: p['runId'] as String?,
        input: params,
      );
      return <String, dynamic>{'ok': true, ...result};
    } catch (e) {
      return stdErr('runBehavior failed: $e');
    }
  }

  Future<Object?> behaviorResume(Map<String, dynamic> p) async {
    final id = p['behaviorId'];
    final runId = p['runId'];
    if (id is! String || id.isEmpty) return stdErr('behaviorId required');
    if (runId is! String || runId.isEmpty) return stdErr('runId required');
    // `statePatch` is merged into the run state before re-evaluation — the
    // approval / unblock payload (e.g. {"approved": true}).
    final statePatch =
        (p['statePatch'] as Map?)?.cast<String, dynamic>();
    try {
      final result = await app.system.ops
          .resumeBehavior(app.scopeIdFor(id), runId, statePatch: statePatch);
      return <String, dynamic>{'ok': true, ...result};
    } catch (e) {
      return stdErr('resumeBehavior failed: $e');
    }
  }

  Future<Object?> behaviorList(Map<String, dynamic> p) async {
    try {
      return <String, dynamic>{
        'ok': true,
        'behaviors': app.system.ops.listBehaviors(),
      };
    } catch (e) {
      return stdErr('listBehaviors failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.workflow.run': workflowRun,
    'bk.workflow.list': workflowList,
    'bk.workflow.get_run': workflowGetRun,
    'bk.pipeline.run': pipelineRun,
    'bk.pipeline.get_run': pipelineGetRun,
    'bk.runbook.run': runbookRun,
    'bk.runbook.list': runbookList,
    'bk.behavior.run': behaviorRun,
    'bk.behavior.resume': behaviorResume,
    'bk.behavior.list': behaviorList,
  };
}
