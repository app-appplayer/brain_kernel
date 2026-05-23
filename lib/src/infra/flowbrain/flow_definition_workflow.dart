/// `FlowDefinitionWorkflow` — declarative-spec adapter with concrete
/// run() execution.
///
/// Generic `Workflow` adapter inside the kernel. Wraps an
/// `mb.FlowDefinition` (a `bundle.flow.flows[]` entry) into an
/// mcp_knowledge_ops `Workflow<Map, Map>` instance and dispatches
/// each step inside `run()` (mcp_knowledge_ops convention — the
/// Workflow class itself is the execution unit).
///
/// `host_bundle_activation.registerFlow` registers an instance via
/// `OpsRuntime.workflowRegistry[id] = () => FlowDefinitionWorkflow(flow)`,
/// so `OpsFacade.runWorkflow` runs the steps end-to-end.
///
/// Supported StepTypes (mb.StepType enum, 11 cases):
///   - action / api → `toolDispatcher` (host MCP `server.callTool`)
///   - skill        → `SkillFacade.execute`
///   - llm          → `LlmPort.complete`
///   - flow         → recursive `OpsFacade.runWorkflow`
///   - wait         → `Future.delayed`
///   - setVar       → state mutate
///   - transform    → input → output mapping
///   - output       → state pass-through (final stage)
///   - condition    → boolean state check + skip
///   - switchCase   → state value → branch (declared-order
///                    fallback for now)
///   - parallel / loop / unknown → declared-order fallback
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_knowledge_ops/mcp_knowledge_ops.dart' as fb;

/// Function signatures the host injects so each step type knows
/// where to dispatch.
typedef ToolDispatcher = Future<dynamic> Function(
    String tool, Map<String, dynamic> args);
typedef SkillRunner = Future<dynamic> Function(
    String skillId, Map<String, dynamic> inputs);
typedef LlmComplete = Future<String> Function(String prompt);
typedef SubFlowRunner = Future<Map<String, dynamic>> Function(
    String flowId, Map<String, dynamic> input);

