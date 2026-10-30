/// `bk.skill.*` — SkillFacade / SkillRuntime wrappers. Exposes
/// `list` / `get` / `execute`. `SkillFacade` has no `register` — skill
/// registration goes through [BundleActivation] instead.
library;

import '../kernel_app.dart';
import 'standard_tools.dart';

Map<String, InProcessToolHandler> buildSkillTools(KernelApp app) {
  Future<Object?> list(Map<String, dynamic> p) async {
    final rt = app.system.skillRuntime;
    if (rt == null) return stdErr('SkillRuntime not configured');
    try {
      final all = await rt.registry.listSkills(
        workspaceId: p['workspaceId'] as String?,
      );
      final scope = p['scopeId'] as String?;
      final shown = <Map<String, dynamic>>[];
      for (final e in all) {
        final json = e.toJson();
        final id = e.manifest.id;
        if (await app.skillScopes.visible(id, scope)) shown.add(json);
      }
      return <String, dynamic>{'ok': true, 'skills': shown};
    } catch (e) {
      return stdErr('listSkills failed: $e');
    }
  }

  Future<Object?> get(Map<String, dynamic> p) async {
    final rt = app.system.skillRuntime;
    if (rt == null) return stdErr('SkillRuntime not configured');
    final id = p['skillId'];
    if (id is! String || id.isEmpty) return stdErr('skillId required');
    try {
      final full = app.scopeIdFor(id);
      if (!await app.skillScopes.visible(full, p['scopeId'] as String?)) {
        return stdErr('skill not visible in this scope: $id');
      }
      final skill = await rt.registry.getSkill(full);
      return <String, dynamic>{'ok': true, 'skill': skill?.toJson()};
    } catch (e) {
      return stdErr('getSkill failed: $e');
    }
  }

  Future<Object?> execute(Map<String, dynamic> p) async {
    if (app.system.skillRuntime == null) {
      return stdErr('SkillRuntime not configured');
    }
    final id = p['skillId'];
    if (id is! String || id.isEmpty) return stdErr('skillId required');
    final inputs = p['inputs'];
    final inputsMap = inputs is Map
        ? Map<String, dynamic>.from(inputs)
        : const <String, dynamic>{};
    try {
      final full = app.scopeIdFor(id);
      if (!await app.skillScopes.visible(full, p['scopeId'] as String?)) {
        return stdErr('skill not visible in this scope: $id');
      }
      final verdict = await app.philosophyGate.check(
        full,
        context: <String, dynamic>{
          'workspaceId': p['scopeId'],
          'actor': p['actor'],
          'inputs': inputsMap,
        },
      );
      if (!verdict.allowed) {
        return stdErr(verdict.reason ?? 'blocked by philosophy');
      }
      final procedureId = p['procedureId'];
      final result = await app.system.skill.execute(
        full,
        inputsMap,
        procedureId: procedureId is String && procedureId.isNotEmpty
            ? procedureId
            : null,
      );
      // The runtime reports a skill that failed as a result carrying the error
      // in its metadata, not as an exception; the tool must not call it ok.
      final failure = result.metadata.custom?['error'];
      if (failure != null) return stdErr('skill failed: $failure');
      return <String, dynamic>{
        'ok': true,
        'result': result.toJson(),
        if (verdict.warnings.isNotEmpty) 'warnings': verdict.warnings,
      };
    } catch (e) {
      return stdErr('execute failed: $e');
    }
  }

  return <String, InProcessToolHandler>{
    'bk.skill.list': list,
    'bk.skill.get': get,
    'bk.skill.execute': execute,
  };
}
