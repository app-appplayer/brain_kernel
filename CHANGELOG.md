## 0.1.3 - 2026-06-23 - FlowBrain orchestration tools (route/review) + destructive-action gate (spec 12 §5·§6)

### Added
- **§5** — `bk.agent.route` + `bk.agent.review` standard tools (agent_tools: 11 → 13) — expose the AgentFacade's manager-routing + reviewer-verdict as MCP tools so workflows / agents can drive rule-based agent→agent handoff (spec `platform/12-flowbrain-runtime.md` §5). `route{managerId, request, candidateAgentIds?}` → `{targetAgentId, confidence, reason}`; `review{reviewerId, targetAgentId, content}` → `{verdict, severity, comments}`. standardTools map: 45 → 47.
- **§6** — `HostToolRegistry` destructive-action gate: `registerExposed(destructive: true)` + optional `confirmDestructive` host callback (ctor). Destructive tools (git push / mail / settlement / external publish) are gated through the callback before running — **blocked when the human declines or no callback is wired (deny-by-default)** (spec §6). `destructive` defaults false → existing tools unaffected. The confirm UI is host-supplied (core has no UI). 209 PASS.

### Fixed
- **`bk.philosophy.put` accepts a raw Ethos and never silently drops the body.** Previously `put` called `EthosRecord.fromJson(input)` directly, so an author / LLM passing a raw Ethos (no `payload` envelope key) stored `payload: {}` — the body was lost and every later `getEthos` / `intervene` / `checkProhibitions` operated on an empty ethos (or crashed in `Ethos.fromJson`). `put` now detects the shape: an envelope (`payload` present) is stored as before; a raw Ethos is wrapped into an `EthosRecord` with `payload: <ethos>`, `id`/`name`/`version` derived from the ethos (version from `metadata.version`). The body is validated via `Ethos.fromJson` before storage, returning a clear `invalid ethos: <field-named message>` (mcp_bundle 0.4.4) instead of storing garbage. Integration test: `test/system/philosophy_authoring_test.dart` (raw round-trip preserves body · envelope back-compat · malformed → clear error) over a real `KvEthosStoreAdapter`. 212 PASS.

### Changed (dependency floor)
- `flowbrain_core` `^0.1.4` → `^0.1.5` — track the latest published cascade release (flowbrain_core 0.1.5 wires spec 12 §2·§3·§3b·§4·§4b). The kernel's §5 route/review tools wrap the existing `AgentFacade.route`/`review` (present since 0.1.x), so this is an internal-latest constraint bump, not a symbol requirement.
- `mcp_bundle` `^0.4.1` → `^0.4.4` — the `bk.philosophy.put` fix above relies on the Ethos graph `fromJson` throwing field-named `FormatException`s (mcp_bundle 0.4.4) for the clear-error guarantee; floored to **guarantee** it.

### Backward compatibility
- Fully additive. No existing `HostToolRegistry`, `BundleActivation`, `standardTools`, or host-abstract surface changed. Tools registered without `destructive: true` and hosts that don't pass `confirmDestructive` see no behavior change.

## 0.1.2 - 2026-06-10 - Extension transport seam + clientTools export (additive)

### Added
- `McpClientKernelHost.connectWith({id, transport})` — new public method on the
  reference `KernelClientHost` implementation. Accepts a host-supplied
  `mcp_client.ClientTransport` (e.g. `TcpClientTransport` or
  `WebSocketClientTransport` from `mcp_bridge`) and opens a
  `KernelClientConnection` over it. The kernel itself carries no FFI or
  platform dependency for the transport — the calling host owns those by
  design (`specs/platform/08-extension.md` §4 injection seam). The abstract
  `KernelClientHost` is unchanged.
- `clientTools` function exported from the main barrel
  (`lib/brain_kernel.dart`). Returns the `bk.mcp.*` in-process tool map so
  hosts (e.g. `appplayer_core`) can register it alongside `standardTools`
  without reaching into `src/`.

