/// Adapter that wires `FlowBrainWiring` into `AssetValidator`'s
/// runtime layer (DDD-05 §2.3 / DDD-24 §4).
///
/// Calls `KnowledgeSystem.importBundle(bundle, workspaceId: '__validate__')`
/// and translates the resulting `BundleImportSummary` (or any thrown
/// error) into a [ValidationReport]. Lives in `src/runtime/` so the
/// core validator can stay decoupled from `package:flowbrain`.
library;

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart'
    show McpBundle;

import '../../core/asset_validator.dart';
import 'flowbrain_wiring.dart';

class FlowBrainRuntimeProbe {
  FlowBrainRuntimeProbe(
    this.wiring, {
    this.workspaceId = '__validate__',
  });

  final FlowBrainWiring wiring;
  final String workspaceId;

  /// Wraps the probe call in the [RuntimeProbeFn] shape so it can drop
  /// straight into `validator.validateAll(runtimeProbe: probe.fn, …)`.
  RuntimeProbeFn get fn => probe;

  Future<ValidationReport> probe(McpBundle bundle) async {
    if (!wiring.isBooted) {
      return const ValidationReport(
        errors: [
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'KB-RT-WIRING-NOT-BOOTED',
            message:
                'FlowBrainWiring has not been booted — call wiring.boot() before runtime validation.',
            layer: ValidationLayer.runtime,
          ),
        ],
        warnings: [],
        infos: [],
      );
    }
    try {
      final summary =
          await wiring.system.importBundle(bundle, workspaceId: workspaceId);
      return _summaryToReport(summary);
    } catch (e) {
      return ValidationReport(
        errors: [
          ValidationIssue(
            severity: ValidationSeverity.error,
            code: 'KB-RT-IMPORT-FAILED',
            message: 'FlowBrain import dry-run failed: $e',
            layer: ValidationLayer.runtime,
          ),
        ],
        warnings: const [],
        infos: const [],
      );
    }
  }

  ValidationReport _summaryToReport(fb.BundleImportSummary summary) {
    final infos = <ValidationIssue>[
      ValidationIssue(
        severity: ValidationSeverity.info,
        code: 'KB-RT-IMPORT-OK',
        message:
            'FlowBrain import dry-run succeeded — philosophies: ${summary.philosophiesAdded}, agents: ${summary.agentsAdded}, skipped: ${summary.agentsSkipped}',
        layer: ValidationLayer.runtime,
      ),
    ];
    final warnings = <ValidationIssue>[];
    if (summary.agentsSkipped > 0) {
      warnings.add(ValidationIssue(
        severity: ValidationSeverity.warning,
        code: 'KB-RT-AGENT-SKIPPED',
        message:
            '${summary.agentsSkipped} agent(s) skipped during import (duplicate id or already registered in workspace)',
        layer: ValidationLayer.runtime,
      ));
    }
    return ValidationReport(
      errors: const [],
      warnings: warnings,
      infos: infos,
    );
  }
}
