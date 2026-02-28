# Lessons

## 2026-02-24 - OpenClaw Gateway Auth Failures
- Symptom: repeated `device token mismatch` while loopback gateway is reachable.
- Root cause pattern: launch-agent credential can drift stale versus local device-auth/paired sources.
- Rule: for loopback gateway auth, prioritize local device-auth sources before launch-agent token and instrument candidate-level fallback diagnostics.

## 2026-02-24 - Startup Auto-Connect Mismatch Noise
- Symptom: every launch prints deterministic provider endpoint mismatch errors for local OpenClaw placeholder URLs.
- Root cause pattern: misconfigured entries stay `autoConnect=true`, so startup keeps attempting and logging failures.
- Rule: when startup detects deterministic misconfigured OpenClaw-local endpoint failures, auto-disable provider `autoConnect` and emit a clear diagnostic event.

## 2026-02-24 - Transient Auth Failure Toast Noise
- Symptom: user sees `OpenClaw failed` auth toasts even when loopback credential recovery reconnects successfully moments later.
- Root cause pattern: connection layer emits immediate `.failed(auth...)` before manager-side fallback auth candidates complete.
- Rule: defer auth-failure toasts behind a short grace window, cancel on successful/recovery states, and dedupe repeated auth failure variants so users only see persistent failures.

## 2026-02-24 - OpenClaw Chat Delta Semantics
- Symptom: streamed assistant text duplicates prefixes (`HelloHello...`) in Work mode.
- Root cause pattern: OpenClaw `chat` events can deliver snapshot-style text in `state: "delta"` payloads, while consumers may assume append-only incremental deltas.
- Rule: normalize snapshot text to incremental deltas before appending/rendering, and keep regression tests for repeated/equal snapshots.

## 2026-02-24 - Cross-Repo Integration Path Validation
- Symptom: initial investigation started from one subtree while the OpenClaw counterpart lived in a sibling repo path.
- Root cause pattern: integration debugging began before confirming the exact repository/component boundaries.
- Rule: for OpenClaw-Osaurus wiring issues, verify both canonical paths (`Jarvis/osaurus` and `Jarvis/openclaw`) before tracing event pipelines.

## 2026-02-24 - Kimi Coding Provider Canonical Source of Truth
- Symptom: Osaurus kept using a legacy Kimi Coding endpoint, causing persistent 401s despite valid Kimi Code keys.
- Root cause pattern: endpoint/provider assumptions were reimplemented in Osaurus instead of syncing with OpenClaw's canonical provider catalog/runtime.
- Rule: for provider-specific behavior (base URL, API compatibility, model IDs), validate against OpenClaw provider definitions first, then add compatibility migration for legacy configs rather than introducing parallel endpoint assumptions.

## 2026-02-25 - Work Chat Staleness From Count-Only Event Wiring
- Symptom: Work chat pane appeared frozen or never showed final assistant text while sidebar progress kept updating.
- Root cause pattern: UI sync was keyed on `activityStore.items.count`, but many assistant updates mutate existing items without changing count.
- Rule: subscribe chat sync to `activityStore.$items` (full publisher), not only `.count` changes, whenever timeline items are updated in-place.

## 2026-02-25 - OpenClaw Trace Leakage Into User Response
- Symptom: user-facing assistant output included OpenClaw internal `System:` task execution traces.
- Root cause pattern: Work-mode stream path forwarded raw deltas without robust boundary filtering for trace sections.
- Rule: always filter `System:` trace boundaries (including chunk-split and start-of-stream variants) before rendering assistant content; keep dedicated regression tests.

## 2026-02-25 - Prefer Native Thread Rendering Over Ticker-Only Streaming
- Symptom: Work responses looked low-fidelity (less markdown/interactivity) when streaming content was hidden from the main thread in favor of ticker text.
- Root cause pattern: replacing live assistant blocks with a ticker bypassed Osaurus’ richer message rendering surface.
- Rule: keep live assistant/thinking blocks in the main thread whenever available; use ticker only as fallback when no assistant paragraph content exists yet.

## 2026-02-25 - Chat/OpenClaw Control Blocks Must Be Parsed In Both Live And History Paths
- Symptom: Chat UI rendered raw protocol payloads such as `---COMPLETE_TASK_START---` JSON and sometimes ended without a polished final answer.
- Root cause pattern: only Work-mode execution parsed OpenClaw completion/control blocks; Chat-mode stream processor and history loader treated them as plain assistant text.
- Rule: apply the same OpenClaw output formatter to both live event streaming and history hydration, and promote completion `artifact`/`summary` into user-visible markdown when control blocks contain final output.

## 2026-02-26 - Swift 6 Concurrent Closure Capture Hygiene
- Symptom: Swift compiler errors for `Reference to captured var ... in concurrently-executing code` and actor-isolated property reads inside `Task` telemetry closures.
- Root cause pattern: loop-mutable vars (`pollAttempt`, `recoveryAttempt`) and main-actor state (`isConnected`) were read directly inside concurrently executing closures.
- Rule: before spawning concurrent closures, snapshot mutable/actor-isolated values into immutable locals and capture only those snapshots.

## 2026-02-26 - Insights Must Distinguish SDK vs Network Spans
- Symptom: Insights/trace dashboards were dominated by HTTP/network spans, while SDK MLX/agent/tool traces were hard to isolate.
- Root cause pattern: manual SDK spans were not explicitly tagged as non-auto/network in app-level telemetry attributes.
- Rule: stamp SDK-created spans with explicit origin metadata (`terra.auto_instrumented=false`, `osaurus.trace.origin=sdk`, surface tag) so dashboards can filter SDK spans independently from network effects.

## 2026-02-27 - Trace Tree Stability Requires Stable IDs + External Expansion State
- Symptom: tool/trace tree collapsed or appeared to reset when new trace updates arrived; rows looked like they disappeared/reappeared.
- Root cause pattern: dynamic block IDs changed as tool-call arrays grew, and parent expansion state lived in local `@State` that remounted on row identity churn.
- Rule: for streaming/collapsible trees, keep item IDs stable across incremental updates and persist expansion state in shared store keyed by stable IDs (not view-local state).

## 2026-02-27 - Avoid Auto-Switching Trace Panels By Active Run
- Symptom: while inspecting one trace/span timeline, the panel jumped to another run when new background traces arrived.
- Root cause pattern: display projection keyed to `activeRunId` causes context switches whenever a different run starts.
- Rule: for inspection UIs, default to stable chronological projection (or explicit user-selected focus), not implicit active-run switching.

## 2026-02-28 - Work Greeting Duplication Needs Input + Output Dedupe
- Symptom: saying `hello` in Work mode produced duplicated greeting intent (`hello hello`) and repeated assistant paragraphs.
- Root cause pattern: OpenClaw streams may encode cumulative snapshots in `delta` fields, and Work gateway prompt assembly can repeat the same query across issue/context sections.
- Rule: treat snapshots as authoritative for stream normalization (including delta-only cumulative fallback), and dedupe semantically identical issue/context prompt segments before sending to the gateway.

## 2026-02-27 - Telemetry Producer Changes Require Consumer Compatibility Checks
- Symptom: producer-side span fixes introduced new attributes, but viewer classification/rendering still reflected legacy behavior (`chat` labeling and missing thinking panel).
- Root cause pattern: instrumentation updates were validated in Osaurus without immediately validating TerraViewer parsing/classification keys.
- Rule: for telemetry schema changes, patch and verify both producer (Osaurus) and primary consumer (TerraViewer) in the same change window, including tests for new attribute keys.