### Backward compatibility
- Fully additive. No existing `KernelApp`, `BundleActivation`, `standardTools`,
  or host-abstract surface changed. Hosts that do not use extension transports
  see no behavior change.

---

## 0.1.1 - 2026-06-01 - Behavior definition engine bridge + MCP serving (additive)

### Added
- `bk.philosophy.check` standard tool — wraps `PhilosophyFacade.checkProhibitions`, evaluating a proposed `action` / `output` against active ethos and returning `{hasHardViolation, violations}`. The read-side of `bk.philosophy.*` (the existing put/get/activate go to the ethos store); lets a behavior step gate on `hasHardViolation`.
- `BundleActivation.registerBehavior(BehaviorDefinition)` — maps a bundle's `behavior.definitions[]` entry to an `OpsRuntime.behaviorRegistry` factory. Called automatically inside the `activate` loop when `bundle.behavior` is present; result carries `result.behaviors` count and `registeredBehaviors` list. `ownsBehavior(id)` predicate and teardown unregistration included. The action dispatcher surfaces a step's tool/skill output into run state — a tool's JSON result (or a skill's `Map` result) is merged so a later step's `when` guard can read its keys (e.g. gate on `hasHardViolation` from `bk.philosophy.check`).
- `bk.behavior.run`, `bk.behavior.resume`, and `bk.behavior.list` standard tools registered in `ops_tools.dart`, under the `bk.behavior.*` namespace alongside `bk.workflow.*` / `bk.pipeline.*` / `bk.runbook.*`. Execution routes through the ops facade (`app.system.ops.runBehavior` / `resumeBehavior` / `listBehaviors`, added in mcp_knowledge 0.2.4) — the same layer the workflow/runbook tools use — so the kernel and tools layer hold no direct `mcp_knowledge_ops` dependency for behavior execution. `bk.behavior.resume` accepts an optional `statePatch` (e.g. `{"approved": true}`) merged into the run state before re-evaluation, so an approval unblocks a waiting guard.
- `BundleActivation` optional `behaviorStore` field (`StateStore?`) — injected durable store for suspend/resume across restarts; defaults to per-behavior `EphemeralStateStore` when absent.
- **MCP serving** (`specs/mcp_serving` 1.0) — `KernelEndpoint.activate` exposes the activated bundle as the well-known `bundle://manifest.json` resource (the bundle document: manifest metadata + sections) so a remote AppPlayer-class client can `resources/read` it, reconstruct the `McpBundle`, and run it identically to a local bundle. `KernelServerHost` gains a `resourceUris` introspection getter (parity with `toolDefinitions` / `promptDefinitions`), implemented by `InProcessKernelServerHost` and `ServerBootstrap`.
- New regression tests included in the system test suite.

### Changed (dependency floors)
The kernel uses symbols introduced in this round's lower releases, so the constraint floors are raised to **guarantee** them, not merely resolve to them (the prior `^0.2.1`-style floors were satisfiable by versions lacking the symbols):
- `mcp_bundle` `^0.4.0` → `^0.4.1` — `BehaviorSection` / `BehaviorDefinition` (`bundle.behavior`) consumed by `BundleActivation`.
- `mcp_knowledge_ops` `^0.2.1` → `^0.2.2` — `BehaviorEngine` / `BehaviorRunnable` / `StateStore` / `OpsRuntime.behaviorRegistry` constructed by `BundleActivation`.
- `flowbrain_core` `^0.1.2` → `^0.1.3` — its re-exported `OpsFacade` must carry `runBehavior` / `resumeBehavior` / `listBehaviors` (flowbrain_core 0.1.3 raises its own `mcp_knowledge` floor to `^0.2.4`).

### Backward compatibility
- Fully additive. No existing `BundleActivation`, `KernelApp`, or tool API changed. Hosts that do not set `bundle.behavior` see no behavior change.

---

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
