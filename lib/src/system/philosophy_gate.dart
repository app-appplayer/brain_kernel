/// The check a skill run passes before it starts (platform spec 12 §4, 30 §8).
///
/// The active ethos is asked whether the action breaks a prohibition:
/// * a hard violation stops the run — no one is asked, there is nothing to
///   confirm;
/// * a soft violation goes to the host's confirmation, which must be able to
///   say no; with no confirmation the run goes on and the violations come back
///   as warnings;
/// * an engine that is not wired lets the run through (nothing to check
///   against); any other failure of the check stops the run — a check that
///   could not be made is not a pass.
library;

import 'package:flowbrain_core/flowbrain_core.dart' as fb;
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

/// Asks the person about soft violations of [action]; true lets it run.
typedef SoftViolationConfirm = Future<bool> Function(
  String action,
  List<String> violations,
);

class GateVerdict {
  const GateVerdict.allow([this.warnings = const <String>[]])
      : allowed = true,
        reason = null;
  const GateVerdict.block(this.reason)
      : allowed = false,
        warnings = const <String>[];

  final bool allowed;
  final String? reason;
  final List<String> warnings;
}

class PhilosophyGate {
  PhilosophyGate(this._philosophy, {SoftViolationConfirm? confirm})
      : _confirm = confirm;

  final fb.PhilosophyFacade Function() _philosophy;
  final SoftViolationConfirm? _confirm;

  Future<GateVerdict> check(
    String action, {
    Map<String, dynamic> context = const <String, dynamic>{},
  }) async {
    final fb.PhilosophyFacade philosophy;
    try {
      philosophy = _philosophy();
      if (!philosophy.isAvailable) return const GateVerdict.allow();
    } on StateError {
      return const GateVerdict.allow();
    }
    final mb.ProhibitionCheckResult result;
    try {
      result = await philosophy.checkProhibitions(
        mb.ProhibitionCheckRequest(proposedAction: action, context: context),
      );
    } on StateError {
      return const GateVerdict.allow();
    } on Object catch (e) {
      return GateVerdict.block('philosophy check failed: $e');
    }
    String why(mb.ProhibitionCheck c) => c.violationDetail ?? c.prohibitionId;
    final violated = result.checks.where((c) => c.violated).toList();
    if (result.hasHardViolation) {
      final hard = violated
          .where((c) => c.severity == mb.ProhibitionSeverity.hard)
          .map(why)
          .join('; ');
      return GateVerdict.block('philosophy hard prohibition: $hard');
    }
    final soft = violated.map(why).toList();
    if (soft.isEmpty) return const GateVerdict.allow();
    final confirm = _confirm;
    if (confirm == null) return GateVerdict.allow(soft);
    if (await confirm(action, soft)) return GateVerdict.allow(soft);
    return GateVerdict.block('not approved by the human: ${soft.join('; ')}');
  }
}
