/// Built-in in-process [KernelServerHost] used when no external
/// transport is wired. Hosts that boot the kernel without supplying a
/// `serverHostFactory` get this as the default — every endpoint can
/// register tools, dispatch in-process, and surface tool definitions
/// for observability, but never bind a network transport.
///
/// The reference MCP impl (`McpServerKernelHost` in
/// `package:brain_kernel/mcp_host.dart`) extends this shape with a
/// real `mcp.Server` plus stdio / Streamable HTTP / SSE transports.
library;

import '../../infra/server/tool_scope.dart';
import 'kernel_envelope.dart';
import 'kernel_server_host.dart';
import 'mcp_server_spec.dart';

class InProcessKernelServerHost implements KernelServerHost {
  InProcessKernelServerHost({
    this.name = 'kernel',
    this.version = '0.1.0',
    Set<ToolScope> visibility = const {ToolScope.external},
    bool debugMode = false,
  })  : _visibility = {
          ...visibility,
          if (debugMode) ToolScope.debug,
        },
        _debugMode = debugMode;

  @override
  final String name;

  @override
  final String version;

  final Set<ToolScope> _visibility;
  final bool _debugMode;

  final Map<String, ToolScope> _scopes = <String, ToolScope>{};
  final Map<String, KernelToolDef> _toolDefs = <String, KernelToolDef>{};
  final Map<String, KernelToolHandler> _handlers =
      <String, KernelToolHandler>{};
  final Map<String, _ResourceEntry> _resources = <String, _ResourceEntry>{};
  final Map<String, _PromptEntry> _prompts = <String, _PromptEntry>{};
  final List<Map<String, Object?>> _dispatchLog = <Map<String, Object?>>[];
  static const int _dispatchLogLimit = 200;

  bool _registered = false;

  @override
  Set<ToolScope> get activeVisibility => Set.unmodifiable(_visibility);

  @override
  bool get debugMode => _debugMode;

  @override
  Map<String, ToolScope> get toolScopes => Map.unmodifiable(_scopes);

  @override
  List<KernelToolDef> get toolDefinitions =>
      List<KernelToolDef>.unmodifiable(_toolDefs.values);

  @override
  McpServerSpec? get externalSpec => null;

  @override
  List<Map<String, Object?>> get dispatchLog =>
      List<Map<String, Object?>>.unmodifiable(_dispatchLog);

  @override
  void register() {
    _registered = true;
  }

  bool get isRegistered => _registered;

  @override
  void addTool({
    required String name,
    required String description,
    required Map<String, dynamic> inputSchema,
    required KernelToolHandler handler,
    ToolScope scope = ToolScope.external,
  }) {
    _scopes[name] = scope;
    _toolDefs[name] = KernelToolDef(
      name: name,
      description: description,
      inputSchema: inputSchema,
      scope: scope,
    );
    _handlers[name] = handler;
  }

  @override
  bool removeTool(String name) {
    final hadDef = _toolDefs.remove(name) != null;
    final hadScope = _scopes.remove(name) != null;
    final hadHandler = _handlers.remove(name) != null;
    return hadDef || hadScope || hadHandler;
  }

  @override
  void addResource({
    required String uri,
    required String name,
    required String description,
    required String mimeType,
    required KernelResourceHandler handler,
  }) {
    _resources[uri] = _ResourceEntry(
      uri: uri,
      name: name,
      description: description,
      mimeType: mimeType,
      handler: handler,
    );
  }

  @override
  bool removeResource(String uri) => _resources.remove(uri) != null;

  @override
  List<String> get resourceUris =>
      List<String>.unmodifiable(_resources.keys);

  @override
  void addPrompt({
    required String name,
    required String description,
    required List<KernelPromptArgument> arguments,
    required KernelPromptHandler handler,
  }) {
    _prompts[name] = _PromptEntry(
      def: KernelPromptDef(
        name: name,
        description: description,
        arguments: List<KernelPromptArgument>.unmodifiable(arguments),
      ),
      handler: handler,
    );
  }

  @override
  bool removePrompt(String name) => _prompts.remove(name) != null;

  @override
  List<KernelPromptDef> get promptDefinitions =>
      List<KernelPromptDef>.unmodifiable(_prompts.values.map((e) => e.def));

  @override
  Future<KernelToolResult> callTool(
    String name,
    Map<String, dynamic> args,
  ) async {
    final handler = _handlers[name];
    if (handler == null) {
      return KernelToolResult(
        isError: true,
        content: <KernelContent>[
          KernelTextContent(text: 'Tool not registered: $name'),
        ],
      );
    }
    final start = DateTime.now();
    final sw = Stopwatch()..start();
    KernelToolResult result;
    bool isError = false;
    String? preview;
    try {
      result = await handler(args);
      isError = result.isError ?? false;
      if (result.content.isNotEmpty) {
        final first = result.content.first;
        if (first is KernelTextContent) {
          final t = first.text;
          preview = t.length > 240 ? '${t.substring(0, 240)}…' : t;
        }
      }
    } catch (e) {
      sw.stop();
      _appendLog(<String, Object?>{
        'ts': start.toUtc().toIso8601String(),
        'tool': name,
        'durationMs': sw.elapsedMilliseconds,
        'isError': true,
        'thrown': e.toString(),
        'args': args,
      });
      rethrow;
    }
    sw.stop();
    _appendLog(<String, Object?>{
      'ts': start.toUtc().toIso8601String(),
      'tool': name,
      'durationMs': sw.elapsedMilliseconds,
      'isError': isError,
      'args': args,
      if (preview != null) 'resultPreview': preview,
    });
    return result;
  }

  void _appendLog(Map<String, Object?> entry) {
    _dispatchLog.add(entry);
    while (_dispatchLog.length > _dispatchLogLimit) {
      _dispatchLog.removeAt(0);
    }
  }

  @override
  Future<void> start(
    KernelTransportKind transport, {
    String host = '127.0.0.1',
    int port = 7820,
  }) async {
    if (transport == KernelTransportKind.inProcess) {
      register();
      return;
    }
    throw StateError(
      'InProcessKernelServerHost does not support transport: $transport',
    );
  }

  @override
  Future<void> shutdown() async {
    // In-process host has no transport to tear down.
  }
}

class _PromptEntry {
  _PromptEntry({required this.def, required this.handler});
  final KernelPromptDef def;
  final KernelPromptHandler handler;
}

class _ResourceEntry {
  _ResourceEntry({
    required this.uri,
    required this.name,
    required this.description,
    required this.mimeType,
    required this.handler,
  });

  final String uri;
  final String name;
  final String description;
  final String mimeType;
  final KernelResourceHandler handler;
}
