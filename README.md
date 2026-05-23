# brain_kernel

Headless system kernel for knowledge-grounded multi-agent systems.

`brain_kernel` bundles project / canonical / patch / validate / build /
MCP / chat / RAG over [`mcp_bundle`](https://pub.dev/packages/mcp_bundle)
and [`flowbrain_core`](https://pub.dev/packages/flowbrain_core), and
exposes them as a single Dart library that products (builders, industrial
HMIs, medical / education tools, B2B platforms, personal apps) can wire
into their own UI and domain workflow without writing the integration
plumbing themselves.

## What's inside

- **Core** — project / canonical / patch pipeline / asset validator /
  undo-redo stack / sidecar logs (prefs, chat, history, undo).
- **Feature** — BM25 index, gold-question runner, asset extractor +
  reviewer queue, asset-touch observer.
- **Infra** — bundle reader / knowledge writer / mcpb packager,
  embedding runner, BM25 query engine + bundle registry, domain
  storage, FlowBrain wiring (KvStoragePort adapter, runtime probe,
  LLM port adapter, FlowDefinitionWorkflow), MCP server bootstrap
  (tool scope + transport picker), LLM session manager, chat
  controller + system-prompt composer.
- **System** — `BundleActivation` + `BundleActivationRegistry`: the
  single standard API every host (vibe_studio · AppPlayer · future
  hosts) uses to activate a bundle, register its assets, and tear it
  down. Per-bundle isolation via `<bundleId>.<asset.id>` prefixing.

## Quick start

```dart
import 'package:brain_kernel/brain_kernel.dart' as bk;

// Boot the kernel.
final wiring = bk.FlowBrainWiring(
  workspaceId: 'my_workspace',
  kvStoragePort: bk.InMemoryKvStoragePort(),
);
await wiring.boot();

// Activate a bundle.
final activation = bk.BundleActivation(
  system: wiring.system,
  bundleId: 'my.bundle',
);
await activation.activate(myBundle); // McpBundle
```

Hosts (AppPlayer Core, vibe_studio, ...) drive this lifecycle from their
own session-management code. See
[`knowledge-operations.md`](https://github.com/app-appplayer/makemind/blob/main/tools/builder/vibe_studio/docs/knowledge-operations.md)
for the full host-integration manual.

## Re-exports

The barrel re-exports the upstream packages so consumers can stay on a
single MCP surface (per `FR-CMP-002`):

- `flowbrain_core` — `KnowledgeSystem`, the five facades, the agent
  runtime types, infrastructure ports.
- `mcp_bundle` — bundle schema, validators, ports.
- `mcp_server` — MCP server primitives.
- `mcp_client` — selected client types (`Client`, transport configs).

Products do not need to depend on these packages directly; depending on
`brain_kernel` is enough.

## Status

`brain_kernel` is the canonical kernel for the MakeMind ecosystem and
the foundation that AppPlayer Core, vibe_studio, and the FlowBrain
products build on. The API surface is stable enough for early adopters
but still evolves with the upstream `mcp_bundle` / `flowbrain_core`
spec — pin caret versions.

## License

MIT
