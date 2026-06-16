/// Public barrel for the brain_kernel system kernel
/// (carbon copy of brain_kernel for vibe-side iteration).
///
/// Headless — no UI dependency. Products (builder, industrial, medical,
/// education, B2B, personal) wire kernel pieces together with their own
/// UI and domain workflow. See `docs/00_PRD/PRD.md` for the manifesto.
///
/// **Library dependency policy** — the kernel itself does NOT depend on
/// `package:mcp_server` / `package:mcp_client` at the type level. It
/// describes tool calls and resource reads through the
/// [KernelServerHost] / [KernelClientHost] envelope (in
/// `lib/src/system/host/`). Hosts that want a `mcp_server` / `mcp_client`
/// backed surface import the reference impls via
/// `package:brain_kernel/mcp_host.dart`. Hosts that drive a custom
/// transport (USB, IPC, in-memory bus) implement the abstracts directly
/// without adding mcp_server / mcp_client to their pubspec.
library;

// CORE — project / canonical / patch / validate / build framework.
// Kernel's `ChatTurn` is the agent-controller turn type (separate from
// `vibe_studio_base.ChatTurn` which is the chat panel UI turn). Domain
// hosts that import both base and kernel should add `hide ChatTurn` on
// the kernel import in those files; kernel tests need the symbol
// available so we keep it exported here.
export 'src/core/types.dart';
export 'src/core/asset_category_map.dart';
export 'src/core/canonical.dart';
export 'src/core/canonical_storage_port.dart';
export 'src/core/undo_redo_stack.dart';
export 'src/core/patch_pipeline.dart';
export 'src/core/asset_validator.dart';
export 'src/core/project.dart';
export 'src/core/sidecar/prefs.dart';
export 'src/core/sidecar/chat_log.dart';
export 'src/core/sidecar/history_log.dart';
export 'src/core/sidecar/undo_log.dart';

// FEAT — proposal queue / asset extractor / BM25 / gold question /
// asset touch observer (auto GUI sync helper).
export 'src/feat/bm_index.dart' show BmConfig, BmHit, BmIndex;
export 'src/feat/gold_question_runner.dart';
export 'src/feat/extractor/reviewer_queue.dart';
export 'src/feat/extractor/asset_extractor.dart';
export 'src/feat/asset_touch_observer.dart';

// INFRA — bundle helpers / embedding / knowledge registry / FlowBrain
// wiring. Server / transport / dispatch surfaces live in `src/system/host/`
// as library-agnostic abstracts (see policy note at the top).
export 'src/infra/converter.dart';
export 'src/infra/bundle/bundle_reader.dart';
export 'src/infra/bundle/knowledge_writer.dart';
export 'src/infra/bundle/mcpb_packager.dart';
export 'src/infra/embed/embedding_provider.dart';
export 'src/infra/embed/embedding_runner.dart';
export 'src/infra/domain_storage/domain_storage.dart';
export 'src/infra/knowledge/bundle_registry.dart';
export 'src/infra/knowledge/query_engine.dart';
export 'src/infra/flowbrain/kv_storage_port_adapter.dart';
export 'src/infra/flowbrain/flowbrain_wiring.dart';
export 'src/infra/flowbrain/flowbrain_runtime_probe.dart';
export 'src/infra/flowbrain/llm_port_adapter.dart';
export 'src/infra/flowbrain/flow_definition_workflow.dart';
export 'src/infra/server/tool_scope.dart';
export 'src/infra/server/transport_picker.dart';
// Bundle activation standard (knowledge-operations) — hosts, built-in
// bundles, external bundles, and AppPlayer bundle apps all register
// their assets through the same canonical path.
export 'src/system/bundle_activation.dart';

// KernelApp — single boot entry point for any FlowBrain app. Owns
// the shared resources (KnowledgeSystem · LLM pool · activation
// registry · BM25 query engine · active context) plus the four
// host-supplied ports. Endpoints (per-domain tool surface + transport)
// attach through `addEndpoint`. The four ports keep the kernel
// host-neutral; `Null*` defaults let hosts opt out of any port they
// do not need (e.g. AppPlayer in-process runs with every port at its
// `Null*` default).
export 'src/system/kernel_app.dart';
export 'src/system/kernel_endpoint.dart';
export 'src/system/ports/config_port.dart';
export 'src/system/ports/ui_resource_port.dart';
export 'src/system/ports/observability_port.dart';
export 'src/system/ports/bundle_source_port.dart';
export 'src/system/standard_tools/standard_tools.dart';

