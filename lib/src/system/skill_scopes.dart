/// Who owns a skill, and who may see it (platform spec 30 §8).
///
/// A skill with no owner is global. One with an owner is visible to a call
/// only when the owner is in the call's scope chain — the caller's own scope
/// first, then the ones above it. How a chain is built (an org hierarchy, a
/// single workspace) is the host's; the kernel only asks whether the owner is
/// in it.
library;

/// The scope chain for [scopeId], itself first, then upward.
typedef SkillScopeChain = Future<List<String>> Function(String scopeId);

class SkillScopes {
  SkillScopes({SkillScopeChain? chainOf}) : _chainOf = chainOf;

  final SkillScopeChain? _chainOf;
  final Map<String, String> _ownerBySkill = <String, String>{};

  /// Record [owner] for [skillId]; a null owner makes the skill global.
  void own(String skillId, String? owner) {
    if (owner == null) {
      _ownerBySkill.remove(skillId);
    } else {
      _ownerBySkill[skillId] = owner;
    }
  }

  void forget(String skillId) => _ownerBySkill.remove(skillId);

  String? ownerOf(String skillId) => _ownerBySkill[skillId];

  /// The chain a call from [scopeId] carries; with no provider, just itself.
  Future<List<String>> chainFor(String scopeId) async {
    final provider = _chainOf;
    if (provider == null) return <String>[scopeId];
    final chain = await provider(scopeId);
    return chain.contains(scopeId) ? chain : <String>[scopeId, ...chain];
  }

  /// Whether a call from [scopeId] (null = no scope given) may see [skillId].
  /// A call with no scope sees only global skills.
  Future<bool> visible(String skillId, String? scopeId) async {
    final owner = _ownerBySkill[skillId];
    if (owner == null) return true;
    if (scopeId == null) return false;
    return (await chainFor(scopeId)).contains(owner);
  }
}
