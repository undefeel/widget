# Project status

Run: run_0007adffba77
Stage: 01-review-refresh (approved)
State: 01-07 accepted; 01-05 held for final ownership correction; 01-02 and 01-04 leads running

## Active

<!-- active:start -->
- 01-01 | ctx_0ceb147c0f1e | gemini | 5d316412-736b-46fe-885e-79824b4fafce::/Users/kodoku/Work/widget
- 01-02 | ctx_99d5e019e7a8 | terra | 5d316412-736b-46fe-885e-79824b4fafce::/Users/kodoku/orca/workspaces/widget/t01-02
- 01-05 | ctx_6f9f96cdcdec | luna | 5d316412-736b-46fe-885e-79824b4fafce::/Users/kodoku/orca/workspaces/widget/t01-05
- 01-07 | ctx_b92860eb293a | luna | 5d316412-736b-46fe-885e-79824b4fafce::/Users/kodoku/orca/workspaces/widget/t01-07
- 01-04 | ctx_052bb5219b06 | terra | 5d316412-736b-46fe-885e-79824b4fafce::/Users/kodoku/orca/workspaces/widget/t01-04
- 01-06 | ctx_89a020aa8df3 | luna | 5d316412-736b-46fe-885e-79824b4fafce::/Users/kodoku/orca/workspaces/widget/t01-06
<!-- active:end -->

## Queue

Stage 00 is complete: 20 executable stub tests, universal macOS application and
widget build, resource checks and codesign verification passed.

The user requested a whole-project Gemini high review, confirmed fixes, and
faster limits refresh independent of statistics. Scope clarification received:
review the entire project, prioritize limits refresh.

Read `01-review-refresh.md` and specs `01-01.md` / `01-02.md`. User approved this plan on 2026-11-06. Execute without another approval gate. Further confirmed audit fixes receive
their own exact specs after triage; no catch-all implementation Task exists.

Read `HANDOFF.md` after a context compaction. Do not claim a compact occurred
unless the interface actually performed it.

## Recovery

1. Read this file, `PLAN.md`, the stage subplan and relevant specs/addenda.
2. Resolve the Orca executable and load its current orchestration skill.
3. Run `orca orchestration run-list --json`, then, for the Run recorded above,
   `orca orchestration run-use --id <run_id>` and
   `orca orchestration task-list --json`.
4. Inspect `orca orchestration worker-list --run <run_id> --json`, following
   pagination. Inspect individual `worker-show` / `worker-read` receipts before
   any retry/release. Silence does not prove exit.
5. Recover mail using
   `orca orchestration inbox --terminal run:<run_id> --limit 50 --full`.
6. Inspect `plan/.runtime/` receipts and shared Git runtime reservations if a
   launch was interrupted. Reconcile exact Dispatch IDs; do not relaunch blindly.
7. Update this file after each launch, merge and release. Before finishing an
   execution stage, the Run's `worker-list --terminal-state reclaimable` must be
   empty, or record the specific unresolved cleanup blocker.

Audit 01-01 completed; ctx_0ceb147c0f1e released with closed_agent_terminal receipt.

Wave 1 launched: refresh lead, WAL reader fix and watchdog fix. Next: 01-04 and 01-06 when capacity permits; 01-02 integration first.

01-05 and 01-07: passing worker acceptance and clean Gemini reviews; diffs inspected, awaiting 01-02-first integration. 01-04 started as ctx_052bb5219b06.

01-05 final root review found double-close on failed init; bounded addendum prepared. Old successful report is not final acceptance. 01-06 started as ctx_89a020aa8df3.
