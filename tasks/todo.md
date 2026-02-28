# Plan

## Current Task: MLX/Qwen Trace Pipeline Fix (2026-02-27)
- [x] Confirm plan before code changes

### Implementation
- [x] Remove duplicate MLX inference trace emission on ChatEngine-driven flows
- [x] Preserve/propagate tool call IDs so tool execution spans correlate with inference/tool invocation traces
- [x] Eliminate duplicate tool execution span wrappers in Work execution path
- [x] Add explicit inference mode/channel telemetry attributes for source-aware classification
- [x] Separate `<think>` reasoning content from final output in telemetry attributes (while preserving streamed output behavior)

### Verification
- [x] Add/update focused tests for thinking split and tool call ID propagation paths
- [x] Run targeted OsaurusCore tests for touched areas

### Review
- [x] Root causes fixed and validated by tests
- [x] Trace behavior manually reasoned against reported symptoms (duplication, classification, tree linkage, thinking/output split)
- Focused tests passed:
  - `swift test --package-path Packages/OsaurusCore --filter ChatEngineTests` (9/9)
  - `swift test --package-path Packages/OsaurusCore --filter ThinkingTagSplitterTests` (4/4)
  - `swift test --package-path Packages/OsaurusCore --filter TraceTreeStabilityTests` (2/2)
  - `swift test --package-path Packages/OsaurusCore --filter WorkExecutionEngineOpenClawTests` (7/7)
- TerraViewer support audit completed; viewer upgraded to parse/render new Osaurus fields (`osaurus.inference.mode`, `osaurus.inference.channel`, `osaurus.response.thinking`, `osaurus.thinking.length`) with new coverage in `InsightsTraceAnalysisTests` and `TraceTelemetryFocusTests`.

## Current Task: Deep Logging + Startup/Provider Stabilization
- [x] Confirm this execution plan before code changes

### Phase 1: Deep Logging Instrumentation (diagnostics-first)
- [x] Add a structured diagnostics logger for startup/provider/work-db flows with per-launch correlation ID (`startupRunId`)
- [x] Emit JSON diagnostics events for:
  - [x] OpenClaw gateway start/poll/connect lifecycle (endpoint, status code, retry count, elapsed ms)
  - [x] MCP provider connect/test lifecycle (provider id/name/url, transport mode, failure class)
  - [x] Remote provider connect/test lifecycle (provider id/name/base URL, models URL, response content-type, decode class)
  - [x] Work database open/close and `notOpen` call-site context
- [x] Persist diagnostics to a stable file under app support (in addition to existing OpenClaw CLI diagnostics)
- [x] Add redaction policy for tokens/secrets and response-body preview truncation

### Phase 2: Repro Harness and Evidence Collection
- [x] Build a reproducible startup capture flow that bundles:
  - [x] Osaurus app logs for a single launch session
  - [x] OpenClaw diagnostics (`~/Library/Logs/OpenClaw/diagnostics.jsonl`)
  - [x] OpenClaw launch agent log (`OpenClawLaunchAgent.logPath()`)
  - [x] Effective provider configs (`providers/remote.json`, `providers/mcp.json`) with secret fields redacted
- [x] Add a one-command debug script in `scripts/openclaw/` to gather and timestamp all artifacts
- [ ] Run two reproducible scenarios:
  - [ ] clean startup with OpenClaw enabled
  - [ ] startup with intentionally misconfigured provider endpoints (to validate classifier quality)

### Phase 3: Functional Fixes (root-cause remediation)
- [x] Fix Work DB initialization race causing `[ChatWindowState] Failed to refresh work tasks: notOpen`
  - [x] Ensure DB is opened before `IssueStore.listTasks` is reachable from `ChatWindowState.refreshWorkTasks()`
  - [x] Add idempotent guard so open is safe from multiple call paths
- [x] Harden Remote Provider model discovery error handling
  - [x] Detect non-JSON responses (HTML starting with `<`) and return actionable error with endpoint hint
  - [x] Include response content-type/status/body-prefix in diagnostics
  - [x] Add OpenClaw-specific hint when endpoint appears to target gateway UI/control routes instead of model API
- [x] Harden MCP Provider connection validation
  - [x] Classify `method not allowed` as endpoint/protocol mismatch with explicit remediation text
  - [x] Add URL sanity checks for known bad OpenClaw routes when configured as MCP provider
- [x] Refine startup auto-connect orchestration to reduce noisy failure loops
  - [x] Keep provider auto-connect after gateway start, but gate retries and add bounded backoff
  - [x] Prevent duplicate/ambiguous teardown logs when startup cancellation happens

### Phase 4: UX and Operational Guardrails
- [x] Surface normalized provider health states in UI (`misconfigured endpoint`, `auth failed`, `gateway unavailable`, `network unreachable`)
- [x] Add “Fix-it” guidance directly in provider cards and OpenClaw dashboard when mismatch is detected
- [x] Add doc updates for correct OpenClaw integration path (`mcporter` bridge for MCP tools, OpenClaw manager for gateway)

### Phase 5: Verification and Release Gates
- [x] Add/extend tests:
  - [x] `RemoteProviderService` decode-classification tests for HTML/non-JSON responses
  - [x] `MCPProviderManager` connection error classification tests for method-not-allowed responses
  - [x] Work DB initialization tests covering early `listTasks` access from chat/window paths
  - [x] Startup orchestration tests for gateway-first + provider auto-connect sequencing
- [x] Run targeted test suite:
  - [x] `swift test --filter OpenClawManagerTests`
  - [x] `swift test --filter OpenClawGatewayConnection`
  - [x] `swift test --filter OpenClawLaunchAgentTests`
  - [x] `swift test --filter MCPHTTPHandlerTests`
  - [x] `swift test --filter OpenClawLogViewerTests`
- [ ] Run production smoke checks with real launch and validate no recurring startup errors

## Collaboration Inputs Needed (from you)
- [x] Provide one full startup artifact bundle from the new debug script
- [ ] Confirm whether `OpenClaw MCP` and `OpenClaw` provider entries are intentional custom endpoints or legacy/misconfigured entries
- [ ] Share expected behavior for local-only vs custom-remote OpenClaw usage so we can set strict validation rules without false positives

## Review
- [x] Root cause(s) confirmed with diagnostics evidence, not assumptions
- [ ] Fixes validated by tests + live startup run
- [x] Logs are cleaner, errors are actionable, and no regressions observed

