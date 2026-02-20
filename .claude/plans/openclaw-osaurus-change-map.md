# OpenClaw Osaurus Change Map

Date: 2026-02-20  
Scope: Current dirty OpenClaw integration files in `osaurus/`  
Purpose: WS-A / A-01 classification of every modified file by intent and revert risk.

## Classification Summary

### Event / Resync Logic

| File | Intent | Risk If Reverted |
|---|---|---|
| `Packages/OsaurusCore/Services/OpenClawGatewayConnection.swift` | Reconnect behavior, disconnect classification, event buffering, run refresh plumbing. | High: regress reconnect stability and seq-gap recovery; higher odds of missed late events. |
| `Packages/OsaurusCore/Services/OpenClawModelService.swift` | Route seq-gap callback to gateway refresh during streaming run processing. | High: seq-gap path can silently skip catch-up/refresh. |
| `Packages/OsaurusCore/Tests/OpenClawGatewayConnectionPhase1Tests.swift` | Validate gateway request/stream behavior and presence-related decode paths used by reconnect/runtime flow. | Medium: reduced guardrails for transport/regression bugs. |
| `Packages/OsaurusCore/Tests/OpenClawModelServiceTests.swift` | Verify run streaming, lifecycle handling, and seq-gap refresh trigger behavior. | High: seq-gap and lifecycle races can regress undetected. |

### Notification Pipeline

| File | Intent | Risk If Reverted |
|---|---|---|
| `Packages/OsaurusCore/Services/OpenClawNotificationService.swift` | Notification dedupe/startup behavior, unread/badge tracking, polling listener behavior. | High: duplicate notifications, stale startup floods, unread drift. |
| `Packages/OsaurusCore/Managers/OpenClawManager.swift` | Orchestrate notification lifecycle with connection state and status refresh updates. | High: notification state can desync on connect/reconnect/disconnect. |
| `Packages/OsaurusCore/Views/OpenClawDashboardView.swift` | Dashboard-level notification/read side effects and refresh triggers. | Medium: unread policy may diverge from intended UX. |
| `Packages/OsaurusCore/Tests/OpenClawNotificationServiceTests.swift` | Hermetic tests for startup, dedupe, and unread clear semantics. | High: notification regressions become non-deterministic/manual-only. |

### Presence Protocol Mapping + UI

| File | Intent | Risk If Reverted |
|---|---|---|
| `Packages/OsaurusCore/Models/OpenClawPresenceModels.swift` | Normalize presence identity/timestamps and decode protocol fields (`deviceId`, `roles`, `scopes`, `tags`). | High: wrong identity precedence, ms/sec timestamp bugs, inconsistent client IDs. |
| `Packages/OsaurusCore/Views/Components/OpenClawConnectedClientsView.swift` | Render presence metadata, sorting/fallbacks, and accessibility labels. | Medium: reduced metadata parity and accessibility regressions. |
| `Packages/OsaurusCore/Tests/OpenClawGatewayConnectionPhase3PresenceTests.swift` | Presence decode/normalization correctness checks. | Medium: protocol drift can slip through tests. |

### Wizard / Cron / Skills UI Determinism

| File | Intent | Risk If Reverted |
|---|---|---|
| `Packages/OsaurusCore/Views/Components/OpenClawChannelLinkSheet.swift` | Channel-selection heuristics and wizard step value matching. | Medium: wrong account/channel preselection and operator confusion. |
| `Packages/OsaurusCore/Views/Components/OpenClawCronView.swift` | Toggle optimistic-state handling, run controls, busy/disabled states. | Medium: stuck toggles and nondeterministic UI state. |
| `Packages/OsaurusCore/Views/Components/OpenClawSkillsView.swift` | Skill state labels, toggle behavior, and install actions with busy/error handling. | Medium: stale optimistic state and incorrect skill status display. |
| `Packages/OsaurusCore/Tests/OpenClawPhase3ViewLogicTests.swift` | Shared deterministic logic tests for wizard selection, cron toggles, skills status, presence sorting. | Medium: UI logic regressions move to manual verification only. |

### Lifecycle / Startup Integration

| File | Intent | Risk If Reverted |
|---|---|---|
| `Packages/OsaurusCore/AppDelegate.swift` | App startup/shutdown coordination with OpenClaw manager lifecycle. | Medium: startup auto-connect behavior may drift or stop being deterministic. |

## Classification Notes

- All files above are in-scope for WS-A release hygiene because they are currently dirty OpenClaw integration paths.
- No file is classified as safe-to-revert without behavior/test impact.
- The untracked file `OpenClawPhase3ViewLogicTests.swift` is treated as intentional candidate pending explicit WS-A / A-03 decision.
