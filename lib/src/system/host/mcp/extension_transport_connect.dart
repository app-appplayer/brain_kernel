/// `ExtensionTransportConnect` — capability interface for opening an
/// outbound MCP connection over a **host-built transport** injected into
/// the kernel.
///
/// [KernelClientHost.connect] only drives the transports the kernel can
/// build itself (`stdio` / `streamableHttp` / `sse`, all FFI-free). The
/// extension seam described in `specs/platform/08-extension.md` §4 covers
/// the transports whose platform libraries live *outside* the kernel —
/// serial / usb / ble / tcp / ws (via `mcp_bridge`) and the hub relay ws
/// (via `gateway_node`'s `HubConsumerTransport`, spec 15 §8). The host
/// builds the `ClientTransport` and injects it here; the kernel never
/// depends on the transport's platform libraries.
///
/// This is an **additive capability interface**, separate from
/// [KernelClientHost], so hosts can probe it off the abstract client host
/// without holding a concrete impl reference:
///
/// ```dart
/// final ch = kernel.clientHost;            // abstract KernelClientHost?
/// if (ch is ExtensionTransportConnect) {
///   await ch.connectWith(id: sessionId, transport: HubConsumerTransport(consumer));
/// }
/// ```
///
/// The reference impl [McpClientKernelHost] implements it. Client hosts
/// that cannot inject a host-built transport simply do not implement it,
/// and the `is` probe is `false`.
library;

import 'package:mcp_client/mcp_client.dart' show ClientTransport;

import '../kernel_client_host.dart';

/// Injected-transport seam companion to [KernelClientHost].
abstract class ExtensionTransportConnect {
  /// Open a connection over a host-supplied [transport], built outside the
  /// kernel and injected here. The connection is identified by [id] and
  /// lands in the same registry the kernel `mcp.*` tools resolve by `id`,
  /// so `mcp.list_tools` / `mcp.call_tool` / `mcp.read_resource` /
  /// `mcp.disconnect` drive it with no further host wiring.
  Future<KernelClientConnection> connectWith({
    required String id,
    required ClientTransport transport,
  });
}

/// Canonical way to drive the extension-transport seam off a — possibly
/// null, possibly non-capable — [clientHost]. Probes [ExtensionTransportConnect]
/// and injects [transport], or throws a [StateError] if the host cannot.
///
/// Hosts (AppPlayer core, Studio backbone) and the `extension_transport`
/// recipe call this instead of hand-rolling the probe. The explicit cast is
/// required because [ExtensionTransportConnect] is unrelated to the declared
/// `KernelClientHost?`, so an `is` test does not promote the variable — a
/// footgun this helper hides in one place.
Future<KernelClientConnection> connectExtension(
  KernelClientHost? clientHost, {
  required String id,
  required ClientTransport transport,
}) async {
  if (clientHost is! ExtensionTransportConnect) {
    throw StateError(
      'client host does not support injected extension transports '
      '(not an ExtensionTransportConnect; the kernel booted without one, '
      'or with a host that only drives kernel-built transports)',
    );
  }
  return (clientHost as ExtensionTransportConnect)
      .connectWith(id: id, transport: transport);
}