### Evidence Snapshot
- Startup artifact bundle generated: `/tmp/osaurus-startup-artifacts/startup-20260224T042110Z`
- Startup diagnostics file captured: `~/Library/Application Support/com.dinoki.osaurus/runtime/startup-diagnostics.jsonl`
- Full package verification passed: `swift test` (276 tests, 49 suites)
- Targeted suite from this plan passed (`OpenClawManagerTests`, `OpenClawGatewayConnection`, `OpenClawLaunchAgentTests`, `MCPHTTPHandlerTests`, `OpenClawLogViewerTests`)

## Task: OpenClaw token resync test coverage
- [x] Confirm plan before research
- [x] Search OsaurusCore tests for OpenClaw auth failure/device token mismatch coverage
- [x] Review gateway connect/auth code to understand automatic token resync/retry behavior needs
- [x] Propose minimal OsaurusCore tests covering token resync/retry on local gateway connect failure
- [x] Document findings in this file's review section

### Review

## Current Task: SDK vs Network Trace Distinction (2026-02-26)
- [x] Confirm plan before patching

### Implementation
- [x] Mark MLX inference spans as SDK-origin telemetry (`terra.auto_instrumented=false`, `osaurus.trace.origin=sdk`)
- [x] Mark Work agent spans as SDK-origin telemetry (same attributes for loop + OpenClaw gateway runs)
- [x] Mark tool execution spans as SDK-origin telemetry (to separate from HTTP/network auto spans)

### Verification
- [x] Run `swift build --package-path Packages/OsaurusCore`
- [x] Confirm changed files compile with no new errors
- [x] Run focused tests for touched paths (`ModelRuntimeMappingTests`, `MCPHTTPHandlerTests`)

### Review
- SDK spans now include explicit origin metadata for Insights filtering:
  - `terra.auto_instrumented=false`
  - `osaurus.trace.origin=sdk`
  - `osaurus.trace.surface` set to `model_runtime`, `work_loop`, `work_openclaw_gateway`, or `tool_registry`
- Build verification succeeded: `swift build --package-path Packages/OsaurusCore`.
- Focused tests passed:
  - `swift test --package-path Packages/OsaurusCore --filter ModelRuntimeMappingTests`
  - `swift test --package-path Packages/OsaurusCore --filter MCPHTTPHandlerTests`
- Note: `swift test --package-path Packages/OsaurusCore --filter WorkExecutionEngineOpenClawTests` failed with existing `requestObserved` expectations in this environment; no logic changes were made to request execution flow in this patch.

## Current Task: OpenClaw Auth Mismatch Recovery
- [x] Confirm plan for auth mismatch analysis before code suggestions

### Step 1: Investigate OpenClaw auth/token resolution
- [x] Read `OpenClawManager.swift` (and helpers) to map token sources and connection flow
- [x] Identify how local ws://127.0.0.1:18789/ws connection loads credentials

### Step 2: Diagnose mismatch cycle
- [x] Trace where device token gets refreshed/reconfigured and note conflicting priorities
- [x] Spot helper paths (e.g., stored tokens, credential sources) contributing to loops

### Step 3: Propose minimal fixes and tests
- [x] Sketch targeted code adjustments, linking to file/line for OpenClawManager connect and token resolution
- [x] Outline tests (unit/behavior) to cover new priority/order or failure handling
- [x] Update plan file with review section after recommendations

## Current Task: OpenClaw Auth Mismatch Hotfix (2026-02-24)
- [x] Confirm remediation plan before code changes

### Implementation
- [x] Add local gateway token hydration helper and reuse it in `connect()` and sync-token flow
- [x] Add bounded local auth-recovery retry path for token mismatch/unauthorized failures
- [x] Keep custom endpoint auth behavior unchanged

### Verification
- [x] Add/extend unit tests for auth-recovery classification/retry gating
- [x] Run targeted tests (`swift test --filter localAuthRecoveryPredicate_requiresLoopbackAndNoCustomEndpoint`, `swift test --filter localAuthRecoveryPredicate_ignoresNonAuthFailures`, `swift test --filter OpenClawGatewayConnectionReconnectionTests`)

### Review (Hotfix)
- [x] Root cause confirmed against artifacts
- [x] Fix validated by tests
- [x] Follow-up operational guidance captured

#### Hotfix Evidence
- Root-cause artifacts show repeated `unauthorized: device token mismatch (rotate/reissue device token)` for `ws://127.0.0.1:18789` while valid token probes succeed immediately after (`.claude/plans/artifacts/openclaw-production/e2e/gateway-probe-20260224T035715Z.json`, `.../health-valid-token-20260224T040205Z.json`).
- Manager now hydrates local loopback token sources before connect and performs one bounded local auth recovery retry with SDK device-token reset.
- New tests passed: `localAuthRecoveryPredicate_requiresLoopbackAndNoCustomEndpoint`, `localAuthRecoveryPredicate_ignoresNonAuthFailures`.
- Regression suite passed: `swift test --filter OpenClawGatewayConnectionReconnectionTests` (7 tests).

## Task: Provider UI gating investigation
- [x] Confirm plan before research
- [ ] Trace WorkEmptyStateLogic routing to determine why authenticated users rerun provider setup/ui despite existing configs
- [ ] Inspect OpenClaw provider config decoding (`config.get`/`configGetFull`) to ensure persisted API keys are surfaced during Work mode boot
- [ ] Capture evidence (files, functions, condition checks) explaining why Work mode keeps hitting provider setup/loading, including affected lines for minimal patch suggestions

## Current Task: Gateway Connection Deep Diagnostics (2026-02-24)
- [x] Confirm plan before instrumentation changes

### Implementation
- [x] Add low-level gateway diagnostics in `OpenClawGatewayConnection` for:
  - [x] connect begin/success/failure with mapped error kind
  - [x] preflight health check begin/success/failure (+ HTTP status)
  - [x] websocket connect begin/success/failure
  - [x] disconnect disposition classification and reconnect decisioning
  - [x] reconnect loop attempts/rate-limit/auth-stop outcomes
  - [x] request-level failure diagnostics after retries are exhausted
- [x] Expand `OpenClawManager` connect/reconnect diagnostics with credential source selection + credential availability flags (without exposing secrets)
- [x] Add a helper script to inspect gateway diagnostics quickly: `scripts/openclaw/inspect_gateway_diagnostics.sh`

### Verification
- [x] `swift test --filter localAuthRecoveryPredicate_requiresLoopbackAndNoCustomEndpoint`
- [x] `swift test --filter localAuthRecoveryPredicate_ignoresNonAuthFailures`
- [x] `swift test --filter OpenClawGatewayConnectionReconnectionTests`

