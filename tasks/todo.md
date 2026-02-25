# Plan

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
- Auth failure handling already has coverage via `OpenClawGatewayConnectionReconnectionTests.authFailureDisconnect_doesNotRetryReconnect` and the disconnect-classification helpers, which verify unauthorized close codes stop reconnects (`Packages/OsaurusCore/Tests/OpenClawGatewayConnectionReconnectionTests.swift:267-373`).
- `OpenClawManager.connect()` retries once on errors mentioning “device token mismatch” (`Packages/OsaurusCore/Managers/OpenClawManager.swift:678-758`), but there are no OsaurusCore tests exercising that retry path.
- Proposed additions: add a test-only hook for `OpenClawManager.connect()` to stub the gateway connect call, then write two `OpenClawManagerTests` (one that succeeds on the retry and one that keeps failing) to assert the hook is invoked twice and the manager’s state/diagnostics behave as expected.

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
