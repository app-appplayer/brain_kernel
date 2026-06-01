/// MOD-SYSTEM-004 — ConfigPort.
///
/// Host-supplied configuration source. The kernel does not interpret
/// the configuration shape — it is plain JSON-like data produced by
/// whatever loader the host chose (YAML / TOML / JSON / in-memory).
/// Hosts that do not surface configuration use [NullConfig.instance].
library;

abstract class ConfigPort {
  /// Current configuration snapshot.
  Future<Map<String, dynamic>> load();

  /// Hot-reload stream. Emits a fresh snapshot each time the underlying
  /// source changes. Hosts without hot-reload return `Stream.empty()`.
  Stream<Map<String, dynamic>> watch();

  /// Apply a partial change. Hosts without runtime patching throw
  /// [UnsupportedError] or no-op (host's choice).
  Future<void> patch(Map<String, dynamic> diff);
}

/// No-op [ConfigPort] for hosts that do not surface configuration.
class NullConfig implements ConfigPort {
  const NullConfig._();
  static const NullConfig instance = NullConfig._();

  @override
  Future<Map<String, dynamic>> load() async => const <String, dynamic>{};

  @override
  Stream<Map<String, dynamic>> watch() =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<void> patch(Map<String, dynamic> diff) async {
    // No-op.
  }
}
