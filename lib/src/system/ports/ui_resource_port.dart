/// MOD-SYSTEM-005 — UiResourcePort.
///
/// Host-supplied UI resource server. Surfaces text / template / asset
/// resources to MCP clients (Claude Desktop, web inspectors) so the
/// bundle's `ui/` payload becomes serveable. Hosts that ship without a
/// UI surface use [NullUiResource.instance].
library;

class UiResourceEvent {
  const UiResourceEvent({required this.kind, required this.path});

  /// One of `'mounted'` · `'changed'` · `'unmounted'`.
  final String kind;
  final String path;
}

abstract class UiResourcePort {
  Future<List<String>> list();
  Future<String> read(String path);
  Future<void> register(String path, String content);
  Stream<UiResourceEvent> events();
}

/// No-op [UiResourcePort] for hosts without a UI resource surface.
class NullUiResource implements UiResourcePort {
  const NullUiResource._();
  static const NullUiResource instance = NullUiResource._();

  @override
  Future<List<String>> list() async => const <String>[];

  @override
  Future<String> read(String path) async {
    throw StateError('NullUiResource: no resource registered at "$path"');
  }

  @override
  Future<void> register(String path, String content) async {
    // No-op.
  }

  @override
  Stream<UiResourceEvent> events() => const Stream<UiResourceEvent>.empty();
}
