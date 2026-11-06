# Stage 01 — whole-project review and responsive limits refresh

Status: approved by the user on 2026-11-06; execution in progress.
User scope: whole-project review, primarily Gemini high, fix confirmed findings,
and make the refresh button show limits without waiting for token statistics.
Clarification received: review the whole project, prioritize limits refresh.

## Evidence and intended outcome

`Sources/App/Store.swift:refresh(force:)` currently starts three CLI fetches,
local fallback reads and UsageScanner concurrently, then awaits all five before
publishing. `force: true` forces statistics as well as limits. One isRefreshing
guard covers the entire operation. Both refresh buttons call that same method.

Limits must be publishable independently of slow statistics. Statistics can
continue in the background without keeping the limits refresh indicator active,
blocking another limits request, or overwriting newer provider state. Preserve
the existing VPN policy, refresh intervals, fallbacks, notifications, widget
updates, persistence and localizations. Changing provider authentication/CLI
contracts is outside this performance fix unless the audit proves a separate bug.

## Ordered work

| ID | Description | Ready when | Dependencies | Files | Level | Executor | Status | Orca task_id | dispatch_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 01-01 | Read-only whole-project audit, prioritize refresh, concurrency and process/protocol handling | Report contains reproducible blocker/major/minor findings and exact locations | Plan approval | All tracked files read-only; report recorded by orchestrator | L2 review | Gemini `gemini-3.8-flash-high` | done | task_785f694791f7 | ctx_0ceb147c0f1e (released) |
| 01-02 | Decouple limits publication from token statistics and validate refresh races | Responsive limits path, independent guarded usage work, meaningful deterministic regressions, full acceptance and lead review | 01-01, plan approval | See exact Ownership in spec | L3 | terra lead + luna pieces | in_progress | task_01e9d8be1c52 | ctx_99d5e019e7a8 |
| 01-03 | Triage remaining audit findings into exact bounded fix specs | Each accepted finding is covered by 01-02 or an approved concrete fix spec; rejected findings have reasons | 01-01 | `plan/` only during triage | L1 planning | sol orchestrator | done | not created (planning only) | none |

Do not create an executable catch-all fix Task for 01-03. Add exact tasks after
seeing the audit: each has ownership, level, acceptance and dependencies. Keep
fixes in the authorized review scope; ask before architecture/stack changes.
Independent fixes may run concurrently only with disjoint ownership. Anything
touching refresh ownership waits for 01-02 or is folded into its addendum.

## Acceptance and review

- Gemini high audits first and reviews implementation diffs afterward. L3 lead
  independently reads the entire final diff and owns all review dispositions.
- Deterministic refresh checks cover slow statistics, overlapping completions,
  and VPN/no-read gating. Use injected stubs or a standalone Swift harness;
  never invoke real provider agents or scan user histories during automated tests.
- Because this is a performance request, include a controlled measurement with
  slow synthetic statistics showing limits publish earlier. Do not promise a
  faster external CLI response than the provider actually supplies.
- Full acceptance runs once before implementation commit and once at merge.
  Report any actual macOS manual UI checks separately.
- Integrate serially, push main, release every settled agent/reviewer and safely
  remove child worktrees. Finish with findings, fixes, checks and remaining risks.

## Approval boundary

No Run or product implementation starts before the user approves this committed
plan. This gate is the user's supplied operating rule, not a tool/skill approval.


## Validated fixes after audit
The user already approved review and confirmed fixes; these refine that scope
without an architecture change. See 01-01.review.md for every disposition.

| ID | Description | Acceptance | Dependencies | Files | Level | Executor | Status | task_id | dispatch_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 01-04 | Safe process transport and JSON replies | Spec commands and review dispositions | 01-01 | Fetchers + Process harness | L3 | terra | in_progress | task_00283c688444 | ctx_052bb5219b06 |
| 01-05 | WAL-aware read-only SQLite | Spec commands and review dispositions | 01-01 | Usage + UsageReader harness | L2 | luna | in_progress | task_3680b0de49d3 | ctx_42dfc61443df (correction; old attempt released) |
| 01-06 | Truthful reset notifications and dedupe | Spec commands and review dispositions | 01-01 | Services + locales + Notification harness | L2 | luna | in_progress | task_5c27e42e6aa0 | ctx_89a020aa8df3 |
| 01-07 | Race-safe watchdog observation | Spec commands and review dispositions | 01-01 | orchestrate.py + test_tools.py | L2 | luna | review | task_e31c44a002be | ctx_b92860eb293a |

Wave 1: 01-02, 01-05, 01-07; wave 2: 01-04, 01-06 after capacity/ownership permits. Each lead uses at most one nested Luna concurrently for this wave. Merge 01-02 first to install generic standalone harness acceptance.

Follow-ups: 01-08 (actual Task task_56626dbf6dd8, ctx_1ac40ed03b92) fixes measured-usage reset detection after unrelated publication; 01-09 (actual Task task_23f64509577c, ctx_0bd2a6e449f1, released) records the SQLite cleanup correction. These map native follow-up Tasks, not new Tasks hiding failures.