// Host abstracts + envelope types — library-agnostic surface the
// kernel speaks. `KernelServerHost` / `KernelClientHost` are the
// abstracts hosts implement; `KernelToolResult` / `KernelContent` /
// `KernelToolHandler` etc. are the envelope types every tool surface
// goes through. Reference impl on top of `mcp_server` / `mcp_client`
// lives in `package:brain_kernel/mcp_host.dart`.
export 'src/system/host/kernel_envelope.dart';
export 'src/system/host/kernel_server_host.dart';
export 'src/system/host/kernel_client_host.dart';
export 'src/system/host/in_process_server_host.dart';
export 'src/system/host/host_tool_registry.dart';
export 'src/system/host/client_tools.dart';
export 'src/system/host/mcp_server_spec.dart';

// UI ↔ kernel standard wiring layer. Session lifecycle · Zone-scoped
// dispatch · 4 standard channel APIs (callTool · readResource · listResources
// · attach) · `kb://<facade>/<id>` URI scheme. Hosts (vibe_studio ·
// AppPlayer · user host) consume it through the same import.
export 'src/system/bridge/bundle_session_bridge.dart';
export 'src/system/bridge/dispatch_context.dart';
export 'src/system/bridge/dispatch_session.dart';
export 'src/system/bridge/resource_uri.dart';
export 'src/system/bridge/session_registry.dart';

// Chat / LLM — agent-scoped (Phase 2d). Each FlowBrain agent owns its
// own LLM context (system prompt, history, tool surface, model,
// params). A single global ChatSession is forbidden
// (FR-LLM-006 / FR-CHT-006).
export 'src/infra/llm/agent_llm_sessions.dart';
export 'src/infra/chat/agent_chat_controller.dart';
export 'src/infra/chat/system_prompt_composer.dart';

// FlowBrain raw types — re-exported so products consume `brain_kernel` as
// the single surface. KnowledgeSystem · AgentRole · ModelSpec · AgentFacade
// · 5 facades · LlmPort · KnowledgePorts · InfraPorts · OpsRuntime · etc.
// Products do not depend on `flowbrain_core` directly (FR-CMP-002).
//
// LLM message types are hidden here so `mcp_llm`'s versions win at the
// barrel — vibe_llm adapters call `LlmRequest(history:, parameters:,
// withSystemInstruction:)` against mcp_llm's API, not mcp_bundle's
// thinner port DTO.
export 'package:flowbrain_core/flowbrain_core.dart'
    hide LlmRequest, LlmResponse, LlmMessage, LlmTool, LlmToolCall;

// `mcp_bundle` — bundle schema + LlmPort + 50+ ports. The kernel is
// the single MCP surface for domain hosts; they do not add
// `mcp_bundle` to their pubspec.
//
// Conflict policy among the re-exported packages:
//   * kernel's own [ValidationIssue] (asset_validator.dart) stays
//     primary → mcp_bundle's [ValidationIssue] / [ValidationError] /
//     [ValidationWarning] / [ValidationSeverity] hidden
//   * `SkillConfig` / `SkillManifest` / `AuthConfig` /
//     `EvaluationException` / `EvaluationContext` / `LlmMessage` /
//     `TransportType` / `ResourceContent` — kernel's downstream
//     surfaces (flowbrain_core) own these; mcp_bundle's hidden
//   * `LlmMessage` / `LoggerExtensions` — flowbrain_core (via
//     mcp_bundle) wins; mcp_llm's hidden
//   * `LlmPortAdapter` — kernel's flowbrain adapter wins; mcp_llm's
//     internal adapter hidden
export 'package:mcp_bundle/mcp_bundle.dart'
    hide
        ValidationIssue,
        ValidationError,
        ValidationWarning,
        ValidationSeverity,
        SkillConfig,
        SkillManifest,
        AuthConfig,
        EvaluationException,
        EvaluationContext,
        LlmMessage,
        LlmRequest,
        LlmResponse,
        LlmTool,
        LlmToolCall,
        TransportType,
        ResourceContent;
// `mcp_llm` is exported selectively (show list) so its server-side
// adapter re-exports (CallToolResult / ReadResourceResult / ToolHandler
// / ...) don't leak collisions into domain code. The `show` set
// captures the LLM types domain hosts actually consume; new types are
// added here on demand.
export 'package:mcp_llm/mcp_llm.dart'
    show
        LlmClient,
        LlmConfiguration,
        LlmProvider,
        LlmProviderFactory,
        McpLlm,
        ChatSession,
        ClaudeProvider,
        CustomLlmProvider,
        CustomLlmProviderFactory,
        LlmRequest,
        LlmResponse,
        LlmTool,
        LlmToolCall,
        LLmContent,
        LlmMessage,
        ProviderOptions;
