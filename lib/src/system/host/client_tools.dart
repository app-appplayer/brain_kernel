/// `mcp.*` — the mcp_client capability as host tools.
///
/// The kernel already owns the outbound MCP client surface
/// ([KernelClientHost] / `McpClientKernelHost`), so exposing it as tools
/// adds no new dependency — this is why the client capability is
/// kernel-provided rather than a recipe (domain capability packages such
/// as browser / form / ingest stay in recipes because they *would* drag
/// dependencies into the kernel).
///
/// These tools do **not** pre-connect to a chosen server. The host
/// registers the `mcp.*` surface once (only meaningful when it booted
/// with a [KernelClientHost]); the app / bundle then drives it —
/// connecting to whatever server it chooses, calling a remote tool, or
/// reading a remote resource (e.g. a dashboard UI document). The host is
/// the conduit, not the owner of the connection.
///
/// Shape mirrors [standardTools]: handlers are [InProcessToolHandler]
/// (raw JSON-shaped maps) so the **same source** feeds both register
/// paths — a host's in-process dispatcher consumes them directly
/// (AppPlayer's `ToolDispatcher`, as it does for `bk.*`), and the
/// external endpoint path wraps them with [wrapInProcess]
/// ([registerClientTools]). It is an IO capability, **not** a knowledge
/// facade — never registered through `addStandardTools` (`bk.*`). It is
/// also opt-in: a host that never wires a [KernelClientHost] never
/// registers these tools.
library;

import 'dart:convert' show jsonDecode;

import '../standard_tools/standard_tools.dart'
    show InProcessToolHandler, wrapInProcess;
import 'host_tool_registry.dart';
import 'kernel_client_host.dart';
import 'kernel_envelope.dart';

/// Capability namespace — exposed names are `mcp.connect`, `mcp.call_tool`, …
const String mcpCapabilityId = 'mcp';

/// One `mcp.*` tool: bare [verb], schema, and a raw handler.
class _ClientTool {
  const _ClientTool({
    required this.verb,
    required this.description,
    required this.inputSchema,
    required this.handler,
  });

  final String verb;
  final String description;
  final Map<String, dynamic> inputSchema;
  final InProcessToolHandler handler;
}

/// The mcp_client capability handlers keyed by full name (`mcp.connect`,
/// …), as [InProcessToolHandler] — the shape a host registers straight
/// into its in-process dispatcher, exactly as it does for [standardTools].
Map<String, InProcessToolHandler> clientTools(KernelClientHost host) {
  return <String, InProcessToolHandler>{
    for (final tool in _buildClientTools(host))
      '$mcpCapabilityId.${tool.verb}': tool.handler,
  };
}

/// Register the mcp_client capability onto [registry] under `mcp.*` for
/// the external endpoint path (wraps each handler with [wrapInProcess]).
/// Returns the exposed names. Hosts that only use an in-process
/// dispatcher register [clientTools] directly instead.
List<String> registerClientTools(
  HostToolRegistry registry,
  KernelClientHost host,
) {
  final exposed = <String>[];
  for (final tool in _buildClientTools(host)) {
    exposed.add(
      registry.registerExposed(
        bundleId: mcpCapabilityId,
        rawName: tool.verb,
        description: tool.description,
        inputSchema: tool.inputSchema,
        handler: wrapInProcess(tool.handler),
      ),
    );
  }
  return exposed;
}

