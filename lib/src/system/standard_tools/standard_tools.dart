/// MOD-SYS-008 — Standard tool surface.
///
/// In-process tool wrappers over the seven KernelSystem facades
/// (fact / skill / profile / philosophy / ops / agent / knowledge).
/// The wrappers return plain JSON-shaped maps so they can run
/// in-process (host-side dispatcher) or, after envelope wrapping
/// (`wrapInProcess`), be registered onto a [KernelEndpoint]'s server.
///
/// One handler per name (`bk.<facade>.<verb>`). The composed map is
/// keyed by tool name so endpoints register everything in a single
/// loop via [KernelEndpoint.addStandardTools].
///
/// Tool semantics follow the original BrainBridge surface
/// (`os/core/appplayer/dart/lib/src/brain/`) verbatim — the only
/// changes are import paths and the helper-method receiver
/// (`brain.X` → `app.X`).
library;

import 'dart:convert' show jsonEncode;

import '../host/kernel_envelope.dart';
import '../kernel_app.dart';
import 'agent_tools.dart';
import 'fact_tools.dart';
import 'knowledge_tools.dart';
import 'ops_tools.dart';
import 'philosophy_tools.dart';
import 'profile_tools.dart';
import 'skill_tools.dart';

/// In-process tool handler. Returns raw JSON-shaped data — the host
/// wraps it for transport when registering with
/// [KernelEndpoint.addStandardTools] (or via [wrapInProcess]).
typedef InProcessToolHandler = Future<Object?> Function(
  Map<String, dynamic> args,
);

/// Compose the seven facade tool maps into one. The returned map is
/// safe to pass to [KernelEndpoint.addStandardTools] or to consume
/// directly via an in-process dispatcher.
Map<String, InProcessToolHandler> standardTools(KernelApp app) {
  return <String, InProcessToolHandler>{
    ...buildFactTools(app),
    ...buildSkillTools(app),
    ...buildProfileTools(app),
    ...buildPhilosophyTools(app),
    ...buildOpsTools(app),
    ...buildAgentTools(app),
    ...buildKnowledgeTools(app),
  };
}

/// Standard error envelope used by every wrapper.
Map<String, dynamic> stdErr(String message) =>
    <String, dynamic>{'ok': false, 'error': message};

/// Wrap an [InProcessToolHandler] into a [KernelToolHandler]. The
/// raw return value is `jsonEncode`d into one text content; `isError`
/// is set when the result is a Map carrying `ok: false`.
KernelToolHandler wrapInProcess(InProcessToolHandler handler) {
  return (Map<String, dynamic> args) async {
    final result = await handler(args);
    final isError = result is Map && result['ok'] == false;
    return KernelToolResult(
      content: <KernelContent>[
        KernelTextContent(text: jsonEncode(result)),
      ],
      isError: isError,
    );
  };
}
