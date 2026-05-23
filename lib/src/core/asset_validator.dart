/// Four-layer asset validator (MOD-CORE-006).
///
/// This first-pass implementation supplies the two fast layers — schema
/// and cross-reference — that the patch pipeline runs on every mutation.
/// Runtime (`flowbrain.importBundle` dry-run) and behavioral (gold
/// question) layers are stubbed and will be wired in later rounds.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;
import 'package:mcp_bundle/mcp_bundle.dart' show McpBundle;

import 'asset_category_map.dart';
import '../feat/gold_question_runner.dart';
import 'types.dart';

/// Which validator pass produced an issue.
enum ValidationLayer { schema, crossRef, runtime, behavioral }

/// Callback that probes the runtime layer (DDD-05 §2.3). Defined here so
/// the validator stays decoupled from `flowbrain`. A typical
/// implementation runs `KnowledgeSystem.importBundle` in a
/// `__validate__` workspace and converts `BundleImportSummary` /
/// thrown errors into a [ValidationReport].
typedef RuntimeProbeFn = Future<ValidationReport> Function(McpBundle bundle);

/// Severity of a [ValidationIssue].
enum ValidationSeverity { error, warning, info }

/// One row in a [ValidationReport].
class ValidationIssue {
  const ValidationIssue({
    required this.severity,
    required this.code,
    required this.message,
    required this.layer,
    this.pointer,
  });

  final ValidationSeverity severity;
  final String code;
  final String message;
  final ValidationLayer layer;
  final String? pointer;
}

/// Aggregated validator output. `isValid == errors.isEmpty`.
class ValidationReport {
  const ValidationReport({
    required this.errors,
    required this.warnings,
    required this.infos,
  });

  factory ValidationReport.empty() =>
      const ValidationReport(errors: [], warnings: [], infos: []);

  /// Combine multiple reports preserving order. Used by the patch
  /// pipeline to merge fast-path layers (DDD-05 §10).
  static ValidationReport merge(List<ValidationReport> parts) {
    final errors = <ValidationIssue>[];
    final warnings = <ValidationIssue>[];
    final infos = <ValidationIssue>[];
    for (final p in parts) {
      errors.addAll(p.errors);
      warnings.addAll(p.warnings);
      infos.addAll(p.infos);
    }
    return ValidationReport(
        errors: errors, warnings: warnings, infos: infos);
  }

  final List<ValidationIssue> errors;
  final List<ValidationIssue> warnings;
  final List<ValidationIssue> infos;

  bool get isValid => errors.isEmpty;
}

/// Stateless validator. Holds no canonical reference — the canonical
/// (or a probed copy) is passed in as needed.
class AssetValidator {
  const AssetValidator({
    this.goldRunner = const GoldQuestionRunner(),
  });

  final GoldQuestionRunner goldRunner;

  /// Layer 1 — schema. Currently delegates to `mcp_bundle`'s built-in
  /// validator. The runtime layer in a later round will plug into
  /// `KnowledgeSystem.importBundle`.
  ValidationReport validateSchema(McpBundle bundle) {
    final result = mb.McpBundleValidator.validateSchema(bundle);
    return _adaptValidationResult(result, ValidationLayer.schema);
  }

  /// Layer 2 — cross-section reference integrity (Agent → 4-axis ids,
  /// Skill → knowledge sources / mcp tools, duplicate ids inside a
  /// section).
  ValidationReport validateCrossRef(McpBundle bundle) {
    final errors = <ValidationIssue>[];
    final warnings = <ValidationIssue>[];

    final ids = <AssetCategory, Set<String>>{
      for (final cat in AssetCategory.values)
        cat: AssetCategoryMap.currentIds(bundle, cat).toSet(),
    };

    // Duplicate ids inside each section.
    for (final cat in AssetCategory.values) {
      final list = AssetCategoryMap.currentIds(bundle, cat);
      final seen = <String>{};
      for (final id in list) {
        if (!seen.add(id)) {
          errors.add(ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'KB-CR-DUP-ID',
            message: 'Duplicate id "$id" in ${cat.name}',
            layer: ValidationLayer.crossRef,
            pointer:
                '${AssetCategoryMap.of(cat).jsonPointerPrefix}/$id',
          ));
        }
      }
    }

    // Agent four-axis bindings must exist.
    for (final agent in bundle.agents?.agents ?? const []) {
      _checkAgentRefs(
        agent.id,
        'profileIds',
        agent.profileIds,
        ids[AssetCategory.profile]!,
        'KB-CR-AGENT-PROFILE-MISSING',
        errors,
      );
      _checkAgentRefs(
        agent.id,
        'skillIds',
        agent.skillIds,
        ids[AssetCategory.skill]!,
        'KB-CR-AGENT-SKILL-MISSING',
        errors,
      );
      _checkAgentRefs(
        agent.id,
        'philosophyIds',
        agent.philosophyIds,
        ids[AssetCategory.philosophy]!,
        'KB-CR-AGENT-PHILOSOPHY-MISSING',
        errors,
      );
      // Fact source ids may resolve to either the fact graph or a
      // knowledge source. Both pools are checked; only when neither
      // matches do we emit an error.
      final knownFactSources = <String>{
        ...ids[AssetCategory.fact]!,
        for (final src in bundle.knowledge?.sources ?? const []) src.id,
      };
      _checkAgentRefs(
        agent.id,
        'factSourceIds',
        agent.factSourceIds,
        knownFactSources,
        'KB-CR-AGENT-FACT-MISSING',
        errors,
      );
    }

