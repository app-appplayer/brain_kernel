/// Every standard tool tells a caller what it is for and what it takes
/// (the listing a model reads), and what it says matches what the tool does.
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:brain_kernel/src/system/standard_tools/tool_specs.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:test/test.dart';

void main() {
  late KernelApp app;

  setUp(() async {
    app = await KernelApp.boot(
      workspaceId: 'ws',
      kvStorage: mb.InMemoryKvStoragePort(),
    );
    addTearDown(app.shutdown);
  });

  test('every standard tool is described', () {
    final missing = [
      for (final name in standardTools(app).keys)
        if (!standardToolSpecs.containsKey(name)) name,
    ];
    // The knowledge tools the knowledge store adds describe themselves.
    expect(missing, isEmpty);
    expect(
      standardToolSpecs.keys.toSet().difference(standardTools(app).keys.toSet()),
      isEmpty,
      reason: 'a description for a tool that is not there',
    );
  });

  test('a schema names the arguments it requires', () {
    standardToolSpecs.forEach((name, spec) {
      expect(spec.description.trim(), isNotEmpty, reason: name);
      final schema = spec.inputSchema;
      expect(schema['type'], 'object', reason: name);
      final props = (schema['properties'] as Map?) ?? const {};
      for (final r in (schema['required'] as List?) ?? const []) {
        expect(props, contains(r), reason: '$name requires $r');
      }
    });
  });

  test('every argument a schema names has a type', () {
    final lacking = <String>[];
    standardToolSpecs.forEach((name, spec) {
      final props = (spec.inputSchema['properties'] as Map?) ?? const {};
      props.forEach((key, value) {
        final p = value as Map;
        if (p['type'] == null && p['enum'] == null && p['oneOf'] == null) {
          lacking.add('$name.$key has no type');
        }
      });
    });
    expect(lacking, isEmpty);
  });

  test('a description says what the tool does, not that it exists', () {
    standardToolSpecs.forEach((name, spec) {
      expect(spec.description.startsWith('Standard kernel tool'), isFalse,
          reason: name);
      expect(spec.description.trim().split(RegExp(r'\s+')).length,
          greaterThanOrEqualTo(2),
          reason: name);
    });
  });

  test('the role and the axis a schema lists are the ones the tools take, '
      'and any other is refused',
      () async {
    final tools = standardTools(app);
    final create = standardToolSpecs['bk.agent.create']!.inputSchema;
    final roles = ((create['properties'] as Map)['role'] as Map)['enum'] as List;
    for (final role in roles) {
      final r = await tools['bk.agent.create']!(<String, dynamic>{
        'id': 'a-$role',
        'displayName': 'A',
        'role': role,
        'workspaceId': 'ws',
      });
      expect((r as Map)['ok'], isTrue, reason: '$role: $r');
    }
    final bad = await tools['bk.agent.create']!(<String, dynamic>{
      'id': 'a-bad',
      'displayName': 'A',
      'role': 'janitor',
      'workspaceId': 'ws',
    });
    expect((bad as Map)['ok'], isFalse, reason: '$bad');
    expect('${bad['error']}', contains('unknown role'));
    // A role left out is a worker.
    final plain = await tools['bk.agent.create']!(<String, dynamic>{
      'id': 'a-plain',
      'displayName': 'A',
      'workspaceId': 'ws',
    });
    expect((plain as Map)['agent']['role'], 'worker');

    final materialize = standardToolSpecs['bk.agent.materialize']!.inputSchema;
    final axes =
        ((materialize['properties'] as Map)['axis'] as Map)['enum'] as List;
    for (final axis in axes) {
      final r = await tools['bk.agent.materialize']!(<String, dynamic>{
        'agentId': 'a-worker',
        'axis': axis,
        'forkedRef': 'nothing',
      });
      // The axis is understood; what is missing is the thing to materialise.
      expect('${(r as Map)['error']}', isNot(contains('unknown axis')),
          reason: '$axis');
    }
    final badAxis = await tools['bk.agent.materialize']!(<String, dynamic>{
      'agentId': 'a-worker',
      'axis': 'mood',
      'forkedRef': 'nothing',
    });
    expect((badAxis as Map)['ok'], isFalse);
    expect('${badAxis['error']}', contains('unknown axis'));
  });

  test('a tool refuses a call that leaves out what its schema requires',
      () async {
    final tools = standardTools(app);
    for (final entry in standardToolSpecs.entries) {
      final required = (entry.value.inputSchema['required'] as List?) ?? [];
      if (required.isEmpty) continue;
      final answer = await tools[entry.key]!(<String, dynamic>{});
      expect(
        answer is Map && answer['ok'] == false,
        isTrue,
        reason: '${entry.key} accepted a call without $required: $answer',
      );
    }
  });
}
