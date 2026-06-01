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

class HostToolRegistry {
  HostToolRegistry({
    required this.endpoint,
    required this.attachToDispatcher,
    required this.detachFromDispatcher,
  });

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
  String registerExposed({
    required String bundleId,
    required String rawName,
    required String description,
    required KernelToolHandler handler,
    Map<String, dynamic>? inputSchema,
  }) {
    final exposedName = _composeExposedName(bundleId, rawName);
    attachToDispatcher(exposedName, handler);
    endpoint.addTool(
      name: exposedName,
      description: description,
      inputSchema: inputSchema ??
          const <String, dynamic>{
            'type': 'object',
            'additionalProperties': true,
          },
      handler: handler,
    );
    return exposedName;
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
