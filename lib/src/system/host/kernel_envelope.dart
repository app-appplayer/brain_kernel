/// Kernel-side tool / resource envelope types.
///
/// These types let the kernel core (`KernelEndpoint`, the standard
/// tools, `BundleSessionBridge`) describe tool calls and resource
/// reads without referencing any specific MCP wire library. Hosts pick
/// a wire implementation by supplying a [KernelServerHost] /
/// [KernelClientHost] — the reference impl on top of `package:mcp_server`
/// + `package:mcp_client` lives in
/// `package:brain_kernel/mcp_host.dart`. Hosts that want a custom
/// transport (USB, IPC, in-memory bus) implement the abstracts directly
/// without pulling in mcp_server / mcp_client.
library;

/// Result of one tool dispatch. Shape mirrors the MCP `CallToolResult`
/// envelope (content array + optional isError flag) but is library-
/// independent.
class KernelToolResult {
  KernelToolResult({required this.content, this.isError});

  /// Content items returned to the caller. Most calls return a single
  /// [KernelTextContent] carrying the JSON-encoded result; richer
  /// results (images, structured payloads) use additional entries.
  final List<KernelContent> content;

  /// `true` when the tool reported failure. The kernel uses this to
  /// surface in-process errors uniformly across in-process and
  /// transport-bound dispatch paths.
  final bool? isError;
}

/// Sealed base for the kernel content envelope. Hosts add their own
/// concrete subclasses if a transport supports additional content
/// kinds (the reference mcp implementation maps `KernelTextContent` →
/// `mcp.TextContent` and `KernelImageContent` → `mcp.ImageContent`).
sealed class KernelContent {
  const KernelContent();
}

class KernelTextContent extends KernelContent {
  const KernelTextContent({required this.text});
  final String text;
}

class KernelImageContent extends KernelContent {
  const KernelImageContent({required this.data, required this.mimeType});

  /// Base64-encoded image bytes (matching MCP wire format).
  final String data;
  final String mimeType;
}

/// One resource content entry. Matches the MCP `ReadResourceResult`
/// element shape (`uri` + optional `text` or `blob` + `mimeType`).
class KernelResourceContent {
  KernelResourceContent({
    required this.uri,
    this.text,
    this.blob,
    this.mimeType,
  });

  final String uri;
  final String? text;

  /// Base64-encoded bytes when the resource is binary.
  final String? blob;
  final String? mimeType;
}

class KernelReadResourceResult {
  KernelReadResourceResult({required this.contents});
  final List<KernelResourceContent> contents;
}

/// Tool handler signature used by the kernel core.
typedef KernelToolHandler = Future<KernelToolResult> Function(
  Map<String, dynamic> args,
);

/// Resource handler signature used by the kernel core.
typedef KernelResourceHandler = Future<KernelReadResourceResult> Function(
  String uri,
  Map<String, dynamic> params,
);

/// One argument declared on a kernel-side MCP prompt. Mirrors the wire
/// shape (`PromptArgument` in mcp_server) without coupling kernel
/// callers to the wire library.
class KernelPromptArgument {
  const KernelPromptArgument({
    required this.name,
    this.description,
    this.required = false,
  });

  final String name;
  final String? description;
  final bool required;
}

/// One message in the assembled prompt response. `role` matches the
/// MCP role tokens (`'user'` / `'assistant'` / `'system'`); content
/// reuses the kernel [KernelContent] envelope so hosts can return
/// text, images, or future content kinds through the same path the
/// tool surface uses.
class KernelPromptMessage {
  const KernelPromptMessage({
    required this.role,
    required this.content,
  });

  final String role;
  final KernelContent content;
}

/// Result of a `prompts/get` dispatch — the assembled message list
/// the MCP client hands the LLM, plus an optional preamble the host
/// surfaces to the user. Library-independent counterpart of
/// `mcp.GetPromptResult`.
class KernelGetPromptResult {
  const KernelGetPromptResult({
    this.description,
    required this.messages,
  });

  final String? description;
  final List<KernelPromptMessage> messages;
}

/// Prompt handler signature used by the kernel core. Receives the
/// caller-supplied arguments (validated upstream against the prompt's
/// declared [KernelPromptArgument] list) and returns the assembled
/// message list.
typedef KernelPromptHandler = Future<KernelGetPromptResult> Function(
  Map<String, dynamic> args,
);

/// Read-friendly snapshot of one registered prompt. Mirrors
/// [KernelToolDef] / `KernelResourceContent` so hosts can list /
/// introspect the prompt surface without holding the live handler
/// closure.
class KernelPromptDef {
  const KernelPromptDef({
    required this.name,
    required this.description,
    required this.arguments,
  });

  final String name;
  final String description;
  final List<KernelPromptArgument> arguments;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'description': description,
        'arguments': <Map<String, dynamic>>[
          for (final a in arguments)
            <String, dynamic>{
              'name': a.name,
              if (a.description != null) 'description': a.description,
              'required': a.required,
            },
        ],
      };
}

/// Transport family the host can ask a [KernelServerHost] to bind.
/// Hosts that do not implement network transports (in-process only)
/// raise on any value other than [inProcess].
enum KernelTransportKind {
  inProcess,
  stdio,
  streamableHttp,
  sse,
}