    // Skill knowledgeSources should resolve to an existing source.
    for (final skill in bundle.skills?.modules ?? const []) {
      final knowledgeSources = <String>{
        for (final src in bundle.knowledge?.sources ?? const []) src.id,
      };
      for (final ks in skill.knowledgeSources) {
        if (!knowledgeSources.contains(ks.sourceId) &&
            !ks.sourceId.startsWith('asset:')) {
          warnings.add(ValidationIssue(
            severity: ValidationSeverity.warning,
            code: 'KB-CR-SKILL-KNOWLEDGE-MISSING',
            message:
                'Skill "${skill.id}" references unknown knowledge source "${ks.sourceId}"',
            layer: ValidationLayer.crossRef,
            pointer:
                '/skills/modules/${skill.id}/knowledgeSources',
          ));
        }
      }
    }

    return ValidationReport(
      errors: errors,
      warnings: warnings,
      infos: const [],
    );
  }

  /// Layer 3 — runtime probe.
  ///
  /// The validator stays decoupled from flowbrain: callers pass a
  /// [RuntimeProbeFn] (typically built by `FlowBrainRuntimeProbe`) that
  /// runs `KnowledgeSystem.importBundle` in a `__validate__` workspace
  /// and returns the resulting [ValidationReport]. When [probe] is null
  /// — the default for the patch pipeline's fast path — this layer is
  /// a no-op.
  Future<ValidationReport> validateRuntime(
    McpBundle bundle, {
    RuntimeProbeFn? probe,
  }) async {
    if (probe == null) return ValidationReport.empty();
    return probe(bundle);
  }

  /// Layer 4 — behavioural / gold questions. Each gold question that
  /// fails to surface its expected chunks within the top-K BM25 hits
  /// becomes a `KB-BH-GOLD-MISS` warning. A failed gold question is a
  /// quality signal, not a hard error — Build proceeds unless the host
  /// chooses to gate on warnings as well.
  Future<ValidationReport> validateBehavioral(
    McpBundle bundle,
    List<GoldQuestion> goldSet,
  ) async {
    if (goldSet.isEmpty) return ValidationReport.empty();
    final verdicts = await goldRunner.runAll(bundle, goldSet);
    final warnings = <ValidationIssue>[];
    final infos = <ValidationIssue>[];
    for (final v in verdicts) {
      if (v.passed) {
        infos.add(ValidationIssue(
          severity: ValidationSeverity.info,
          code: 'KB-BH-GOLD-PASS',
          message: 'Gold question "${v.question.id}" passed',
          layer: ValidationLayer.behavioral,
        ));
        continue;
      }
      warnings.add(ValidationIssue(
        severity: ValidationSeverity.warning,
        code: 'KB-BH-GOLD-MISS',
        message:
            'Gold question "${v.question.id}" did not surface expected chunks: ${v.reason}',
        layer: ValidationLayer.behavioral,
      ));
    }
    return ValidationReport(
      errors: const [],
      warnings: warnings,
      infos: infos,
    );
  }

  /// Run schema + cross-ref + runtime + behavioral, merging all reports.
  Future<ValidationReport> validateAll(
    McpBundle bundle, {
    RuntimeProbeFn? runtimeProbe,
    List<GoldQuestion>? goldSet,
  }) async {
    final fast = ValidationReport.merge([
      validateSchema(bundle),
      validateCrossRef(bundle),
    ]);
    if (fast.errors.isNotEmpty) return fast;
    final runtime = await validateRuntime(bundle, probe: runtimeProbe);
    final beh = goldSet == null || goldSet.isEmpty
        ? ValidationReport.empty()
        : await validateBehavioral(bundle, goldSet);
    return ValidationReport.merge([fast, runtime, beh]);
  }

  void _checkAgentRefs(
    String agentId,
    String field,
    List<String> refs,
    Set<String> pool,
    String code,
    List<ValidationIssue> errors,
  ) {
    for (final ref in refs) {
      if (!pool.contains(ref)) {
        errors.add(ValidationIssue(
          severity: ValidationSeverity.error,
          code: code,
          message:
              'Agent "$agentId" $field references unknown id "$ref"',
          layer: ValidationLayer.crossRef,
          pointer: '/agents/agents/$agentId/$field',
        ));
      }
    }
  }
}

ValidationReport _adaptValidationResult(
  mb.ValidationResult result,
  ValidationLayer layer,
) {
  final errors = <ValidationIssue>[];
  final warnings = <ValidationIssue>[];
  for (final e in result.errors) {
    errors.add(ValidationIssue(
      severity: ValidationSeverity.error,
      code: e.code,
      message: e.message,
      layer: layer,
      pointer: e.location,
    ));
  }
  for (final w in result.warnings) {
    warnings.add(ValidationIssue(
      severity: ValidationSeverity.warning,
      code: w.code,
      message: w.message,
      layer: layer,
      pointer: w.location,
    ));
  }
  return ValidationReport(
      errors: errors, warnings: warnings, infos: const []);
}
