/// `KernelServerHost` — abstract MCP server surface used by the kernel.
///
/// The kernel core (`KernelEndpoint`, the standard tools, the bundle
/// bridge) talks to this abstract instead of `package:mcp_server`
/// directly. Hosts pick a wire library by supplying an implementation:
///
/// - Default impl `McpServerKernelHost` (in
///   `package:brain_kernel/mcp_host.dart`) wraps `mcp.Server` +
///   stdio / Streamable HTTP / SSE transports.
/// - In-process-only hosts (AppPlayer's client-default mode, headless
///   probes, tests) supply an [InProcessKernelServerHost] or skip the
///   server factory entirely.
/// - Custom transports (USB, IPC, in-memory bus) implement the
///   abstract directly without pulling in `mcp_server`.
library;

import '../../infra/server/tool_scope.dart';
import 'kernel_envelope.dart';
import 'mcp_server_spec.dart';

/// Tool definition retained by a [KernelServerHost] so external
/// transports can answer `tools/list`. Mirrors mcp_server's tool meta
/// without depending on the wire library.
class KernelToolDef {
  const KernelToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.scope,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final ToolScope scope;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'scope': scope.name,
      };
}

abstract class KernelServerHost {
  /// Caller-supplied server identity surfaced on `initialize`.
  String get name;
  String get version;

  /// Visibility filter the host launches with. Tools outside the
  /// filter stay tracked (for introspection) but never reach the
  /// transport.
  Set<ToolScope> get activeVisibility;
  bool get debugMode;

  /// Register a tool. Idempotent re-registration replaces the handler.
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required KernelToolHandler handler,
    ToolScope scope = ToolScope.external,
  });

  /// Remove a previously registered tool. Returns true when an entry
  /// was removed.
  bool removeTool(String name);

  /// Register an MCP-style resource. The handler returns
  /// [KernelReadResourceResult]; the host translates to its wire shape.
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    required KernelResourceHandler handler,
  });

  /// Remove a previously registered resource. Returns true when an
  /// entry was removed (the call is idempotent on missing URIs).
  bool removeResource(String uri);

  /// Read-only snapshot of every registered resource URI (parity with
  /// [toolDefinitions] / [promptDefinitions]). Used by hosts and tests to
  /// confirm what the server exposes — e.g. the MCP Serving bundle document
  /// at `bundle://manifest.json`.
  List<String> get resourceUris;

  /// Register an MCP prompt. The handler returns a
  /// [KernelGetPromptResult] (description + list of messages); the
  /// host translates to the wire shape (`mcp.GetPromptResult` for the
  /// reference impl, host-specific for custom transports).
  ///
  /// Mirrors the [addTool] / [addResource] surface so builtin /
  /// bundle-app callers stay on the kernel envelope and never need
  /// `package:mcp_server` directly — the "OS api vs app" boundary
  /// `vibe_studio/builtin_api.dart` enforces.
  void addPrompt({
    required String name,
    required String description,
    required List<KernelPromptArgument> arguments,
    required KernelPromptHandler handler,
  });

  /// Remove a previously registered prompt. Returns true when an
  /// entry was removed (the call is idempotent on missing names).
  bool removePrompt(String name);

  /// Read-only snapshot of every registered prompt definition.
  List<KernelPromptDef> get promptDefinitions;

  /// Read-only snapshot of registered tool scopes.
  Map<String, ToolScope> get toolScopes;

  /// Read-only snapshot of every registered tool definition.
  List<KernelToolDef> get toolDefinitions;

  /// In-process tool dispatch. Used by [BundleActivation] flows whose
  /// `toolDispatcher` closure routes through the host's local server
  /// surface, by `BundleSessionBridge` mirroring, and by host code
  /// that wants to invoke a tool without going over the transport.
  Future<KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  );

  /// Bind a transport. Implementations that only support in-process
  /// dispatch may ignore the call or raise.
  Future<void> start(
    KernelTransportKind transport, {
    String host = '127.0.0.1',
    int port = 7820,
  });

  /// Mark the server as registered without binding a transport. The
  /// in-process AppPlayer use case where no network surface is exposed.
  void register();

  /// Tear the transport down.
  Future<void> shutdown();

  /// Read-only snapshot of recent dispatches (kernel observability
  /// surface; reference impl caps the buffer at ~200 entries).
  List<Map<String, Object?>> get dispatchLog;

  /// External dial-back description for this host. Returns `null` for
  /// in-process implementations that never expose a wire transport.
  /// Transport-binding implementations override this once `start()`
  /// has wired a concrete URL / port / command pair so consumers
  /// (Claude Code's `--mcp-config`, sibling hosts, debug tooling) can
  /// reach the server without re-encoding wire details. See
  /// `host/mcp_server_spec.dart`.
  McpServerSpec? get externalSpec => null;
}