### Review
- [x] Diagnostics now identify the exact failing stage (`manager credential resolution`, `gateway preflight`, `websocket handshake`, `disconnect classification`, `reconnect policy`) instead of only a top-level auth error string.
- [x] Added log-inspection workflow for immediate triage against `startup-diagnostics.jsonl`.

## Current Task: Gateway Auth Source Mismatch Fix (2026-02-24)
- [x] Confirm root cause from diagnostics before patching

### Implementation
- [x] Add credential-candidate resolver with dedup and deterministic source ordering
- [x] For loopback/local auth, prioritize: device-auth file -> paired registry -> legacy config -> launch-agent token
- [x] Keep launch-agent token as fallback only (instead of primary)
- [x] Expand auth recovery retry to iterate alternate local credential candidates with per-candidate diagnostics
- [x] Keep reconnect path aligned with updated credential resolution

### Verification
- [x] `swift test --filter gatewayCredentialSourceOrder_prefersLocalDeviceSourcesForLoopback`
- [x] `swift test --filter gatewayCredentialSourceOrder_dedupesDuplicateTokenValues`
- [x] `swift test --filter localAuthRecoveryPredicate_requiresLoopbackAndNoCustomEndpoint`
- [x] `swift test --filter OpenClawGatewayConnectionReconnectionTests`

### Review
- [x] Root cause validated from live token probes: launch-agent token fails explicit WS probe with `device token mismatch`; device-auth, paired, and legacy tokens succeed.
- [x] Source ordering now avoids selecting stale launch-agent credentials first on loopback.
- [x] Recovery diagnostics now show candidate count/order and per-candidate attempt/failure/success to pinpoint fallback behavior.

## Current Task: Startup Provider Noise Suppression (2026-02-24)
- [x] Confirm post-fix startup logs and identify remaining failures

### Implementation
- [x] Harden startup auto-connect retry classification by inferring health state from thrown errors when runtime state is still unknown
- [x] Add startup URL sanity precheck to skip clearly invalid OpenClaw-local provider endpoints before connect attempts
- [x] Auto-disable `autoConnect` for startup failures classified as misconfigured OpenClaw-local endpoints (Remote + MCP managers)
- [x] Extend OpenClaw MCP endpoint sanity matching to include `/mcp` route
- [x] Emit explicit diagnostics when auto-connect is disabled (`remote.autoconnect.disabled`, `mcp.autoconnect.disabled`)

### Verification
- [x] `swift test --filter ProviderAutoConnectStartupTests`
- [x] `swift test --filter MCPProviderManagerClassificationTests`
- [x] `swift test --filter RemoteProviderServiceClassificationTests`

### Review
- [x] Startup now disables repeat-failing OpenClaw-local provider entries after first deterministic endpoint-mismatch failure.
- [x] Existing transient-failure retry behavior remains unchanged.

## Current Task: Transient Auth-Failure Toast Suppression (2026-02-24)
- [x] Confirm remaining symptom from logs: auth failure toast appears before loopback credential recovery succeeds

### Implementation
- [x] Add deferred auth-failure toast scheduling in `OpenClawManager` with short grace period
- [x] Cancel pending auth-failure toast when connection state transitions to connecting/reconnecting/connected/reconnected/disconnected
- [x] Deduplicate/reschedule pending auth-failure toasts across repeated auth error variants
- [x] Keep non-auth failures immediate
- [x] Emit explicit diagnostics for auth-failure toast lifecycle (`scheduled`, `duplicateSuppressed`, `cancelled`, `emitted`, `suppressed`)
- [x] Reuse unified auth-failure classifier for local auth recovery predicate + toast deferral

### Verification
- [x] `swift test --filter OpenClawManagerTests`
  - [x] `authFailureToast_isCancelledWhenConnectionRecoversQuickly`
  - [x] `authFailureToast_isEmittedWhenFailurePersists`
  - [x] `authFailureToast_reschedulesAndEmitsAtMostOnceAcrossAuthFailureVariants`

### Review
- [x] Transient `device token mismatch` failures no longer surface user-facing error toasts if connection recovers during grace window.
- [x] Persistent auth failures still emit a single actionable toast after the grace window.
- [x] OpenClaw manager diagnostics now expose toast suppression decisions directly for incident triage.

## Current Task: Reconnect UX De-Noising (2026-02-24)
- [x] Confirm target UX behavior before implementation

### Implementation
- [x] Debounce reconnect toasts so brief reconnects do not emit user-visible reconnect/reconnected spam
- [x] Suppress duplicate `connected` toast immediately after `reconnected`
- [x] Treat `heartbeat.status` unsupported as optional capability and stop repeated retry/error churn
- [x] Treat `skills.bins` unauthorized role errors as optional capability and degrade gracefully

### Verification
- [x] Update/add OpenClaw manager tests for reconnect toast delay/suppression behavior
- [x] Run targeted tests for OpenClaw manager and gateway reconnection flows

### Review
- [x] Confirm reduced reconnect toast churn in expected quick-recovery path
- [x] Confirm capability fallback does not break normal connected flows

## Current Task: Work Mode Greeting Duplication (2026-02-24)
- [x] Confirm symptom and locate streaming path for Work mode
- [x] Verify OpenClaw chat event semantics (snapshot vs delta)
- [x] Patch OpenClaw streaming normalization to emit true incremental deltas to consumers
- [x] Add regression tests for cumulative snapshot streaming in service/event processor
- [x] Run focused OpenClaw test suite

### Review
- [x] Work mode streaming no longer duplicates cumulative chat snapshot prefixes.
- [x] OpenClaw chat snapshot handling remains compatible with existing finalization/sequence behavior.

## Current Task: Snapshot Rewrite + Explicit Delta Protocol (2026-02-24)
- [x] Confirm scope for follow-up hardening items
- [x] Implement explicit rewrite/regression handling in Osaurus OpenClaw stream processors
- [x] Add telemetry for non-prefix snapshot transitions
- [x] Add Work-mode end-to-end regression test via `WorkExecutionEngine` + OpenClaw stream path
- [x] Patch OpenClaw gateway chat delta payload to include both snapshot text and incremental delta fields
- [x] Run targeted Osaurus + OpenClaw tests

### Review
- [x] Rewrite snapshots are handled explicitly without silent duplication/corruption.
- [x] Non-prefix transitions are observable in diagnostics.
- [x] Work-mode regression remains fixed in end-to-end execution path.
- [x] Gateway emits backward-compatible snapshot text plus explicit incremental delta.
- [x] Targeted verification passed:

