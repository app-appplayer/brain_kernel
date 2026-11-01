import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_llm/mcp_llm.dart' as mll;
import 'package:test/test.dart';

/// Refuses `temperature` the way newer Claude models do.
class _StrictProvider implements mll.LlmProvider {
  final List<Map<String, dynamic>> seen = <Map<String, dynamic>>[];

  @override
  Future<mll.LlmResponse> complete(mll.LlmRequest request) async {
    seen.add(Map<String, dynamic>.of(request.parameters));
    if (request.parameters.containsKey('temperature')) {
      throw Exception('400 - `temperature` is deprecated for this model.');
    }
    return mll.LlmResponse(
        text: 'ok',
        metadata: const <String, dynamic>{'stop_reason': 'max_tokens'});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Counting implements mll.LlmProvider {
  @override
  Future<mll.LlmResponse> complete(mll.LlmRequest request) async =>
      mll.LlmResponse(text: 'ok', metadata: const <String, dynamic>{
        'input_tokens': 120,
        'output_tokens': 30,
      });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Failing implements mll.LlmProvider {
  int calls = 0;

  @override
  Future<mll.LlmResponse> complete(mll.LlmRequest request) async {
    calls++;
    throw Exception('500 - upstream failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a model that refuses temperature is retried without it, then remembered',
      () async {
    final provider = _StrictProvider();
    final llm = LlmPortAdapter.fromInterface(
        modelId: 'm', provider: provider, providerName: 'test');

    final first = await llm.complete(
        const mb.LlmRequest(prompt: 'a', temperature: 0));
    expect(first.content, 'ok');
    expect(provider.seen.length, 2);
    expect(provider.seen.first.containsKey('temperature'), isTrue);
    expect(provider.seen.last.containsKey('temperature'), isFalse);

    await llm.complete(const mb.LlmRequest(prompt: 'b', temperature: 0));
    expect(provider.seen.length, 3,
        reason: 'the refusal is remembered; no second failed attempt');
    expect(provider.seen.last.containsKey('temperature'), isFalse);
  });

  test('a request without a limit sends none unless the host set a default',
      () async {
    final plain = _StrictProvider();
    await LlmPortAdapter.fromInterface(
            modelId: 'm', provider: plain, providerName: 'test')
        .complete(const mb.LlmRequest(prompt: 'a'));
    expect(plain.seen.single.containsKey('max_tokens'), isFalse,
        reason: 'the provider keeps its own default, as before');

    final provider = _StrictProvider();
    final llm = LlmPortAdapter.fromInterface(
        modelId: 'm',
        provider: provider,
        providerName: 'test',
        defaultMaxTokens: 8192);
    await llm.complete(const mb.LlmRequest(prompt: 'a'));
    expect(provider.seen.single['max_tokens'], 8192);
    await llm.complete(const mb.LlmRequest(prompt: 'b', maxTokens: 50));
    expect(provider.seen.last['max_tokens'], 50);
  });

  test('why the provider stopped is passed on as finishReason', () async {
    final llm = LlmPortAdapter.fromInterface(
        modelId: 'm', provider: _StrictProvider(), providerName: 'test');
    final r = await llm.complete(const mb.LlmRequest(prompt: 'a'));
    expect(r.finishReason, 'max_tokens');
  });

  test('token counts the provider reports become usage and reach onUsage',
      () async {
    final seen = <List<Object>>[];
    final llm = LlmPortAdapter.fromInterface(
      modelId: 'm',
      provider: _Counting(),
      providerName: 'test',
      onUsage: (p, i, o) => seen.add([p, i, o]),
    );
    final r = await llm.complete(const mb.LlmRequest(prompt: 'a'));
    expect(r.usage!.inputTokens, 120);
    expect(r.usage!.outputTokens, 30);
    expect(seen, [
      ['test', 120, 30]
    ]);

    // A provider that does not report counts leaves usage empty and the
    // meter untouched.
    final quiet = LlmPortAdapter.fromInterface(
      modelId: 'm',
      provider: _StrictProvider(),
      providerName: 'test',
      onUsage: (p, i, o) => seen.add([p, i, o]),
    );
    expect((await quiet.complete(const mb.LlmRequest(prompt: 'a'))).usage,
        isNull);
    expect(seen.length, 1);
  });

  test('any other failure is not retried', () async {
    final provider = _Failing();
    final llm = LlmPortAdapter.fromInterface(
        modelId: 'm', provider: provider, providerName: 'test');
    await expectLater(
        llm.complete(const mb.LlmRequest(prompt: 'a', temperature: 0)),
        throwsA(isA<Exception>()));
    expect(provider.calls, 1);
  });
}
