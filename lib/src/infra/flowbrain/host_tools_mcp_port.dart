/// The `McpPort` a skill's `tool` steps run through when the host gives the
/// kernel its own tools to call (platform spec 30 §8).
///
/// The kernel's default skill port is a stub that answers every call with a
/// made-up result. This one hands the call to the host — its dispatcher, where
/// the kernel's `bk.*` tools and the host's own capabilities are registered —
/// and answers with what came back: an error the host reports comes back as an
/// error result, and a call that throws is thrown on. It does not reach
/// external servers: those go through `mcp.*` and the client host.
library;

import 'dart:convert';

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../../system/host/kernel_envelope.dart';

/// Calls a host tool by name. Throws when the tool does not exist.
typedef KernelHostToolInvoker = Future<KernelToolResult> Function(
  String name,
  Map<String, dynamic> arguments,
);

class HostToolsMcpPort implements mb.McpPort {
  const HostToolsMcpPort(this._invoke);

  final KernelHostToolInvoker _invoke;

  @override
  Future<mb.ToolResult> callTool(
    String name,
    Map<String, dynamic> arguments, {
    String? serverId,
  }) async {
    final r = await _invoke(name, arguments);
    final text = [
      for (final c in r.content)
        if (c is KernelTextContent) c.text,
    ].join('\n');
    Object? content = text;
    try {
      content = jsonDecode(text);
    } on FormatException {
      // Plain text stays plain text.
    }
    if (r.isError == true) {
      return mb.ToolResult(content: content, isError: true, errorMessage: text);
    }
    return mb.ToolResult.success(content);
  }

  @override
  Future<mb.ResourceContent> readResource(String uri, {String? serverId}) =>
      throw UnsupportedError('a skill reads host resources through a tool');

  @override
  Future<List<mb.ToolInfo>> listTools({String? serverId}) async =>
      const <mb.ToolInfo>[];

  @override
  Future<List<mb.ResourceInfo>> listResources({String? serverId}) async =>
      const <mb.ResourceInfo>[];

  @override
  Stream<mb.ResourceContent>? subscribeResource(String uri, {String? serverId}) =>
      null;

  @override
  Future<mb.PromptTemplate?> getPrompt(
    String name, {
    String? serverId,
    Map<String, dynamic>? arguments,
  }) async =>
      null;

  @override
  Future<bool> isConnected({String? serverId}) async => true;
}