## Current Task: Provider Persistence Across Sessions (2026-02-25)
- [x] Confirm bug-fix plan before code changes
- [x] Reproduce and isolate provider/API key restore path for Work mode
- [x] Add failing tests for startup routing and config payload decoding edge cases
- [x] Patch route logic so existing connected/configured users do not get misrouted to provider setup
- [x] Patch `config.get` full payload decoding so persisted providers are read from both payload formats
- [x] Run targeted tests for Work empty-state routing and OpenClaw gateway config parsing
- [x] Update review notes with validation evidence

### Review
- [x] Root cause validated with code-level evidence
- [x] Fixes verified with tests
  - `swift test --filter WorkViewEmptyStateLogicTests` (10 tests passed)
  - `swift test --filter configGetFull_acceptsFlattenedConfigPayloadWithLegacyHashField` (1 test passed)
  - `swift test --filter OpenClawGatewayConnectionPhase1Tests` still reports unrelated pre-existing failure:
    `eventBuffer_dropsOldestFramesWhenOverflowing`

## Current Task: OpenClaw Onboarding Stage UI Missing (2026-02-24)
- [x] Confirm likely root cause in Osaurus wizard-stage renderer

### Implementation
- [x] Ensure onboarding wizard stages always render visible content (including empty/fallback states)
- [x] Map action stages to explicit primary action UX (`Run`) in channel-link onboarding
- [x] Align action-stage submission payload with OpenClaw onboarding expectations

### Verification
- [x] Add/update focused tests for channel-link onboarding stage rendering/logic fallbacks
- [x] Run targeted tests for the OpenClaw phase/view logic suite

### Review
- [x] Onboarding stage no longer appears blank in Osaurus.
- [x] Action stages are clearly actionable and submit expected values.
- [x] Targeted test evidence: `swift test --filter OpenClawPhase3ViewLogicTests` (17 tests passed).

## Current Task: Work Mode Tool Failure Visibility + Scope Clarity (2026-02-24)
- [x] Confirm issue and collect runtime evidence from OpenClaw logs
- [x] Verify `web_fetch` failures are runtime/tool failures, not just UI color/state noise
- [x] Verify memory read failures and workspace state for `MEMORY.md` and dated memory files
- [x] Harden activity ingestion against malformed/blank tool names
- [x] Improve Work action-feed/tool row failure detail summarization
- [x] Distinguish Osaurus-local abilities from OpenClaw runtime tools in Work mode UI
- [x] Add focused tests and run targeted verification

### Review
- [x] Runtime evidence confirms repeated failures in `/tmp/openclaw/openclaw-2026-02-24.log` (`web_fetch` 403/404/500 and `read` ENOENT on memory files).
- [x] Osaurus now normalizes malformed/blank tool names to `invalid_tool_name` to avoid blank/confusing tool rows.
- [x] Work action feed now shows concise failure summaries (`Missing file: ...`, `Web fetch failed (HTTP NNN)`).
- [x] Work mode capability UI now explicitly states these are local Osaurus tools/skills and OpenClaw runtime tools may differ.
- [x] Verification passed: `swift test --filter OpenClawActivityStore`, `swift test --filter WorkToolActivityPresentationTests`.

## Current Task: Investigate SwiftUI chat UI bindings (2026-02-24)
- [x] Confirm plan before research
- [x] Collect context on run completion UI and chat progress views
- [x] Trace related components back to their view models and state
- [x] Identify missing wiring or state updates that would cause stale progress/completion indicators
- [x] Patch OpenClaw streaming path so Work chat text consumes `agent/assistant` updates (not only `chat` deltas)
- [x] Prevent premature stream termination when `chat.final` arrives before `agent/lifecycle:end`
- [x] Add regression tests for mixed `chat` + `agent` event ordering in Work mode
- [x] Run focused test suite for OpenClaw model service + Work execution OpenClaw path
- [x] Document actionable file/line suggestions and validation notes in this plan’s review section

### Review
- [x] Findings documented (files, models, missing wiring) once investigation completes
- [x] Root cause: Work-mode left chat pane is fed by `WorkSession` streaming callbacks (`WorkExecutionEngine` -> `ChatEngine` -> `OpenClawModelService.streamDeltas`), while the right progress/action panel is fed by `OpenClawActivityStore` via global gateway events. `streamDeltas` previously only consumed `chat` channel deltas, so assistant text emitted on `agent/assistant` was visible in the panel but not in chat.
- [x] Wiring fix: `OpenClawModelService.streamDeltas` now also consumes `agent/assistant` text/snapshot updates and normalizes them through the same incremental snapshot logic.
- [x] Completion fix: when any `agent` events are observed for the run, `chat.final` no longer terminates the stream immediately; completion waits for `agent/lifecycle:end` (or error), preventing dropped late assistant updates.
- [x] Final-message fix: `streamDeltas` now also ingests assistant text from `chat.state == "final"` payloads, covering short runs where no prior delta was emitted.
- [x] Regression tests added:
  - `OpenClawModelServiceTests.streamDeltas_keepsStreamingAssistantAfterChatFinalWhenAgentEventsObserved`
  - `OpenClawModelServiceTests.streamDeltas_emitsFinalMessageTextWhenNoPriorDeltaArrived`
  - `WorkExecutionEngineOpenClawTests.executeLoop_openClawRuntime_mixedChatFinalAndAgentAssistant_keepsUpdatingChatStream`
  - `WorkExecutionEngineOpenClawTests.executeLoop_openClawRuntime_finalMessageOnly_stillUpdatesChatStream`
- [x] Verification passed:
  - `swift test --filter OpenClawModelServiceTests`
  - `swift test --filter WorkExecutionEngineOpenClawTests`
## Current Task: OpenClaw Event Payload Shapes
- [ ] Confirm plan before starting research
- [ ] Locate OpenClaw gateway event emission paths for assistant/lifecycle/chat streams and note the emitted payload fields
- [ ] Compile exact payload shapes for assistant text events (data.text, data.delta, data.content) with file/line references

## Current Task: Kimi Coding Endpoint/Auth Alignment (2026-02-24)
- [x] Confirm OpenClaw canonical Kimi Coding endpoint from upstream implementation
- [x] Update Osaurus provider presets/hints to canonical Kimi Coding endpoint and console URL
- [x] Add runtime migration for legacy `kimi-coding` Moonshot Anthropic endpoint configs
- [x] Ensure new session creation attempts migration before qualification
- [x] Add/adjust tests for migration and provider preset values
- [x] Run targeted tests for OpenClaw manager/session/model service and provider presets