List<_ClientTool> _buildClientTools(KernelClientHost host) {
  KernelClientConnection conn(Object? id) {
    final wanted = _requireString(id, 'id');
    for (final connection in host.connections) {
      if (connection.id == wanted) return connection;
    }
    throw _ToolFailure('mcp.not_connected', 'no connection: $wanted');
  }

  return <_ClientTool>[
    _ClientTool(
      verb: 'connect',
      description: 'Connect (through the host) to an external MCP server '
          'the app chooses. Returns the connection id for later calls.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'id': <String, dynamic>{'type': 'string'},
          'transport': <String, dynamic>{
            'type': 'string',
            'enum': <String>['stdio', 'streamableHttp', 'sse'],
          },
          'endpoint': <String, dynamic>{'type': 'string'},
          'options': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['id', 'transport'],
      },
      handler: _guard((args) async {
        final connection = await host.connect(
          id: _requireString(args['id'], 'id'),
          transport: _transport(args['transport']),
          endpoint: args['endpoint'] as String?,
          options: (args['options'] as Map?)?.cast<String, dynamic>(),
        );
        return <String, dynamic>{
          'ok': true,
          'id': connection.id,
          'connected': connection.isConnected,
        };
      }),
    ),
    _ClientTool(
      verb: 'list_tools',
      description: 'List the tools the connected server advertises.',
      inputSchema: _idOnlySchema,
      handler: _guard((args) async {
        final tools = await conn(args['id']).listTools();
        return <String, dynamic>{
          'ok': true,
          'tools': tools
              .map((t) => <String, dynamic>{
                    'name': t.name,
                    'description': t.description,
                    'inputSchema': t.inputSchema,
                  })
              .toList(),
        };
      }),
    ),
    _ClientTool(
      verb: 'call_tool',
      description: 'Invoke a tool on the connected server.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'id': <String, dynamic>{'type': 'string'},
          'tool': <String, dynamic>{'type': 'string'},
          'args': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['id', 'tool'],
      },
      handler: _guard((args) async {
        final result = await conn(args['id']).callTool(
          _requireString(args['tool'], 'tool'),
          (args['args'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        );
        return <String, dynamic>{
          'ok': !(result.isError ?? false),
          'isError': result.isError ?? false,
          'content': _content(result.content),
        };
      }),
    ),
    _ClientTool(
      verb: 'read_resource',
      description: 'Read a resource from the connected server — e.g. a '
          'dashboard UI document the app then renders.',
      inputSchema: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'id': <String, dynamic>{'type': 'string'},
          'uri': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['id', 'uri'],
      },
      handler: _guard((args) async {
        final read = await conn(args['id']).readResource(
          _requireString(args['uri'], 'uri'),
        );
        return <String, dynamic>{
          'ok': true,
          'contents': read.contents
              .map((c) => <String, dynamic>{
                    'uri': c.uri,
                    'text': c.text,
                    'blob': c.blob,
                    'mimeType': c.mimeType,
                  })
              .toList(),
        };
      }),
    ),
    _ClientTool(
      verb: 'list_resources',
      description: 'List the resources the connected server exposes.',
      inputSchema: _idOnlySchema,
      handler: _guard((args) async {
        final resources = await conn(args['id']).listResources();
        return <String, dynamic>{
          'ok': true,
          'resources': resources
              .map((r) => <String, dynamic>{
                    'uri': r.uri,
                    'name': r.name,
                    'description': r.description,
                    'mimeType': r.mimeType,
                  })
              .toList(),
        };
      }),
    ),
    _ClientTool(
      verb: 'disconnect',
      description: 'Close a connection the app opened.',
      inputSchema: _idOnlySchema,
      handler: _guard((args) async {
        await conn(args['id']).close();
        return <String, dynamic>{'ok': true};
      }),
    ),
  ];
}

const Map<String, dynamic> _idOnlySchema = <String, dynamic>{
  'type': 'object',
  'properties': <String, dynamic>{
    'id': <String, dynamic>{'type': 'string'},
  },
  'required': <String>['id'],
};

/// Internal — signals a handled tool failure with a stable code.
class _ToolFailure implements Exception {
  _ToolFailure(this.code, this.message);
  final String code;
  final String message;
}

/// Wrap a raw body so no exception escapes the tool boundary — the
/// kernel's uniform tool convention (`ops_tools` returns an `{ok:false}`
/// map on failure). A [_ToolFailure] keeps its code.
InProcessToolHandler _guard(
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) body,
) {
  return (Map<String, dynamic> args) async {
    try {
      return await body(args);
    } on _ToolFailure catch (e) {
      return <String, dynamic>{
        'ok': false,
        'code': e.code,
        'error': e.message,
      };
    } catch (e) {
      return <String, dynamic>{
        'ok': false,
        'code': 'mcp.error',
        'error': e.toString(),
      };
    }
  };
}

String _requireString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw _ToolFailure('mcp.bad_input', '$field (string) required');
  }
  return value;
}

KernelTransportKind _transport(Object? value) {
  switch (value) {
    case 'stdio':
      return KernelTransportKind.stdio;
    case 'sse':
      return KernelTransportKind.sse;
    case 'http':
    case 'streamableHttp':
    case 'streamable_http':
      return KernelTransportKind.streamableHttp;
    default:
      throw _ToolFailure(
        'mcp.bad_transport',
        'transport must be stdio | streamableHttp | sse',
      );
  }
}

List<dynamic> _content(List<KernelContent> content) {
  return content.map<dynamic>((item) {
    if (item is KernelTextContent) {
      try {
        return jsonDecode(item.text);
      } catch (_) {
        return item.text;
      }
    }
    return item.toString();
  }).toList();
}
