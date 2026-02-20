# OpenClaw Osaurus Integration Handoff

Date: 2026-02-20  
Scope: WS-F / F-01 finalized behavior record for OpenClaw integration hardening

## 1) Seq-Gap Resync Semantics (Final)

### Contract

- `OpenClawEventProcessor` detects sequence gaps when `seq > lastSeq + 1` and emits a lightweight callback only.  
  Source: `Packages/OsaurusCore/Services/OpenClawEventProcessor.swift`
- `OpenClawModelService` binds this callback to run-scoped resync by calling:
  - `OpenClawGatewayConnection.registerSequenceGap(runId:expectedSeq:receivedSeq:)`  
  Source: `Packages/OsaurusCore/Services/OpenClawModelService.swift`
- `OpenClawGatewayConnection.registerSequenceGap` guarantees at least one targeted refresh pass by:
  - inserting the `runId` into `pendingResyncRunIDs`
  - immediately invoking `refresh(runIdHint: runId)`  
  Source: `Packages/OsaurusCore/Services/OpenClawGatewayConnection.swift`
- `refresh(runIdHint:)` inspects the union of:
  - active runs
  - pending resync run IDs
  - explicit run hint
  Then calls `agent.wait(timeoutMs: 0)` per run and clears pending/active tracking when terminal.

### Why this is final

- It closes the race where lifecycle-end events can remove active-run tracking before refresh executes.
- Reconnect path also performs `announcePresence()` and `refresh()` after successful reconnect, so missed frames have a catch-up path.

### Deterministic evidence

- `OpenClawModelServiceTests.streamRunIntoTurn_sequenceGapTriggersConnectionRefresh()`
- `OpenClawModelServiceTests.streamRunIntoTurn_multipleSequenceGapsTriggerRepeatedRefreshes()`
- `OpenClawModelServiceTests.streamRunIntoTurn_gapThenImmediateEnd_isDeterministicAcrossIterations()`
- `OpenClawGatewayConnectionPhase1Tests.registerSequenceGap_refreshesEvenAfterLifecycleEndRemovesActiveRun()`
- `OpenClawGatewayConnectionPhase1Tests.registerSequenceGap_gapResyncSurvivesReconnectInterleaving()`

## 2) Notification Unread Policy (Final)

### Product policy

- Unread is cleared only by explicit user action.
- Dashboard open does not auto-clear unread.

### Implementation

- Header action `Clear Unread` triggers `manager.markAllChannelNotificationsRead()`.  
  Source: `Packages/OsaurusCore/Views/OpenClawDashboardView.swift`
- `OpenClawManager.markAllChannelNotificationsRead()` delegates to notification service and keeps policy comment in code.  
  Source: `Packages/OsaurusCore/Managers/OpenClawManager.swift`
- `OpenClawNotificationService` behavior:
  - event-driven ingestion via `ingestEvent(_:)`
  - polling fallback (`20s`) via `channels.status`
  - dedupe by `channelId::accountId` + normalized inbound timestamp
  - startup/reconnect baseline guard (`listeningStartedAt` with grace window) to suppress historical flood
  - unread counter increments only on fresh inbound events  
  Source: `Packages/OsaurusCore/Services/OpenClawNotificationService.swift`

### Deterministic evidence

- `OpenClawNotificationServiceTests.unreadCount_persistsUntilExplicitClearAction()`
- `OpenClawNotificationServiceTests.ingestEvent_postsNotification_andPollFallbackDedupesSameTimestamp()`
- `OpenClawNotificationServiceTests.ingestEvent_ignoresHistoricalInboundBeforeListeningBaseline()`
- `OpenClawNotificationServiceTests.reconnectBaselineReset_suppressesStaleNotificationsAfterReconnect()`
- `OpenClawNotificationServiceTests.multiAccountBurst_dedupesPerAccountAndTimestamp()`
- `OpenClawNotificationServiceTests.rapidUnchangedPollCycles_doNotIncrementUnread()`

## 3) Presence Identity Precedence and Rendering (Final)

### Identity and timestamp rules

- Presence decode includes `deviceId`, `roles`, `scopes`, and `tags`.
- `primaryIdentity` precedence:
  1. `deviceId`
  2. `instanceId`
  3. `host`
  4. `ip`
  5. `text`
  6. fallback synthetic `presence-<timestamp>`
- Timestamp normalization accepts second- or millisecond-scale numeric values and string timestamps; internal representation is `timestampMs`.
  Source: `Packages/OsaurusCore/Models/OpenClawPresenceModels.swift`

### UI/rendering rules

- Connected-clients list sorts by:
  1. newest `timestampMs` first
  2. `primaryIdentity` ascending as deterministic tie-break
- Accessibility label includes display name, primary identity, status mode, and connected-age text.
- Accessibility value includes roles, scopes, and tags (or `none` when absent).  
  Source: `Packages/OsaurusCore/Views/Components/OpenClawConnectedClientsView.swift`

### Deterministic evidence

- `OpenClawGatewayConnectionPhase3PresenceTests.systemPresence_identityFallbackPrefersDeviceThenInstanceThenHostThenIP()`
- `OpenClawGatewayConnectionPhase3PresenceTests.systemPresence_normalizesStringSecondTimestamps()`
- `OpenClawPhase3ViewLogicTests.connectedClientsLogic_sortsByIdentityWhenTimestampsMatch()`
- `OpenClawPhase3ViewLogicTests.connectedClientsAccessibility_includesIdentityStatusAndMetadata()`
- `OpenClawPhase3ViewLogicTests.presenceIdentity_fallbackUsesExpectedOrder()`

## 4) Known Operational Caveats

- In sandboxed CLI environments, local loopback probing may fail with `EPERM`; elevated execution was required for live smoke evidence.
- `gateway probe` may report `multiple_gateways` when both ssh-tunnel and direct remote targets are reachable; active target selection remained stable in smoke runs.
- Notification freshness remains hybrid:
  - event-driven when inbound gateway events are available
  - polling fallback for robustness
  This implies worst-case polling lag remains bounded by the poll interval when no events arrive.

## 5) Architectural Constraints Preserved

- State management remains `ObservableObject` + `@Published` + `@MainActor` managers.
- No `@Observable` adoption in Osaurus integration paths.
- No `OpenClawChatUI` import added.