### Review
- [x] Osaurus now canonicalizes and migrates legacy `models.providers["kimi-coding"].baseUrl` values from `https://api.moonshot.ai/anthropic` to `https://api.kimi.com/coding`.
- [x] Session creation runs a guarded migration attempt before model qualification, reducing repeated 401 loops for stale configs.
- [x] Preset tests now assert Kimi Coding console URL `https://www.kimi.com/code/en`.
- [x] Verification passed:
  - `swift test --filter migrateLegacyKimiCodingProviderEndpointIfNeeded_rewritesLegacyMoonshotAnthropicBaseUrl`
  - `swift test --filter kimiCodingPreset_usesCanonicalKimiCodingEndpoint`
  - `swift test --filter OpenClawSessionManagerTests`
  - `swift test --filter OpenClawModelServiceTests`

## Current Task: OpenClaw Work Chat/Event Bridge + File Ingestion (2026-02-25)
- [x] Confirm symptom set (trace leakage, frozen final output, missing workspace artifact bridging)
- [x] Ensure Work execution parses and filters OpenClaw control/trace output before rendering
- [x] Ensure clarification/completion parity for OpenClaw gateway runs
- [x] Ingest OpenClaw workspace files into Osaurus artifacts and surface preferred final artifact fallback
- [x] Wire Work chat pane updates to OpenClaw activity events (not count-only changes)
- [x] Add regression coverage for `System:` trace-at-start streaming edge case
- [x] Run focused verification suites

### Review
- [x] Trace leakage fixed in OpenClaw Work execution path by filtering `System:` trace boundary and stripping control blocks before assistant content render.
- [x] Final-output freeze mitigated by lifecycle finalization grace fallback in `OpenClawModelService.streamDeltas` when `chat.final` arrives without lifecycle end.
- [x] Workspace ingestion bridge added: OpenClaw workspace files are loaded, filtered, deduplicated, imported as artifacts, and `README/result/summary` can become final artifact fallback.
- [x] Work chat now syncs from `activityStore.$items` updates (full publisher), so incremental/final assistant text updates propagate even without item count changes.
- [x] Verification passed:
  - `swift test --filter WorkExecutionEngineOpenClawTests`
  - `swift test --filter OpenClawModelServiceTests`
  - `swift test --filter OpenClawEventProcessorTests`
  - `swift test --filter WorkViewEmptyStateLogicTests`

## Current Task: Apple-Grade Work Chat Formatting (2026-02-25)
- [x] Ensure live Work responses render through native message thread markdown blocks (not ticker-only replacement)
- [x] Prevent degraded token-glued activity snapshots from overwriting readable assistant content
- [x] Keep richer markdown activity snapshots eligible for UI sync updates
- [x] Validate with focused formatting and OpenClaw execution tests

### Review
- [x] Work thread now keeps streaming assistant/thinking markdown blocks visible during execution, preserving interactive Osaurus UI affordances.
- [x] Added guardrails in `WorkSession.applyOpenClawActivityItems` to reject collapsed no-whitespace snapshots while still allowing richer markdown replacements.
- [x] Added tests:
  - `WorkSessionOpenClawActivityFormattingTests.applyOpenClawActivityItems_doesNotReplaceReadableContentWithCollapsedSnapshot`
  - `WorkSessionOpenClawActivityFormattingTests.applyOpenClawActivityItems_allowsRicherMarkdownSnapshotToReplaceShorterText`
- [x] Verification passed:
  - `swift test --filter WorkSessionOpenClawActivityFormattingTests`
  - `swift test --filter WorkExecutionEngineOpenClawTests`
  - `swift test --filter OpenClawModelServiceTests`
  - `swift test --filter OpenClawEventProcessorTests`
  - `swift test --filter ShimmerTextTickerTests`

## Current Task: Chat/OpenClaw Control-Block Formatting Bridge (2026-02-25)
- [x] Confirm Chat-mode leak path for `---COMPLETE_TASK_*---` and malformed control payload rendering
- [x] Add shared OpenClaw output formatter for system/control block stripping + completion payload artifact promotion
- [x] Wire live Chat OpenClaw event processor to filter control blocks during stream and finalize with artifact/summary fallback
- [x] Wire OpenClaw chat history loader to sanitize/format assistant text from stored history payloads
- [x] Add regression tests for live event processing and history hydration of completion control blocks
- [x] Run focused OpenClaw stream/history/work regression suites

### Review
- [x] Root cause: Chat stream (`OpenClawEventProcessor`) and history hydration (`OpenClawChatHistoryLoader`) rendered raw OpenClaw control blocks; only Work-mode path had completion/control parsing.
- [x] Fix: Added `OpenClawOutputFormatting` + `OpenClawControlBlockStreamFilter` and integrated into live stream + history loaders so markers are hidden and completion artifact markdown is promoted for display when appropriate.
- [x] Regression coverage added:
  - `OpenClawEventProcessorTests.processAgentAssistant_completeTaskControlBlock_isNotRenderedAndArtifactIsPromoted`
  - `OpenClawChatHistoryLoaderTests.loadHistory_formatsCompleteTaskControlBlockToArtifact`
- [x] Verification passed:
  - `swift test --filter OpenClawEventProcessorTests`
  - `swift test --filter OpenClawChatHistoryLoaderTests`
  - `swift test --filter OpenClawModelServiceTests`
  - `swift test --filter WorkExecutionEngineOpenClawTests`

## Current Task: Tool Execution Telemetry Audit (2026-02-25)
- [x] Confirm plan before research
- [ ] Document ToolRegistry, MCPServerManager.call_tool, HTTP `/mcp/call`, ChatView tool loop, WorkExecutionEngine local loop, and WorkBatchTool call sites with file/line references
- [ ] Extract current telemetry/logging fields emitted at each surface
- [ ] Propose Terra tool spans/events that capture args, result/failure details, duration, and link to parent inference/agent spans
- [ ] Summarize remaining observability gaps and recommended follow-up

## Task: Runtime Inference Hotspot Audit
- [ ] Confirm the audit plan before digging into searches and code reviews
- [ ] Enumerate every runtime inference path outside tests/docs (FoundationModels, MLX runtime, OpenClaw flows, remote provider APIs, HTTP chat endpoints)
- [ ] Capture file path + approximate line reference + description + observability status (InsightsService / StartupDiagnostics / none) for each hotspot
- [ ] Summarize any instrumentation gaps or follow-ups once every hotspot is mapped
- [ ] Audit ChatEngine, HTTPHandler, RemoteProviderService, and RemoteProviderManager runtime request/response/tool-call/error paths so that each one has file:line, current logging contents, Terra instrumentation to add, and missing attributes/events identified.
- [ ] For every audited path list the missing attributes/events (prompt len/hash, response len/hash, provider, model, stream ttft/tps/chunk count, finish reason, tool call id, error class) and tag which ones need Terra spans/logs.

