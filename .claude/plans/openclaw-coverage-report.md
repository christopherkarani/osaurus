# OpenClaw Coverage Report

Date (UTC): 2026-02-20  
Task: `PR-COV-01`  
Repo: `/Users/chriskarani/CodingProjects/Jarvis/osaurus`

## Scope and Gate

- Coverage scope is OpenClaw-critical runtime paths used by reconnect, seq-gap/resync, and notification-ingestion flows:
  - `Packages/OsaurusCore/Services/OpenClawGatewayConnection.swift`
  - `Packages/OsaurusCore/Services/OpenClawModelService.swift`
  - `Packages/OsaurusCore/Services/OpenClawEventProcessor.swift`
  - `Packages/OsaurusCore/Services/OpenClawNotificationService.swift`
  - `Packages/OsaurusCore/Services/OpenClawSessionManager.swift`
  - `Packages/OsaurusCore/Services/OpenClawChatHistoryLoader.swift`
  - `Packages/OsaurusCore/Models/OpenClawChannelStatus.swift`
  - `Packages/OsaurusCore/Models/OpenClawPresenceModels.swift`
- Enforced threshold: `69%` line coverage for the above scope.
- Enforcement commands:
  - `./scripts/openclaw/coverage_gate.sh`
  - `make openclaw-coverage-gate`

## Commands and Evidence

| UTC timestamp | Command | Exit | Evidence |
|---|---|---|---|
| 2026-02-20T23:18:35Z | `/bin/zsh -lc 'cd /Users/chriskarani/CodingProjects/Jarvis/osaurus && ./scripts/openclaw/coverage_gate.sh'` | `0` | `.claude/plans/artifacts/openclaw-production/coverage/coverage-20260220T231835Z-4CF105A3/summary.json` |
| 2026-02-20T23:18:46Z | `/bin/zsh -lc 'cd /Users/chriskarani/CodingProjects/Jarvis/osaurus && ./scripts/openclaw/coverage_gate.sh 95'` | `1` | `.claude/plans/artifacts/openclaw-production/coverage/coverage-20260220T231846Z-3D88710B/summary.json` |
| 2026-02-20T23:18:58Z | `/bin/zsh -lc 'cd /Users/chriskarani/CodingProjects/Jarvis/osaurus && make openclaw-coverage-gate'` | `0` | `.claude/plans/artifacts/openclaw-production/coverage/coverage-20260220T231858Z-5246E38C/summary.json` |

## Primary Coverage Result (`69%` gate)

Artifact: `.claude/plans/artifacts/openclaw-production/coverage/coverage-20260220T231835Z-4CF105A3/summary.json`

- Status: `passed`
- Covered lines: `1771`
- Total lines: `2552`
- Line coverage: `69.39655172413794%`

Per-file artifact: `.claude/plans/artifacts/openclaw-production/coverage/coverage-20260220T231835Z-4CF105A3/openclaw-critical-per-file.tsv`

| File | Covered | Total | Percent |
|---|---:|---:|---:|
| `Models/OpenClawChannelStatus.swift` | 79 | 105 | 75.24% |
| `Models/OpenClawPresenceModels.swift` | 88 | 118 | 74.58% |
| `Services/OpenClawChatHistoryLoader.swift` | 203 | 246 | 82.52% |
| `Services/OpenClawEventProcessor.swift` | 203 | 305 | 66.56% |
| `Services/OpenClawGatewayConnection.swift` | 640 | 969 | 66.05% |
| `Services/OpenClawModelService.swift` | 248 | 309 | 80.26% |
| `Services/OpenClawNotificationService.swift` | 196 | 379 | 51.72% |
| `Services/OpenClawSessionManager.swift` | 114 | 121 | 94.21% |

## Gate-Failure Proof (Synthetic)

Artifact: `.claude/plans/artifacts/openclaw-production/coverage/coverage-20260220T231846Z-3D88710B/summary.json`

- Command used threshold `95%`.
- Result: `failed` with exit code `1`.
- Measured line coverage remained `69.39655172413794%`, below threshold.
- Confirms gate is enforceable and fails validation when threshold is not met.

## Threshold Rationale

- `69%` is set to be strict enough to block regressions in OpenClaw-critical runtime paths while matching current validated baseline (`69.40%` in passing run).
- The gate is non-optional in automation via `coverage_gate.sh` and Makefile target `openclaw-coverage-gate`.
- Coverage below `69%` is a release validation failure for OpenClaw-critical scope.

## `PR-COV-01` Verdict

- Status: `PASS`
- Criteria met:
  - Coverage report generated for OpenClaw-critical paths.
  - Explicit line-coverage threshold implemented.
  - Enforceable failing gate behavior proven with synthetic threshold breach.
