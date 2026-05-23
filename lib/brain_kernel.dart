/// Public barrel for the brain_kernel system kernel
/// (carbon copy of brain_kernel for vibe-side iteration).
///
/// Headless — no UI dependency. Products (builder, industrial, medical,
/// education, B2B, personal) wire kernel pieces together with their own
/// UI and domain workflow. See `docs/00_PRD/PRD.md` for the manifesto.
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
// wiring / MCP server.
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
export 'src/infra/server/server_bootstrap.dart';
// Bundle activation standard (knowledge-operations) — hosts, built-in
// bundles, external bundles, and AppPlayer bundle apps all register
// their assets through the same canonical path.
export 'src/system/bundle_activation.dart';

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

// MCP packages — re-exported so domain hosts (vibe_app_builder /
// vibe_knowledge_builder / future studios) consume the kernel as the
// single MCP surface. Domains do NOT add `mcp_bundle` / `mcp_server` /
// `mcp_llm` to their pubspec — kernel owns the version pin and
// surfaces the types.
//
// `mcp_client` is exported via a `show` list (selective) because its
// model classes (Content / AudioContent / TextContent / TransportConfig
// / etc.) collide pervasively with `mcp_server`'s. Domain code rarely
// needs the full client API — typical use = creating an outbound
// `Client` with one of the standard transports. New types are added to
// the show list on demand.
//
// Conflict policy among the re-exported three:
//   * kernel's own [ValidationIssue] (asset_validator.dart) stays
//     primary → mcp_bundle's [ValidationIssue] / [ValidationError] /
//     [ValidationWarning] / [ValidationSeverity] hidden
//   * `SkillConfig` / `SkillManifest` / `AuthConfig` /
//     `EvaluationException` / `EvaluationContext` / `LlmMessage` /
//     `TransportType` / `ResourceContent` — kernel's downstream
//     surfaces (flowbrain_core / mcp_server) own these; mcp_bundle's
//     versions are hidden
//   * `LlmMessage` / `LoggerExtensions` — flowbrain_core (via
//     mcp_bundle) wins; mcp_llm's hidden
//   * `AuthResult` / `TokenValidator` / `ApiKeyValidator` —
//     mcp_server's wins; mcp_llm's hidden (LLM auth is internal)
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
export 'package:mcp_server/mcp_server.dart';
export 'package:mcp_client/mcp_client.dart'
    show
        Client,
        StdioClientTransport,
        SseClientTransport,
        StreamableHttpClientTransport;
// `mcp_llm` is exported selectively (show list) instead of with a hide
// list because its `mcp_server` adapter re-exports many server-side
// names (CallToolResult / ReadResourceResult / ToolHandler / ...) that
// collide pervasively with our `mcp_server` re-export. The `show` set
// captures the LLM types domain hosts actually consume; new types are
// added here on demand.
export 'package:mcp_llm/mcp_llm.dart'
    show
        LlmClient,
        LlmConfiguration,
        LlmProviderFactory,
        McpLlm,
        ChatSession,
        ClaudeProvider,
        LlmRequest,
        LlmResponse,
        LlmTool,
        LlmToolCall,
        LLmContent,
        LlmMessage;
