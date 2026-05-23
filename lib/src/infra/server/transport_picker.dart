/// Pick which MCP transport to bind based on user override or stdin
/// attachment heuristics (DDD-20 §3).
library;

import 'dart:io';

/// Transport family the server should bind to.
enum TransportType {
  /// Used when the host (e.g. Claude Desktop) spawned the process and
  /// is communicating over stdin / stdout.
  stdio,

  /// Modern Streamable HTTP transport for browsers / inspectors.
  streamableHttp,

  /// Legacy SSE transport.
  sse,
}

/// Resolution rules:
/// 1. `userOverride` (e.g. `--transport stdio`) wins.
/// 2. If stdin is attached without a terminal — the host launched us —
///    pick stdio so messages flow on the inherited file descriptors.
/// 3. Otherwise default to streamableHttp (a developer running the
///    binary by hand wants a network endpoint, not stdio).
TransportType pickTransport({
  TransportType? userOverride,
  Stdin? stdin,
}) {
  if (userOverride != null) return userOverride;
  final s = stdin ?? io_stdin;
  // `hasTerminal` throws on web; on a host-spawned process it returns
  // false because stdin is a pipe.
  try {
    if (!s.hasTerminal) return TransportType.stdio;
  } catch (_) {
    // Fall through to default.
  }
  return TransportType.streamableHttp;
}

/// Indirection so tests can inject their own [Stdin]. The default value
/// resolves to the real `dart:io` stdin at lookup time, not at import
/// time.
Stdin get io_stdin => stdin;
