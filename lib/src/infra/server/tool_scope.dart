/// Tool visibility scope — drives which subsets of registered tools are
/// actually exposed on the MCP transport at `start` time. Hosts decide
/// the visibility set per launch (production / dev / debug runs).
///
/// FR-SRV-006 — defined in SRS §2.6.
library;

enum ToolScope {
  /// Internal-only — used by the host UI / wiring. Never exposed on
  /// any MCP transport. Example: `_inspect_agent_state` that opens an
  /// agent's private memory dump for the local debugger pane.
  internal,

  /// Default. Exposed on every transport — external clients (Claude
  /// Desktop, AppPlayer, other MCP hosts) can call these. Project /
  /// canonical / build / chat ops live here.
  external,

  /// Surfaced only when the host launches with `debugMode: true`.
  /// Builder-self diagnostics — token usage histograms, prompt
  /// transcripts, queue depths, last-N raw LLM responses, etc. Hosts
  /// and trusted external LLMs share these for in-loop debugging
  /// without polluting the production tool surface.
  debug,
}
