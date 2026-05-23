/// SystemPromptComposer — reference implementation of [SystemPromptResolver].
///
/// Composes a runtime system prompt for an agent by stacking, in order:
///
///   1. The agent's own `systemPrompt` (typically a role description).
///   2. Profile sections — `ProfileContentSection.content` lines, ordered by
///      `priority`, with optional headings.
///   3. Skill procedures — `SkillProcedure` summaries (name + description) so
///      the agent knows which procedures it can carry out without dumping
///      every step into the prompt.
///   4. Fact summary — a compact bulleted view of facts the host considers
///      relevant for this turn (host supplies them — kernel does not query
///      `mcp_fact_graph` directly so the helper stays headless).
///   5. Philosophy statements — `Philosophy.statement` lines + (optional)
///      rationale, joined with section headings.
///
/// Hosts who want a different ordering / different formatting either
/// subclass [SystemPromptComposer] and override [compose], or write their
/// own resolver from scratch — the kernel's `AgentChatController` only
/// requires a `Future<String?> Function(String agentId)`.
///
/// The composer is **stateless** beyond the four-axis snapshot it receives;
/// hosts can rebuild it on every dispatch (cheap) or cache it across
/// dispatches when the four-axis state has not changed.
library;

import 'package:mcp_bundle/mcp_bundle.dart'
    show
        Philosophy,
        ProfileContentSection,
        ProfileDefinition,
        SkillModule,
        SkillProcedure;

/// Plain text fact tuple supplied by the host. Kept minimal — facts in
/// `mcp_fact_graph` are richer, but the prompt only needs a one-liner for
/// each fact, so the host extracts what it wants and feeds it here.
class PromptFact {
  const PromptFact({required this.subject, required this.body, this.tag});
  final String subject;
  final String body;
  final String? tag;

  String render() {
    final tagSuffix = tag == null ? '' : ' [$tag]';
    return '$subject — $body$tagSuffix';
  }
}

/// Snapshot of the four-axis material relevant to a single agent turn.
/// Host code populates whichever axes it has loaded for the agent — any
/// axis left empty is silently skipped (the corresponding section header
/// is omitted from the composed prompt).
class FourAxisSnapshot {
  const FourAxisSnapshot({
    this.profile,
    this.skills = const <SkillModule>[],
    this.facts = const <PromptFact>[],
    this.philosophy = const <Philosophy>[],
  });

  /// Agent's owned profile (or pool starter the agent inherits).
  final ProfileDefinition? profile;

  /// Skills currently fork-assigned to the agent. Procedures across all
  /// of these are surfaced as a single bulleted list (de-duped by name).
  final List<SkillModule> skills;

  /// Facts the host considers relevant for the current turn. Order
  /// preserved.
  final List<PromptFact> facts;

  /// Philosophy statements assigned to the agent. Order preserved.
  final List<Philosophy> philosophy;

  bool get isEmpty =>
      profile == null &&
      skills.isEmpty &&
      facts.isEmpty &&
      philosophy.isEmpty;
}

class SystemPromptComposer {
  const SystemPromptComposer({
    this.includeProcedureSteps = false,
    this.maxFacts = 12,
    this.maxPhilosophyExamples = 0,
  });

  /// When `true`, [SkillProcedure.steps] are flattened into the prompt
  /// (numbered list per procedure). Default `false` keeps the prompt
  /// compact — the agent can read its own procedure store via host tools.
  final bool includeProcedureSteps;

  /// Hard ceiling on the number of facts that go into the prompt. Excess
  /// facts are silently dropped — host code chooses which facts matter.
  final int maxFacts;

  /// Per-philosophy example count to inline. Default `0` (statement +
  /// rationale only). `>0` includes the first N `Philosophy.examples` as
  /// bullet lines, useful when the agent role benefits from concrete
  /// illustrations.
  final int maxPhilosophyExamples;

