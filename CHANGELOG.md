## 0.1.0 - 2026-05-23 - Initial release

First public release of `brain_kernel`. Headless system kernel that
wraps `mcp_bundle` and `flowbrain_core` with the project / canonical /
patch / validate / build / MCP / chat / RAG pieces every host needs, and
exposes the `BundleActivation` standard API that hosts (AppPlayer Core,
vibe_studio, future hosts) use to manage per-bundle catalog lifecycle.

### Added
- **Core layer** — project, canonical store, patch pipeline, asset
  validator, undo/redo stack, prefs / chat-log / history-log / undo-log
  sidecars.
- **Feature layer** — BM25 index, gold-question runner, asset extractor
  + reviewer queue, asset-touch observer.
- **Infra layer** — bundle reader / knowledge writer / mcpb packager,
  embedding runner, BM25 query engine + bundle registry, domain
  storage, FlowBrain wiring (KvStoragePort adapter, runtime probe, LLM
  port adapter, FlowDefinitionWorkflow), MCP server bootstrap (tool
  scope + transport picker + server bootstrap), agent LLM sessions,
  agent chat controller + system-prompt composer.
- **System layer** — `BundleActivation` + `BundleActivationRegistry`:
  the canonical asset-registration standard. Per-bundle catalog via
  `<bundleId>.<asset.id>` prefixing; idempotent registration; one
  registry handles N concurrent activations.
- **Re-exports** — `flowbrain_core`, `mcp_bundle`, `mcp_server`, and a
  selected slice of `mcp_client` are re-exported so products can stay
  on the kernel as the single MCP surface (FR-CMP-002).

### Dependencies
- `mcp_bundle: ^0.4.0`
- `flowbrain_core: ^0.1.2`
- `mcp_llm: ^2.1.1`
- `mcp_knowledge_ops: ^0.2.1`
- `mcp_server: ^2.0.0`, `mcp_client: ^2.0.0`
