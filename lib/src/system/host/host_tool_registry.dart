/// `HostToolRegistry` — convenience layer that registers a general
/// (non-knowledge) tool onto both the host's in-process dispatcher and
/// the external [KernelServerHost] endpoint in one call, prefixing the
/// tool name with `<bundleId>.<rawName>` so two bundles can declare
/// the same raw name (`editor.open` etc.) without collision.
///
/// Two responsibilities are intentionally kept apart from
/// [BundleSessionBridge]:
///
/// - **`BundleSessionBridge.registerTool`** = knowledge tool wrapping
///   only. Canonical `bk.<facade>.<verb>` registration, scopeId
///   auto-application, and per-session `bk.<bundleId>.<rest>` alias
///   publication. The bridge knows about FlowBrain knowledge facets;
///   general tools have no business going through it.
///
/// - **`HostToolRegistry.registerExposed`** = general tool wiring.
///   Single name (`<bundleId>.<rawName>`) on both the dispatcher and
///   the endpoint. No aliasing, no scopeId, no FlowBrain coupling.
///   Hosts (vibe_studio's `HostBundleActivation`, AppPlayer's tool
///   loader, headless tests) call this once per `ToolEntry` in a
///   bundle's `manifest.tools.tools[]`.
///
/// Both bundles supplying their own `editor.open` end up with distinct
/// exposed names (`recipe_a.editor.open` / `recipe_b.editor.open`) on
/// the same endpoint without any further work from the host.
library;

import 'dart:convert';

import 'kernel_envelope.dart';
import 'kernel_server_host.dart';

/// Callback the host supplies so the registry can attach / detach a
/// handler to its own in-process dispatcher (AppPlayer's
/// `ToolDispatcher`, vibe_studio's runtime tool executor, a headless
/// in-memory map, etc.). The registry itself owns no dispatcher state.
typedef DispatcherAttach = void Function(
  String exposedName,
  KernelToolHandler handler,
);

typedef DispatcherDetach = void Function(String exposedName);

/// Host-supplied human-confirm gate for destructive (irreversible) tools
/// — git push, mail, settlement, external publish, etc. (spec
/// `platform/12-flowbrain-runtime.md` §6). Returns true to allow the call,
/// false to block. The core has no UI; the host decides how to obtain
/// approval. A tool registered `destructive: true` with no callback wired is
/// blocked (deny-by-default).
typedef ConfirmDestructive = Future<bool> Function(
  String toolName,
  Map<String, dynamic> args,
);

class HostToolRegistry {
  HostToolRegistry({
    required this.endpoint,
    required this.attachToDispatcher,
    required this.detachFromDispatcher,
    this.confirmDestructive,
  });

  /// Optional human-confirm gate for tools registered `destructive: true`
  /// (§6). When null, destructive tools are blocked (deny-by-default).
  final ConfirmDestructive? confirmDestructive;

  /// Endpoint that receives the same handler (mirrored for external
  /// transports `tools/list` + `tools/call`).
  final KernelServerHost endpoint;

  /// Host-supplied dispatcher attach callback — runs once per
  /// `registerExposed`. The registry passes the already-prefixed
  /// exposed name and the handler; the host stores them in whatever
  /// in-process map its scripts hit on dispatch.
  final DispatcherAttach attachToDispatcher;

  /// Pair of [attachToDispatcher] — the host removes the same key on
  /// `unregisterExposed`.
  final DispatcherDetach detachFromDispatcher;

  /// Register a general tool — dispatcher + endpoint in one call,
  /// prefixed with `<bundleId>.<rawName>` so two bundles can share
  /// the same raw name without colliding.
  ///
  /// `description` and `inputSchema` flow straight through to the
  /// endpoint so external clients can introspect the same metadata
  /// the bundle declared. Idempotent — re-registering the same
  /// `(bundleId, rawName)` pair replaces the prior handler.
  /// [destructive] marks an irreversible tool (git push / mail / settlement
  /// / external publish). Such tools are gated through [confirmDestructive]
  /// before running — blocked when the human declines or no callback is
  /// wired (§6). Default false (existing tools unaffected).
  String registerExposed({
    required String bundleId,
    required String rawName,
    required String description,
    required KernelToolHandler handler,
    Map<String, dynamic>? inputSchema,
    bool destructive = false,
  }) {
    final exposedName = _composeExposedName(bundleId, rawName);
    final effectiveHandler =
        destructive ? _guardDestructive(exposedName, handler) : handler;
    attachToDispatcher(exposedName, effectiveHandler);
    endpoint.addTool(
      name: exposedName,
      description: description,
      inputSchema: inputSchema ??
          const <String, dynamic>{
            'type': 'object',
            'additionalProperties': true,
          },
      handler: effectiveHandler,
    );
    return exposedName;
  }

  /// Wrap a destructive tool's handler so it requires human confirmation
  /// before running. Blocked (not run) when [confirmDestructive] is null
  /// (deny-by-default) or the human declines (§6).
  KernelToolHandler _guardDestructive(
      String toolName, KernelToolHandler handler) {
    return (args) async {
      final confirm = confirmDestructive;
      final approved = confirm != null && await confirm(toolName, args);
      if (!approved) {
        return KernelToolResult(
          content: [
            KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'destructive_action_blocked',
                'tool': toolName,
                'message': confirm == null
                    ? 'destructive tool requires a human-confirm callback (none wired)'
                    : 'destructive action was not approved by the human',
              }),
            ),
          ],
          isError: true,
        );
      }
      return handler(args);
    };
  }

  /// Remove a previously registered tool from both layers.
  /// Returns the `(<bundleId>.<rawName>)` exposed name that was
  /// removed, or `null` when no entry existed.
  String? unregisterExposed({
    required String bundleId,
    required String rawName,
  }) {
    final exposedName = _composeExposedName(bundleId, rawName);
    detachFromDispatcher(exposedName);
    final removed = endpoint.removeTool(exposedName);
    return removed ? exposedName : null;
  }

  /// Compose the exposed name. Kept as a single helper so tests can
  /// assert on the format and so future tweaks (e.g. namespace
  /// separators) land in one place.
  static String _composeExposedName(String bundleId, String rawName) =>
      '$bundleId.$rawName';
}