## Current Task: Runtime Embedding & Safety Audit (2026-02-25)
- [x] Confirm the audit plan before digging into embedding/safety code paths
- [x] Search runtime code (excluding tests/docs) for embedding generation/search routines and moderation/safety execution hooks, noting whether they run or are just metadata
- [x] Capture file/location references for any actual runtime embedding/search or safety/moderation invocations, describing observability and whether instrumentation exists
- [x] Provide explicit confirmation of absence when no runtime embedding/safety execution is found along with supporting evidence (search commands, metadata-only files)

### Review
- [x] Findings recorded with file references and evidence supporting absence/presence of embedding and safety execution

## Task: Runtime Agent Logging Audit
- [x] Confirm plan and identify key modules for agent/tool execution logging research
- [x] Inspect runtime agent logic (reasoning loops, orchestration, tool APIs/routing/results) outside tests/docs and record logging locations with fields
- [x] Document per-file line numbers listing logged context fields and what is missing for each hotspot
- [x] Summarize findings and recommendations for missing context logging

## Task: Deep OpenClaw Event Flow Audit
- [x] Confirm plan before digging into the runtime files
- [x] Map connection setup, transport layers (ws/rpc), subscriptions/polling, event frame decoding, sequence handling, and run/session mapping with precise file/line references
- [x] Detail lifecycle completion and reconnect/resync behavior, including how events transition through the flow
- [ ] Summarize the end-to-end event flow with file path/line citations for delivery.

### Review
- [ ] Record final observations and any follow-up actions or uncertainties

## Task: OpenClaw Event Processing Observability Audit
- [ ] Confirm plan before research
- [ ] Review `OpenClawModelService`, `OpenClawEventProcessor`, `OpenClawGatewayConnection`, `OpenClawActivityStore`, and `WorkSession`/`WorkEngine` integration to trace which event fields are persisted, dropped, or transformed during runtime.
- [ ] Identify observability/logging coverage for tool calls, error handling, and stream state updates, noting missing entries or gaps in diagnostics per module (with file/line references).
- [ ] Summarize findings with concrete file paths and line citations, highlighting fields captured/dropped and any logging gaps.

### Review
- [ ] Note any follow-up instrumentation or documentation actions.

## Current Task: MLX Runtime Telemetry Audit (2026-02-25)
- [ ] Confirm plan before research
- [ ] Enumerate telemetry hotspots in MLXService, ModelRuntime, MLXGenerationEngine, StreamAccumulator, and FoundationModelService
- [ ] Capture file:line, operation, existing telemetry, and missing Terra span wrappers for each hotspot
- [ ] List input/output prompt, token/time/tool-failure capture opportunities and summarize instrumentation gaps

## Task: OpenClaw Runtime Telemetry Audit
- [ ] Confirm audit plan before digging into code
- [ ] Enumerate runtime OpenClaw components (GatewayConnection, ModelService, EventProcessor, Manager, ActivityStore, WorkExecutionEngine/OpenClaw path, WorkSession/WorkView sync) and their entry points
- [ ] For each hotspot, document current telemetry, capture file:line context, and identify gaps versus Terra span/event best practices
- [ ] Draft Terra instrumentation recommendations with span hierarchy + event list (event ingestion, sequence gaps, reconnect/resync, run lifecycle, tool phases, dropped/filtered text)
- [ ] Summarize gaps and follow-up actions

### Review
- [ ] Record final observations and any tooling/monitoring follow-ups

## Current Task: OpenClaw telemetry coverage audit (2026-02-25)
- [x] Confirm plan before research
- [ ] Review telemetry spans and diagnostics in OpenClawGatewayConnection, OpenClawEventProcessor, OpenClawModelService, OpenClawManager, and WorkExecutionEngine OpenClaw path
- [ ] List hotspots missing Terra spans/events/attributes with file:line references and recommended metadata additions

## Task: Final Telemetry Coverage Audit (2026-02-25)
- [ ] Confirm plan before audit
- [ ] Enumerate instrumentation in Packages/OsaurusCore for AI runtime paths, agent loops, tool execution, OpenClaw flows, remote providers, session/manager flows, and launch/bridge operations
- [ ] Identify concrete coverage gaps plus metadata richness and privacy/redaction exposures per file:line
- [ ] Record minimal fix suggestions and rationale for each gap
- [ ] Write review notes summarizing outstanding risks and follow-up actions

## Current Task: ModelRuntime Swift 6 Concurrency Capture Fix (2026-02-26)
- [x] Confirm plan before patching

### Implementation
- [x] Inspect `ModelRuntime.streamWithTools` around compiler-reported lines
- [x] Remove cross-concurrency mutable captures for `outputTokenCount` and `outputText`
- [x] Keep telemetry behavior unchanged (`recordChunk`, output token accounting, raw response attribute)

### Verification
- [x] Run focused Swift build/test command covering `OsaurusCore`
- [x] Update review notes with evidence

### Review
- [x] Confirm compiler capture errors are resolved
- Focused verification command: `swift test --package-path Packages/OsaurusCore --filter OpenClawManagerTests` (log: `/tmp/modelruntime-fix.log`, exit 1 due unrelated files).
- Log grep confirms no remaining `ModelRuntime.swift` references for `outputTokenCount` / `outputText` capture diagnostics; current blockers are in `OpenClawManager.swift`, `OpenClawGatewayConnection.swift`, and `RemoteProviderService.swift`.

## Current Task: RemoteProviderService + WorkExecutionEngine Swift 6.2 Isolation Fix (2026-02-26)
- [x] Confirm plan before patching

### Implementation
- [x] Analyze `WorkExecutionEngine.swift` span closures (lines ~279-702) for the reported Swift 6.2 concurrency violations
- [x] Identify the minimal behavioral-safe adjustments (message mutation, inout capture abstractions, actor helper sequencing)
- [x] Draft and document the minimal code patch or workaround that satisfies the compiler without altering runtime behavior

### Verification
- [x] Run focused package build/test command for `Packages/OsaurusCore`
- [x] Confirm reported diagnostics no longer appear in build output

