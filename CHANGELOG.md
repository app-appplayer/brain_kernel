## 0.1.7 - 2026-07-12 - ExtensionTransportConnect seam capability (additive)

### Added
- **`ExtensionTransportConnect` capability interface + `connectExtension` helper** (`package:brain_kernel/mcp_host.dart`). Codifies the extension-transport injection seam standard (`specs/platform/08-extension.md` §4 "Standard 3 Layers"). The seam `connectWith({ id, transport })` — how a host opens an outbound MCP connection over a transport it built itself (serial / usb / ble / tcp / ws via `mcp_bridge`, or the hub relay ws via `gateway_node`'s `HubConsumerTransport`; `15-hub-channel.md` §8) — previously lived only on the concrete `McpClientKernelHost`. The abstract `KernelClientHost` (the type `KernelApp.clientHost` exposes) surfaces only `connect({ transport: KernelTransportKind })` for the kernel-buildable stdio / Streamable HTTP / SSE transports, so a host had to hold a concrete client-host reference to reach the seam. `McpClientKernelHost` now also `implements ExtensionTransportConnect`, and hosts reach the seam off the abstract client host via the canonical helper `connectExtension(clientHost, { id, transport })` — it probes `ExtensionTransportConnect`, does the explicit cast (the interface is unrelated to `KernelClientHost?`, so `is` does not promote the variable — a footgun sealed in one place), injects, or throws a `StateError`. Both exported from the `mcp_host.dart` sub-barrel (they reference `mcp_client`'s `ClientTransport`, so they stay out of the library-agnostic main barrel). `KernelClientHost` itself is unchanged (cascade 0). Test: `client_tools_test.dart` (probe off the abstract type; non-capable / null host throws). The host-facing surface (the `mcp.connect_extension` tool) lives in the `recipes/extension_transport/` recipe, not the kernel (it carries an mcp_bridge FFI dependency). 227 PASS.

### Backward compatibility
- Fully additive. `KernelClientHost` is **unchanged** — existing implementers are untouched (no new abstract member to satisfy). The new capability is a separate interface a client host opts into. Floors unchanged.

## 0.1.6 - 2026-07-02 - bk.philosophy provenance discipline + bk.agent.update

### Added
- **`bk.agent.update` standard tool (48 tools).** In-place mutation of a persistent agent — `agentId` plus any of `displayName` / `role` / `model` / `systemPrompt` / `tags`. Closes the CRUD asymmetry in the `bk.agent.*` surface (create/delete existed, update did not), so changing an agent's orchestration role or model through the kernel tool surface no longer requires delete→recreate — which destroys the individual's owned axis forks and history, contradicting the persistent-roster principle. An unknown `role` value is rejected (not silently defaulted). Requires `flowbrain_core ^0.1.7` (the `role`-accepting update seam) — floor bumped. Test: `standard_tools_test.dart` (in-place promote persists · untouched fields kept · unknown role rejected). 223 PASS.
- **`bk.philosophy.put` / `bk.philosophy.activate` enforce a provenance lifecycle.** An ethos payload may now carry an optional `provenance` block — `payload['provenance'] = { 'kind': 'anchor'|'derived'|'workaround', 'serves': <principle id>, 'validWhile': <condition> }`. A `derived` or `workaround` ethos is a transient judgment, not an original principle: it must declare the principle it `serves`, and it is forced **inactive** on `put` — it becomes the active principle only through an explicit `activate` (the confirm step), mirroring the fact candidate→confirm lifecycle. This keeps a derived judgment from silently being stored or activated as if it were a defining principle. Rides the existing `EthosStorePort` contract (payload preserved as-is) — **no core type change** in `mcp_bundle`. Tests: `philosophy_authoring_test.dart` (anchor unconstrained · derived-without-serves rejected · derived forced inactive + provenance round-trip · workaround confirmed via activate). 222 PASS.

### Backward compatibility
- Fully additive. `kind` defaults to `anchor` when absent, so pre-existing ethos records and the stock seed (which carry no `provenance`) are unconstrained and behave exactly as before. Floors unchanged.

## 0.1.5 - 2026-06-30 - KvStoragePortAdapter.keys(prefix:) string-prefix contract fix

### Fixed
- **`KvStoragePortAdapter.keys(prefix:)` violated the string-prefix contract.** It treated `prefix` as a directory path (`<rootDir>/<prefix>/`), so flat colon-namespaced keys (e.g. `philosophy.ethos:<id>`, stored as a single `<key>.json` file) were never listed: `keys(prefix: 'philosophy.ethos:')` returned `[]` even though `get`/`set` worked and `keys()` (no prefix) listed them. This surfaced as `bk.philosophy.list` returning an empty array while `put`/`get` succeeded. The method now walks the full store, reconstructs each key, and filters by `key.startsWith(prefix)` — matching the in-memory reference `KvStoragePort`. Hierarchical slash-namespaced prefixes (e.g. `ws/A/`) still match (keys use `/` separators) and partial-segment prefixes now match correctly too. Regression tests added (`kv_storage_port_adapter_test.dart`). 218 PASS.

## 0.1.4 - 2026-06-24 - BundleActivation tool-dispatch via injected callTool closure (additive)

### Added
- **`BundleActivation` optional `callTool` closure** — an alternative to a full `KernelServerHost boot` for wiring flow / behavior tool-action dispatch. A host whose endpoint is a registry (e.g. a `BuiltinToolRegistry` that exposes `callTool` without ever surfacing a raw `KernelServerHost`) can now inject just the dispatch closure: `BundleActivation(system: ..., bundleId: ..., callTool: server.callTool)`. `registerBehavior` / `registerFlow` route tool steps through `callTool ?? boot?.callTool`. Mirrors the skill-executor `callTool` binding pattern already used across hosts. Tests: `bundle_activation_behavior_test.dart` (closure dispatch with `boot == null` · unwired-throws). 214 PASS.

### Fixed
- **Registry-host topologies could not dispatch tool-action behavior / flow steps.** When a host endpoint is a `BuiltinToolRegistry` (not a raw `KernelServerHost`), `boot` is necessarily null and there was no other way to supply dispatch, so **every** `kind: tool` behavior / flow step threw `tool dispatch not wired (<ref>)` at run time (the live-registered philosophy-gate path was latently affected too). The `callTool` seam closes that gap; the same diagnostic now fires only when neither `callTool` nor `boot` is provided.

### Backward compatibility
- Fully additive. The `boot` path and the `tool dispatch not wired` diagnostic are unchanged. `BundleActivation` callers that don't pass `callTool` see no behavior change.

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
