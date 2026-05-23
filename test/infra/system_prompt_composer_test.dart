import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

ProfileDefinition _profile() => ProfileDefinition(
      id: 'p1',
      name: 'Reviewer',
      description: 'Strict, thorough, evidence-led.',
      version: '1',
      sections: [
        const ProfileContentSection(
            name: 'Tone', content: 'Plainspoken.', priority: 1),
        const ProfileContentSection(
            name: 'Bias', content: 'Prefer concrete over abstract.', priority: 5),
      ],
    );

SkillModule _skill() => const SkillModule(
      id: 's1',
      name: 'TriageBug',
      version: '1',
      description: 'Bug triage flow.',
      procedures: [
        SkillProcedure(
          id: 'classify',
          name: 'classify',
          description: 'Decide P0–P3.',
        ),
        SkillProcedure(
          id: 'reproduce',
          name: 'reproduce',
        ),
      ],
    );

Philosophy _phil() => const Philosophy(
      id: 'ph1',
      name: 'Honest doubt',
      statement: 'When uncertain, say so.',
      rationale: 'Hidden uncertainty compounds.',
    );

void main() {
  group('SystemPromptComposer', () {
    test('returns null when nothing to compose', () async {
      final r = await const SystemPromptComposer().compose(
        agentSystemPrompt: null,
        snapshot: const FourAxisSnapshot(),
      );
      expect(r, isNull);
    });

    test('agent systemPrompt alone is preserved', () async {
      final r = await const SystemPromptComposer().compose(
        agentSystemPrompt: 'You are Sara.',
        snapshot: const FourAxisSnapshot(),
      );
      expect(r, 'You are Sara.');
    });

    test('profile sections render highest priority first', () async {
      final r = await const SystemPromptComposer().compose(
        agentSystemPrompt: 'You are Sara.',
        snapshot: FourAxisSnapshot(profile: _profile()),
      );
      expect(r, isNotNull);
      // priority=5 ('Bias') should appear before priority=1 ('Tone').
      expect(r!.indexOf('Bias') < r.indexOf('Tone'), isTrue);
      expect(r, contains('## Profile: Reviewer'));
    });

    test('skill procedures collapse to bullet summary', () async {
      final r = await const SystemPromptComposer().compose(
        agentSystemPrompt: null,
        snapshot: FourAxisSnapshot(skills: [_skill()]),
      );
      expect(r, contains('## Skills'));
      expect(r, contains('TriageBug · classify'));
      expect(r, contains('TriageBug · reproduce'));
    });

    test('facts respect maxFacts ceiling and surface truncation note',
        () async {
      final facts = [
        for (var i = 0; i < 25; i++)
          PromptFact(subject: 'f$i', body: 'value-$i'),
      ];
      final r = await const SystemPromptComposer(maxFacts: 5).compose(
        agentSystemPrompt: null,
        snapshot: FourAxisSnapshot(facts: facts),
      );
      expect(r, contains('## Facts'));
      expect(r, contains('host-truncated'));
      expect('f5'.allMatches(r ?? '').length, 0,
          reason: 'fact #5 should be dropped beyond ceiling');
    });

    test('philosophy includes rationale by default', () async {
      final r = await const SystemPromptComposer().compose(
        agentSystemPrompt: null,
        snapshot: FourAxisSnapshot(philosophy: [_phil()]),
      );
      expect(r, contains('## Philosophy'));
      expect(r, contains('Honest doubt'));
      expect(r, contains('When uncertain'));
      expect(r, contains('_why:_'));
    });

    test('full stack composes in expected order', () async {
      final r = await const SystemPromptComposer().compose(
        agentSystemPrompt: 'You are Sara.',
        snapshot: FourAxisSnapshot(
          profile: _profile(),
          skills: [_skill()],
          facts: [
            const PromptFact(subject: 'service', body: 'paged at 03:14 UTC'),
          ],
          philosophy: [_phil()],
        ),
      );
      expect(r, isNotNull);
      final iAgent = r!.indexOf('You are Sara');
      final iProfile = r.indexOf('## Profile');
      final iSkills = r.indexOf('## Skills');
      final iFacts = r.indexOf('## Facts');
      final iPhil = r.indexOf('## Philosophy');
      expect(iAgent < iProfile, isTrue);
      expect(iProfile < iSkills, isTrue);
      expect(iSkills < iFacts, isTrue);
      expect(iFacts < iPhil, isTrue);
    });

    test('bind returns SystemPromptResolver-shaped closure', () async {
      var snapshot = const FourAxisSnapshot();
      var prompt = 'first';
      final composer = const SystemPromptComposer();
      final resolver = composer.bind(
        snapshotSupplier: () => snapshot,
        agentSystemPromptSupplier: () => prompt,
      );

      var r = await resolver('agentA');
      expect(r, 'first');

      // Suppliers re-evaluated on each call → live binding.
      prompt = 'second';
      snapshot = FourAxisSnapshot(philosophy: [_phil()]);
      r = await resolver('agentA');
      expect(r, contains('second'));
      expect(r, contains('Honest doubt'));
    });
  });
}