### Review
- [x] Summarize root causes, changes, and verification evidence
- Root causes were Swift 6.2 actor/sendable checks in span/task closures: actor-isolated helper calls from sendable closures, mutable `inout`-style message mutation in concurrently-executing closures, and optional `baseURL` dereference.
- `RemoteProviderService` now uses static request/response helpers where needed, safe optional endpoint handling, and immutable telemetry snapshots before async `Task` spans.
- `WorkExecutionEngine` now uses a sendable message buffer for closure-safe mutation and static pure helper methods for completion/parsing utilities called from span closures.
- Verification used `swift build --package-path Packages/OsaurusCore` with logs at `/tmp/osauruscore-build-20260226-pass2.log` and `/tmp/osauruscore-build-20260226-pass3.log`.
- Targeted files compile cleanly in pass3; remaining build failures are in unrelated OpenClaw files.


## Current Task: RemoteProviderService actor-isolation line analysis (2026-02-26)
- [x] Confirm plan before starting file inspection

### Steps
- [x] Inspect `Packages/OsaurusCore/Services/RemoteProviderService.swift` near lines 202, 222, 261, 878, 902, and 959 for Swift 6.2 actor-isolation diagnostics
- [x] Map the actor-isolated helpers/methods involved and document the exact signature/call-site changes needed to satisfy isolation rules
- [x] Draft minimal production-grade edits (method signatures + caller updates) that avoid behavioral regressions while resolving the violations
- [ ] Map the actor-isolated helpers/methods involved and document the exact signature/call-site changes needed to satisfy isolation rules
- [ ] Draft minimal production-grade edits (method signatures + caller updates) that avoid behavioral regressions while resolving the violations

### Review
- [x] Capture the proposed changes and verification plan in `tasks/todo.md`

## Current Task: OpenClaw Gateway/EventProcessor Swift 6 capture fixes (2026-02-26)
- [x] Confirm plan before patching

### Implementation
- [x] Fix `OpenClawGatewayConnection.swift` captured mutable `attempt` values in reconnect telemetry closures by using immutable per-iteration snapshots
- [x] Fix `OpenClawGatewayConnection.swift` captured mutable `lastError`/`lastRawError` telemetry values by snapshotting final immutable values before async span closure
- [x] Fix `OpenClawEventProcessor.swift` optional event sequence telemetry (`Int?` to `Int`) and sendable capture safety for event timestamp

### Verification
- [x] Run `swift build` for `Packages/OsaurusCore` and inspect compiler diagnostics
- [x] Confirm no remaining errors in `OpenClawGatewayConnection.swift` and `OpenClawEventProcessor.swift`

### Review
- [x] Requested compiler errors in `OpenClawGatewayConnection.swift` and `OpenClawEventProcessor.swift` are resolved.
- Verification command: `swift build` in `Packages/OsaurusCore` (log: `/tmp/osauruscore-swift-build.log`).
- Remaining package errors are outside this scope in `Managers/OpenClawManager.swift` (`pollAttempt`/`recoveryAttempt` sendable captures + `isConnected` actor-isolation access).

## Current Task: OpenClawManager Swift 6 capture/isolation fixes (2026-02-26)
- [x] Confirm plan before patching

### Implementation
- [x] Replace concurrent `Task` closure captures of mutable `pollAttempt` with immutable per-closure snapshots
- [x] Replace concurrent `Task` closure captures of mutable `recoveryAttempt` with immutable per-closure snapshots
- [x] Replace concurrent `Task` closure access to main-actor isolated `isConnected` with an immutable snapshot captured on actor

### Verification
- [x] Run `swift build --package-path Packages/OsaurusCore`
- [x] Confirm the reported `OpenClawManager.swift` diagnostics no longer appear

### Review
- [x] Requested Swift 6 diagnostics in `OpenClawManager.swift` are resolved.
- Verification log: `/tmp/osauruscore-openclawmanager-fix.log`.
- Build now completes successfully; remaining output is warning-only (deprecations + separate actor-isolated warnings in other files).

- [x] Confirm plan before research
- [x] Locate Terra/OpenTelemetry telemetry initialization across the repo (agents, runtime, tool loops, CLI) and note exact file:line locations
- [x] Identify code paths that configure OTLP export to `localhost:4318` or default to it (include initializer calls, env defaults, and any docs referencing the endpoint)
- [x] Propose a minimal fix (e.g., guard/flag, env check, or disabling default export when collector absent) to suppress repeated connection-refused noise when no collector is running
- [x] Summarize findings and suggested fix in this plan for review

### Implementation
- [x] Add explicit `Terra.OpenTelemetryConfiguration` wiring in `AppDelegate` instead of relying on OTLP defaults
- [x] Make OTLP export opt-in via env flags and default to local-only instrumentation (no network export)
- [x] Emit a startup log indicating whether OTLP export is enabled and which endpoint is selected

### Verification
- [x] Run `swift build --package-path Packages/OsaurusCore`
- [x] Confirm no compile regressions in `AppDelegate` telemetry bootstrap path

### Review
- `Terra.start()` in `AppDelegate` no longer relies on Terra/OpenTelemetry default OTLP endpoints.
- Startup now resolves explicit OpenTelemetry config from env vars, with OTLP export disabled by default to avoid noisy localhost OTLP failures when no collector is present.
## Task: Telemetry OTLP Noise Audit (2026-02-26)

## Current Task: MLX + Agent Trace Audit (2026-02-26)
- [x] Confirm plan before research
- [ ] Locate MLX trace emission points, recording span names/attributes/kind and file/function references
- [ ] Trace agent and tool-use span emission sites, noting schema details and surrounding telemetry logic
- [ ] Identify schema mismatches that could break Insights rendering and flag suspected sources
- [ ] Summarize findings for documentation and next steps

### Review

## Task: Insights view trace filtering investigation
- [x] Confirm plan before research
- [ ] Trace the Insights view load path and identify where traces/spans are fetched
- [ ] Document the category/type filters and list regression points with file:line references
 - OTLP can be enabled via `OSAURUS_OTLP_EXPORT_ENABLED=1`, optionally using `OTEL_EXPORTER_OTLP_ENDPOINT` or per-signal `OTEL_EXPORTER_OTLP_*_ENDPOINT`.
 - Verification command: `swift build --package-path Packages/OsaurusCore` (build succeeded; existing unrelated warnings remain).

## Current Task: MLX + Agent Trace Audit (2026-02-26)
- [x] Confirm plan before research
- [ ] Locate MLX trace emission points, recording span names/attributes/kind and file/function references
- [ ] Trace agent and tool-use span emission sites, noting schema details and surrounding telemetry logic
- [ ] Identify schema mismatches that could break Insights rendering and flag suspected sources
- [ ] Summarize findings for documentation and next steps

### Review

## Current Task: Trace tree reset + clear controls (2026-02-27)
- [x] Confirm plan before patching

