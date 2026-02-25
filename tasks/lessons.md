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
