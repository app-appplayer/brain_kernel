import 'package:brain_kernel/brain_kernel.dart';
import 'package:test/test.dart';

LlmPortAdapter _adapter(String modelId, {String key = 'sk-test'}) {
  return LlmPortAdapter(modelId: modelId, apiKey: key);
}

void main() {
  group('AgentLlmSessions', () {
    test('register / providers / contains / get', () {
      final pool = AgentLlmSessions();
      expect(pool.providers, isEmpty);

      final opus = _adapter('claude-opus-4-7');
      pool.register('anthropic', opus);
      expect(pool.contains('anthropic'), isTrue);
      expect(pool.get('anthropic'), same(opus));
      expect(pool.providers, hasLength(1));
      expect(pool.providers['anthropic'], same(opus));
    });

    test('replace at key invalidates only that slot', () {
      final pool = AgentLlmSessions();
      final opus = _adapter('claude-opus-4-7');
      final sonnet = _adapter('claude-sonnet-4-6');
      final gpt = _adapter('gpt-5');

      pool.register('anthropic', opus);
      pool.register('openai', gpt);

      pool.register('anthropic', sonnet);

      expect(pool.get('anthropic'), same(sonnet));
      expect(pool.get('openai'), same(gpt));
      expect(pool.providers, hasLength(2));
    });

    test('rebuild swaps the adapter via factory', () {
      final pool = AgentLlmSessions();
      pool.register('anthropic', _adapter('claude-opus-4-7'));
      var built = 0;
      pool.rebuild('anthropic', () {
        built += 1;
        return _adapter('claude-opus-4-7', key: 'sk-rotated');
      });
      expect(built, 1);
      expect(pool.get('anthropic')!.apiKey, 'sk-rotated');
    });

    test('unregister / clear', () {
      final pool = AgentLlmSessions();
      pool.register('a', _adapter('m1'));
      pool.register('b', _adapter('m2'));
      pool.unregister('a');
      expect(pool.contains('a'), isFalse);
      expect(pool.contains('b'), isTrue);
      pool.clear();
      expect(pool.providers, isEmpty);
    });

    test('initial seed populates the pool', () {
      final opus = _adapter('claude-opus-4-7');
      final pool = AgentLlmSessions(initial: {'anthropic': opus});
      expect(pool.get('anthropic'), same(opus));
    });

    test('providers view is unmodifiable', () {
      final pool = AgentLlmSessions();
      pool.register('a', _adapter('m1'));
      expect(() => pool.providers['b'] = _adapter('m2'),
          throwsA(isA<UnsupportedError>()));
    });
  });
}