### Implementation
- [x] Add regression test covering stable tool trace group identity across appended tool calls
- [x] Persist tool trace group expansion state across streaming updates
- [x] Stop trace rows from disappearing prematurely during streaming trace-heavy runs
- [x] Add user-facing "Clear traces" action in Work progress sidebar wired to `OpenClawActivityStore`

### Verification
- [x] Run focused tests for updated trace/tree behavior
- [x] Run broader `OsaurusCore` test command for regression signal

### Review
- [x] Summarize root cause, fix, and verification evidence
- Root causes addressed: unstable tool-group block IDs (causing trace tree remount/collapse), local-only summary expansion state, and aggressive streaming block cap that dropped visible trace rows mid-run.
- Follow-up root cause addressed: Work trace panel projection was run-scoped (`activeRunId`) and could jump to another run while the user was inspecting traces.
- Added `TraceTreeStabilityTests` to lock stable tool-group identity and larger streaming trace window behavior.
- Added `OpenClawActivityStore.clearTimeline()` and wired a new sidebar `Clear traces` action in `IssueTrackerPanel`/`WorkView`.
- Added chronological display projection (`timelineItemsForDisplay`) and switched Work trace sidebar to that path to avoid auto-jumping to a different run/span while viewing.
- Focused verification passed:
  - `swift test --package-path Packages/OsaurusCore --filter TraceTreeStabilityTests`
  - `swift test --package-path Packages/OsaurusCore --filter OpenClawActivityStoreEdgeCaseTests.clearTimeline_clearsItemsButKeepsRunState`
  - `swift test --package-path Packages/OsaurusCore --filter OpenClawActivityStoreEdgeCaseTests.timelineItemsForDisplay_keepsChronologicalItemsAcrossRuns`
  - `swift test --package-path Packages/OsaurusCore --filter OpenClawActivityStoreEdgeCaseTests.timelineItemsForFocusedRun_scopesToActiveRun`
- Broader regression signal command run:
  - `swift test --package-path Packages/OsaurusCore` (fails in pre-existing suites unrelated to this patch, including `WorkSessionOpenClawActivityFormattingTests`, `WorkExecutionEngineOpenClawTests`, `OpenClawManagerOnboardingTests`, and `OpenClawGatewayConnectionPhase1Tests`).

## Current Task: OpenClawActivityStore assistant cumulative-delta handling (2026-02-28)
- [x] Confirm plan before patching

### Implementation
- [x] Inspect `OpenClawActivityStore.processAssistant` and confirm cumulative-snapshot `data.delta` duplication risk
- [x] Add minimal snapshot-aware assistant delta handling while preserving existing stream/media behavior
- [x] Keep behavior stable for explicit `data.text` snapshots and incremental deltas

### Verification
- [x] Add regression tests in `Packages/OsaurusCore/Tests/OpenClawActivityStoreStreamingTests.swift`
- [x] Run focused `swift test --package-path Packages/OsaurusCore --filter OpenClawActivityStoreStreamingTests`

### Review
- [x] Summarize root cause, patch, and verification evidence
- Root cause: `processAssistant` appended `delta` whenever `text` was absent (`activity.text + delta`). If upstream sent cumulative snapshots in `delta`, assistant text duplicated (e.g., `Hello` + `Hello world`).
- Patch: added `mergeAssistantText(currentText:fullText:delta:)` and used it for both update/create paths. It still prefers explicit `data.text`, appends incremental deltas, and replaces text when `delta` already prefixes with current text (snapshot semantics).
- Regression tests added:
  - `assistantDeltaCumulativeSnapshot_withoutText_doesNotDuplicate`
  - `assistantDeltaIncremental_withoutText_appends`
- Verification passed: `swift test --package-path Packages/OsaurusCore --filter OpenClawActivityStoreStreamingTests` (7/7 tests passing).

## Current Task: Work mode hello duplication bundle (2026-02-28)
- [x] Confirm plan before patching

### Implementation
- [x] Normalize OpenClaw stream payload handling so snapshot-style `delta` chunks cannot duplicate assistant output
- [x] Prevent Work gateway prompt from duplicating identical issue title/description text (`hello hello`)
- [x] Harden activity-store assistant merge logic for snapshot-like and stale duplicate deltas
- [x] Add/adjust regression tests for stream normalization + Work prompt deduplication

### Verification
- [x] Run focused OpenClaw model service stream tests
- [x] Run focused activity-store streaming tests
- [x] Run focused Work execution OpenClaw tests

### Review
- [x] Summarize root cause, patch scope, and verification evidence
- Root causes:
  - `OpenClawModelService.streamDeltas` trusted explicit `delta` as always-incremental; snapshot-style deltas could repeat content (`Hello` + `Hello there` -> `HelloHello there`).
  - Work gateway input could send duplicate query text when issue `title == description` and the same text also existed in user context.
  - `OpenClawActivityStore.processAssistant` handled stale shorter snapshot-style deltas as appends.
- Patch scope:
  - Added payload-level delta resolver in `OpenClawModelService` that prioritizes snapshot normalization and normalizes delta-only cumulative snapshots.
  - Updated `WorkExecutionEngine.buildOpenClawGatewayInput` to dedupe identical issue title/description and skip redundant user-context lines already represented by the issue prompt.
  - Hardened `OpenClawActivityStore.mergeAssistantText` to ignore stale shorter deltas and keep latest text stable.
  - Reset `WorkSession` streaming processor when adopting activity-snapshot replacement to avoid overlap with buffered deltas.
- Regression coverage added/updated:
  - `OpenClawModelServiceTests.streamDeltas_deltaOnlyCumulativeSnapshots_withoutText_doNotDuplicate`
  - `OpenClawModelServiceTests.streamDeltas_agentAssistantDeltaOnlyCumulativeSnapshots_doNotDuplicate`
  - `OpenClawActivityStoreStreamingTests.assistantDeltaStaleSnapshot_withoutText_isIgnored`
  - `WorkExecutionEngineOpenClawTests.executeLoop_openClawRuntime_deduplicatesIssuePromptAndContext`
- Verification evidence:
  - `swift test --package-path Packages/OsaurusCore --filter OpenClawModelServiceTests` (22 passed)
  - `swift test --package-path Packages/OsaurusCore --filter OpenClawActivityStoreStreamingTests` (8 passed)
  - `swift test --package-path Packages/OsaurusCore --filter WorkExecutionEngineOpenClawTests` (8 passed)
  - `swift test --package-path Packages/OsaurusCore --filter WorkSessionOpenClawActivityFormattingTests` (4 passed)
