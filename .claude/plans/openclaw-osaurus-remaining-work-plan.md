# OpenClaw Osaurus Residual Risk Register

Date: 2026-02-20  
Scope: WS-F / F-02 residual risks after WS-A through WS-F completion  
Companion docs:
- `.claude/plans/openclaw-osaurus-local-smoke-report.md`
- `.claude/plans/openclaw-osaurus-integration.md`

## Decision Outcomes (Now Locked)

- Unread policy: explicit clear action only (no auto-clear on dashboard open).
- Notification architecture: event-driven ingest with polling fallback.
- Enterprise gate at this stage: local smoke evidence + deterministic hermetic coverage; broader staged validation remains an operational follow-up.

## Residual Risk Table

| Risk | Probability | Impact | Mitigation | Owner |
|---|---|---|---|---|
| Live channel E2E variability (provider/network dependent) can diverge from hermetic behavior in real operator environments. | Medium | High | Keep pre-release smoke runbook mandatory per environment, include at least one real inbound/outbound exchange per enabled channel before production rollout. | Integrations (Osaurus) |
| Notification freshness can degrade to poll cadence when inbound gateway events are absent. | Medium | Medium | Maintain event ingest path as primary, keep poll fallback deterministic, and monitor `lastInboundAt` drift during staged rollout. | Integrations (Osaurus) |
| Multi-gateway reachability (e.g., ssh tunnel + remote target) can introduce operator confusion about active target selection. | Medium | Medium | Document `gateway probe` target interpretation, pin preferred target in runbooks, and treat `multiple_gateways` warning as an explicit operator check. | Platform Ops |
| Auth token mismatch/rotation causes immediate disconnects until credentials are synchronized. | Medium | Medium | Keep clear unauthorized error surfacing, provide token reissue steps in operator docs, and validate auth on startup checks. | Platform Ops |
| Seq-gap handling relies on refresh via `agent.wait`; upstream protocol changes could alter terminal-state assumptions. | Low | High | Preserve targeted regression suite (`sequenceGap`, reconnect interleaving, immediate-end race tests) as merge gate; revisit semantics on upstream protocol bumps. | Integrations (Osaurus) |
| Existing unrelated dirty workspace state (`Packages/OsaurusCore/AppDelegate.swift`) may affect release packaging if not reconciled by owner. | Medium | Medium | Keep out of scoped commits; require owner review/reconcile before release tagging. | Repo Owner |

## Validation Expectations Going Forward

- Keep required validation commands as mandatory for each OpenClaw task:
  1. `swift test --filter OpenClaw`
  2. `swift test`
  3. `swift build`
- For ordering/race-sensitive changes, retain repeated run guard (`>=10` iterations) in CI or local pre-merge verification.

## Residual-Risk Exit Statement

No hidden assumptions remain undocumented in this pass; outstanding risks are explicit, owned, and paired with mitigation actions.
