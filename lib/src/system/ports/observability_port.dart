/// MOD-SYSTEM-006 — ObservabilityPort.
///
/// Host-supplied telemetry sink. Records semantic events
/// (`event`), LLM token cost (`cost`), and arbitrary metrics
/// (`metric`). Hosts without observability use
/// [NullObservability.instance].
library;

class ObservabilityRecord {
  ObservabilityRecord({
    required this.kind,
    required this.data,
    required this.ts,
  });

  /// One of `'event'` · `'cost'` · `'metric'`.
  final String kind;
  final Map<String, dynamic> data;
  final DateTime ts;
}

abstract class ObservabilityPort {
  void event(String name, {Map<String, dynamic>? payload});
  void cost({
    required String model,
    required int tokensIn,
    required int tokensOut,
  });
  void metric(String name, num value, {Map<String, String>? tags});
  Stream<ObservabilityRecord> stream();
}

/// No-op [ObservabilityPort] for hosts without telemetry.
class NullObservability implements ObservabilityPort {
  const NullObservability._();
  static const NullObservability instance = NullObservability._();

  @override
  void event(String name, {Map<String, dynamic>? payload}) {
    // No-op.
  }

  @override
  void cost({
    required String model,
    required int tokensIn,
    required int tokensOut,
  }) {
    // No-op.
  }

  @override
  void metric(String name, num value, {Map<String, String>? tags}) {
    // No-op.
  }

  @override
  Stream<ObservabilityRecord> stream() =>
      const Stream<ObservabilityRecord>.empty();
}