class FlowDefinitionWorkflow
    extends fb.Workflow<Map<String, dynamic>, Map<String, dynamic>> {
  FlowDefinitionWorkflow(
    this.definition, {
    this.toolDispatcher,
    this.skillRunner,
    this.llmComplete,
    this.subFlowRunner,
  });

  /// The declarative spec from `bundle.flow.flows[]`.
  final mb.FlowDefinition definition;

  /// `action` / `api` step execution path — host MCP `server.callTool`.
  final ToolDispatcher? toolDispatcher;

  /// `skill` step execution path — `SkillFacade.execute`.
  final SkillRunner? skillRunner;

  /// `llm` step execution path — `LlmPort.complete`.
  final LlmComplete? llmComplete;

  /// `flow` step execution path — recursive `OpsFacade.runWorkflow`.
  final SubFlowRunner? subFlowRunner;

  @override
  String get id => definition.id;

  @override
  String get name => definition.name;

  @override
  String get version => '1.0.0';

  @override
  String? get description => definition.description;

  @override
  fb.WorkflowConfig get config => const fb.WorkflowConfig();

  @override
  List<fb.Gate> get gates => const <fb.Gate>[];

  @override
  List<fb.WorkflowStage> get stages {
    final out = <fb.WorkflowStage>[];
    for (var i = 0; i < definition.steps.length; i++) {
      final s = definition.steps[i];
      out.add(fb.WorkflowStage(
        id: s.id,
        name: s.name ?? s.id,
        handler: s.type.name,
        type: fb.WorkflowStageType.task,
        order: i + 1,
        condition: s.condition,
        config: Map<String, dynamic>.from(s.config),
      ));
    }
    return out;
  }

  @override
  Future<fb.WorkflowResult<Map<String, dynamic>>> run(
    Map<String, dynamic> input,
    fb.WorkflowContext context,
  ) async {
    final state = <String, dynamic>{...input};
    final stageResults = <fb.StageResult>[];
    final startedAt = DateTime.now();

    for (final step in definition.steps) {
      final stageStart = DateTime.now();

      // condition: simple expressions only (`key`, `key == value`).
      // Complex expressions await an ExpressionEvaluator.
      if (step.condition != null &&
          step.condition!.isNotEmpty &&
          !_evalCondition(step.condition!, state)) {
        stageResults.add(fb.StageResult(
          stageId: step.id,
          status: fb.StageStatus.skipped,
          startedAt: stageStart,
          completedAt: DateTime.now(),
        ));
        continue;
      }

      try {
        final stepOutput = await _dispatchStep(step, state, context);
        if (stepOutput != null) {
          state.addAll(stepOutput);
          // Mirror the output under the step's id so downstream steps
          // can reference `<step.id>.<key>` via dot-path.
          state[step.id] = stepOutput;
        }
        stageResults.add(fb.StageResult.completed(
          step.id,
          stepOutput,
          DateTime.now().difference(stageStart),
        ));
      } catch (e) {
        stageResults.add(fb.StageResult(
          stageId: step.id,
          status: fb.StageStatus.failed,
          error: e.toString(),
          startedAt: stageStart,
          completedAt: DateTime.now(),
        ));
        // step.onError set → continue to next step. Empty / null →
        // surface as workflow failure.
        if (step.onError == null || step.onError!.isEmpty) {
          return fb.WorkflowResult.failure(
            error: fb.WorkflowError(
              code: 'STEP_FAILED',
              message: '${step.id}: $e',
              stageId: step.id,
            ),
            stages: stageResults,
            metrics: fb.WorkflowMetrics(
              totalDuration: DateTime.now().difference(startedAt),
            ),
          );
        }
      }
    }

    return fb.WorkflowResult.success(
      output: state,
      stages: stageResults,
      metrics: fb.WorkflowMetrics(
        totalDuration: DateTime.now().difference(startedAt),
      ),
    );
  }

  // ── Step dispatch ───────────────────────────────────────────────

  Future<Map<String, dynamic>?> _dispatchStep(
    mb.FlowStep step,
    Map<String, dynamic> state,
    fb.WorkflowContext context,
  ) async {
    switch (step.type) {
      case mb.StepType.action:
      case mb.StepType.api:
        return _execTool(step);
      case mb.StepType.skill:
        return _execSkill(step);
      case mb.StepType.llm:
        return _execLlm(step);
      case mb.StepType.flow:
        return _execFlow(step);
      case mb.StepType.wait:
        return _execWait(step);
      case mb.StepType.setVar:
        return _execSetVar(step);
      case mb.StepType.transform:
        return _execTransform(step, state);
      case mb.StepType.output:
        return null; // state pass-through
      case mb.StepType.condition:
        return null; // skip handled by condition field above
      case mb.StepType.switchCase:
        return _execSwitch(step, state, context);
      case mb.StepType.parallel:
        return _execParallel(step, state, context);
      case mb.StepType.loop:
        return _execLoop(step, state, context);
      case mb.StepType.unknown:
        return null; // unknown — declared-order fallback
    }
  }

  Future<Map<String, dynamic>> _execTool(mb.FlowStep step) async {
    final fn = toolDispatcher;
    if (fn == null) {
      throw StateError('toolDispatcher not wired (step.id=${step.id})');
    }
    final tool = step.config['tool'] as String?;
    if (tool == null || tool.isEmpty) {
      throw FormatException('step.config.tool required (step.id=${step.id})');
    }
    final args = (step.config['args'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final result = await fn(tool, args);
    return <String, dynamic>{'result': result};
  }

  Future<Map<String, dynamic>> _execSkill(mb.FlowStep step) async {
    final fn = skillRunner;
    if (fn == null) {
      throw StateError('skillRunner not wired (step.id=${step.id})');
    }
    final skillId = step.config['skillId'] as String? ??
        step.config['skill'] as String?;
    if (skillId == null || skillId.isEmpty) {
      throw FormatException('step.config.skillId required');
    }
    final inputs = (step.config['inputs'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final result = await fn(skillId, inputs);
    return <String, dynamic>{'result': result};
  }

  Future<Map<String, dynamic>> _execLlm(mb.FlowStep step) async {
    final fn = llmComplete;
    if (fn == null) {
      throw StateError('llmComplete not wired (step.id=${step.id})');
    }
    final prompt = step.config['prompt'] as String?;
    if (prompt == null || prompt.isEmpty) {
      throw FormatException('step.config.prompt required');
    }
    final result = await fn(prompt);
    return <String, dynamic>{'result': result};
  }

  Future<Map<String, dynamic>> _execFlow(mb.FlowStep step) async {
    final fn = subFlowRunner;
    if (fn == null) {
      throw StateError('subFlowRunner not wired (step.id=${step.id})');
    }
    final flowId = step.config['flowId'] as String?;
    if (flowId == null || flowId.isEmpty) {
      throw FormatException('step.config.flowId required');
    }
    final input = (step.config['input'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final result = await fn(flowId, input);
    return result;
  }

  Future<Map<String, dynamic>> _execWait(mb.FlowStep step) async {
    final ms = (step.config['ms'] as num?)?.toInt() ?? 1000;
    await Future<void>.delayed(Duration(milliseconds: ms));
    return <String, dynamic>{'waited': ms};
  }

  Map<String, dynamic> _execSetVar(mb.FlowStep step) {
    final key = step.config['key'] as String?;
    if (key == null || key.isEmpty) {
      throw FormatException('step.config.key required');
    }
    return <String, dynamic>{key: step.config['value']};
  }

  Map<String, dynamic> _execTransform(
      mb.FlowStep step, Map<String, dynamic> state) {
    // Simple mapping: step.config.outputs = {newKey: <stateKey>}.
    // Complex expressions await ExpressionEvaluator.
    final outputs = (step.config['outputs'] as Map?)?.cast<String, dynamic>();
    if (outputs == null) return const <String, dynamic>{};
    final result = <String, dynamic>{};
    for (final entry in outputs.entries) {
      final source = entry.value;
      if (source is String) {
        result[entry.key] = state[source];
      } else {
        result[entry.key] = source;
      }
    }
    return result;
  }

  /// switchCase: pick a branch from `config.cases[<state[match]>]`,
  /// falling back to `config.default`. Branch can be a single step
  /// or a list of steps; both are decoded via `mb.FlowStep.fromJson`.
  Future<Map<String, dynamic>?> _execSwitch(
    mb.FlowStep step,
    Map<String, dynamic> state,
    fb.WorkflowContext context,
  ) async {
    final matchKey = step.config['match'] as String?;
    if (matchKey == null) {
      throw FormatException('switchCase.config.match required');
    }
    final value = _resolveValue(matchKey, state)?.toString() ?? '';
    final cases = (step.config['cases'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final selected = cases[value] ?? step.config['default'];
    if (selected == null) return null;
    final substeps = _decodeSteps(selected);
    final merged = <String, dynamic>{};
    for (final s in substeps) {
      final out = await _dispatchStep(s, {...state, ...merged}, context);
      if (out != null) merged.addAll(out);
    }
    return merged;
  }

  /// parallel: run every step in `config.steps` concurrently via
  /// `Future.wait`.
  Future<Map<String, dynamic>?> _execParallel(
    mb.FlowStep step,
    Map<String, dynamic> state,
    fb.WorkflowContext context,
  ) async {
    final substeps = _decodeSteps(step.config['steps']);
    if (substeps.isEmpty) return null;
    final results = await Future.wait<Map<String, dynamic>?>(
      substeps.map((s) => _dispatchStep(s, state, context)),
    );
    final merged = <String, dynamic>{};
    for (var i = 0; i < results.length; i++) {
      final out = results[i];
      if (out != null) {
        merged[substeps[i].id] = out;
        merged.addAll(out);
      }
    }
    return merged;
  }

  /// loop: when `state[config.collection]` is a List, run
  /// `config.body` for each element. The element is exposed under
  /// `config.itemKey ?? 'item'`, the index under `<itemKey>Index`.
  Future<Map<String, dynamic>?> _execLoop(
    mb.FlowStep step,
    Map<String, dynamic> state,
    fb.WorkflowContext context,
  ) async {
    final collectionKey = step.config['collection'] as String?;
    if (collectionKey == null) {
      throw FormatException('loop.config.collection required');
    }
    final raw = _resolveValue(collectionKey, state);
    if (raw is! List) {
      throw FormatException(
          'loop.collection "$collectionKey" not a List (got ${raw?.runtimeType})');
    }
    final itemKey = step.config['itemKey'] as String? ?? 'item';
    final body = _decodeSteps(step.config['body']);
    final iterations = <Map<String, dynamic>>[];
    for (var i = 0; i < raw.length; i++) {
      final iterState = <String, dynamic>{
        ...state,
        itemKey: raw[i],
        '${itemKey}Index': i,
      };
      final out = <String, dynamic>{};
      for (final s in body) {
        final r = await _dispatchStep(s, {...iterState, ...out}, context);
        if (r != null) out.addAll(r);
      }
      iterations.add(out);
    }
    return <String, dynamic>{'iterations': iterations};
  }

  /// Decode a `raw` value into a list of FlowStep entries. Accepts a
  /// single step map or a list of step maps; other shapes return an
  /// empty list.
  List<mb.FlowStep> _decodeSteps(dynamic raw) {
    if (raw == null) return const <mb.FlowStep>[];
    if (raw is Map) {
      return <mb.FlowStep>[
        mb.FlowStep.fromJson(Map<String, dynamic>.from(raw)),
      ];
    }
    if (raw is List) {
      return <mb.FlowStep>[
        for (final entry in raw)
          if (entry is Map)
            mb.FlowStep.fromJson(Map<String, dynamic>.from(entry)),
      ];
    }
    return const <mb.FlowStep>[];
  }

  bool _evalCondition(String expr, Map<String, dynamic> state) {
    final trimmed = expr.trim();
    if (trimmed.isEmpty) return true;

    // Boolean combinators (left-to-right, lowest precedence first).
    // Sub-expressions recurse back into `_evalCondition` —
    // `||` / `&&` / comparators / truthy in that order.
    final orParts = _splitTop(trimmed, '||');
    if (orParts.length > 1) {
      return orParts.any((p) => _evalCondition(p, state));
    }
    final andParts = _splitTop(trimmed, '&&');
    if (andParts.length > 1) {
      return andParts.every((p) => _evalCondition(p, state));
    }

    // Comparators — match `!=` before `==`, and `>=` / `<=` before
    // `>` / `<`.
    for (final op in <String>['!=', '>=', '<=', '==', '>', '<']) {
      final idx = trimmed.indexOf(op);
      if (idx < 0) continue;
      final lhsKey = trimmed.substring(0, idx).trim();
      final rhsRaw = trimmed.substring(idx + op.length).trim();
      final lhs = _resolveValue(lhsKey, state);
      final rhs = _parseLiteral(rhsRaw);
      switch (op) {
        case '==':
          return _equals(lhs, rhs);
        case '!=':
          return !_equals(lhs, rhs);
        case '>':
          return _toNum(lhs) > _toNum(rhs);
        case '<':
          return _toNum(lhs) < _toNum(rhs);
        case '>=':
          return _toNum(lhs) >= _toNum(rhs);
        case '<=':
          return _toNum(lhs) <= _toNum(rhs);
      }
    }

    // Truthy fallback.
    final v = _resolveValue(trimmed, state);
    return v == true ||
        (v is String && v.isNotEmpty) ||
        (v is num && v != 0) ||
        (v is List && v.isNotEmpty) ||
        (v is Map && v.isNotEmpty);
  }

  /// Split `expr` by `op` at the top level. The simple parser does
  /// not yet support parentheses so this returns a single-element
  /// list when `op` is absent.
  List<String> _splitTop(String expr, String op) {
    final out = <String>[];
    var start = 0;
    var i = 0;
    while (i <= expr.length - op.length) {
      if (expr.substring(i, i + op.length) == op) {
        out.add(expr.substring(start, i).trim());
        start = i + op.length;
        i = start;
      } else {
        i++;
      }
    }
    out.add(expr.substring(start).trim());
    return out;
  }

  dynamic _resolveValue(String token, Map<String, dynamic> state) {
    final t = token.trim();
    final lit = _parseLiteral(t);
    if (lit != null || t == 'null') return lit;
    // Dot-path resolution (e.g. `step1.result.value`).
    if (t.contains('.')) {
      final parts = t.split('.');
      dynamic cur = state[parts.first];
      for (var i = 1; i < parts.length; i++) {
        if (cur is Map) {
          cur = cur[parts[i]];
        } else {
          return null;
        }
      }
      return cur;
    }
    return state[t];
  }

  dynamic _parseLiteral(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t == 'true') return true;
    if (t == 'false') return false;
    if (t == 'null') return null;
    if ((t.startsWith("'") && t.endsWith("'")) ||
        (t.startsWith('"') && t.endsWith('"'))) {
      return t.substring(1, t.length - 1);
    }
    final n = num.tryParse(t);
    if (n != null) return n;
    return null;
  }

  bool _equals(dynamic a, dynamic b) {
    if (a == null || b == null) return a == b;
    if (a is num && b is num) return a == b;
    return a.toString() == b.toString();
  }

  num _toNum(dynamic v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v) ?? 0;
    if (v is bool) return v ? 1 : 0;
    return 0;
  }
}
