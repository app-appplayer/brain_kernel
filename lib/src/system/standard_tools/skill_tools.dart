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
      return <String, dynamic>{
        'ok': true,
        'skills': all.map((e) => e.toJson()).toList(),
      };
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
      final skill = await rt.registry.getSkill(app.scopeIdFor(id));
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
      final result = await app.system.skill.execute(
        app.scopeIdFor(id),
        inputsMap,
      );
      return <String, dynamic>{'ok': true, 'result': result.toJson()};
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