  /// Compose the runtime prompt. Returns `null` when there's nothing to
  /// add (no agent prompt + empty snapshot) so the controller falls back
  /// to whatever `agent.systemPrompt` the registry already has.
  Future<String?> compose({
    required String? agentSystemPrompt,
    required FourAxisSnapshot snapshot,
  }) async {
    final hasBase = agentSystemPrompt != null && agentSystemPrompt.isNotEmpty;
    if (!hasBase && snapshot.isEmpty) return null;

    final parts = <String>[];
    if (hasBase) {
      parts.add(agentSystemPrompt.trim());
    }

    final profileBlock = _renderProfile(snapshot.profile);
    if (profileBlock != null) parts.add(profileBlock);

    final skillBlock = _renderSkills(snapshot.skills);
    if (skillBlock != null) parts.add(skillBlock);

    final factBlock = _renderFacts(snapshot.facts);
    if (factBlock != null) parts.add(factBlock);

    final philBlock = _renderPhilosophy(snapshot.philosophy);
    if (philBlock != null) parts.add(philBlock);

    return parts.join('\n\n');
  }

  /// Bind to a specific [snapshot] / [agentSystemPrompt] (or supplier
  /// callbacks) and return a [SystemPromptResolver]-shaped function. The
  /// resulting closure ignores its `agentId` argument — the host has
  /// already pre-loaded the relevant axes — so callers who want
  /// per-agent material wire one resolver per agent or supply suppliers.
  Future<String?> Function(String agentId) bind({
    required FourAxisSnapshot Function() snapshotSupplier,
    required String? Function() agentSystemPromptSupplier,
  }) {
    return (String agentId) => compose(
          agentSystemPrompt: agentSystemPromptSupplier(),
          snapshot: snapshotSupplier(),
        );
    // ignore: unused_local_variable
  }

  String? _renderProfile(ProfileDefinition? profile) {
    if (profile == null) return null;
    final sections = <ProfileContentSection>[...profile.sections]
      ..sort((a, b) => b.priority.compareTo(a.priority));
    if (sections.isEmpty) return null;
    final buf = StringBuffer('## Profile: ${profile.name}');
    if (profile.description != null && profile.description!.isNotEmpty) {
      buf
        ..writeln()
        ..writeln(profile.description);
    }
    for (final s in sections) {
      buf
        ..writeln()
        ..writeln('### ${s.name}')
        ..writeln(s.content.trim());
    }
    return buf.toString();
  }

  String? _renderSkills(List<SkillModule> skills) {
    if (skills.isEmpty) return null;
    final lines = <String>['## Skills'];
    final seen = <String>{};
    for (final m in skills) {
      for (final p in m.procedures) {
        final key = '${m.id}:${p.id}';
        if (!seen.add(key)) continue;
        final desc = (p.description == null || p.description!.isEmpty)
            ? ''
            : ' — ${p.description!.trim()}';
        lines.add('- **${m.name} · ${p.name}**$desc');
        if (includeProcedureSteps && p.steps.isNotEmpty) {
          for (var i = 0; i < p.steps.length; i++) {
            lines.add('  ${i + 1}. step ${p.steps[i].toString()}');
          }
        }
      }
    }
    if (lines.length == 1) return null;
    return lines.join('\n');
  }

  String? _renderFacts(List<PromptFact> facts) {
    if (facts.isEmpty) return null;
    final clipped = facts.length > maxFacts ? facts.sublist(0, maxFacts) : facts;
    final lines = <String>['## Facts'];
    for (final f in clipped) {
      lines.add('- ${f.render()}');
    }
    if (facts.length > maxFacts) {
      lines.add('- _(+${facts.length - maxFacts} more, host-truncated)_');
    }
    return lines.join('\n');
  }

  String? _renderPhilosophy(List<Philosophy> entries) {
    if (entries.isEmpty) return null;
    final lines = <String>['## Philosophy'];
    for (final ph in entries) {
      lines.add('- **${ph.name}** — ${ph.statement.trim()}');
      if (ph.rationale != null && ph.rationale!.isNotEmpty) {
        lines.add('  _why:_ ${ph.rationale!.trim()}');
      }
      if (maxPhilosophyExamples > 0 && ph.examples.isNotEmpty) {
        final ex = ph.examples.length > maxPhilosophyExamples
            ? ph.examples.sublist(0, maxPhilosophyExamples)
            : ph.examples;
        for (final e in ex) {
          lines.add('  e.g. ${e.description.trim()}');
        }
      }
    }
    return lines.join('\n');
  }
}
