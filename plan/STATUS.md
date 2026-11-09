# Project status

Run: none (stage 02 used the owner-approved OpenCode CheapVibeCode override)
Stage: 02-cheapvibecode-balance
State: complete — implementation, acceptance, Kimi review and merge pushed

## Active

<!-- active:start -->
No active dispatches.
<!-- active:end -->

## Queue

No approved work remains. Stage 02 delivered the CheapVibeCode remaining token
balance in all widget sizes and the app panel, with the API key in macOS
Keychain and VPN-independent refresh. See
`plan/02-cheapvibecode-balance.md`, `plan/specs/02-01.review.md` and
RESULTS.md.

Stage 00 established the workflow; stage 01 completed the whole-project review,
confirmed fixes and responsive limits refresh.

## Validation

Stage 02 checkpoints: `7d8978b` implementation and `01ae6d9` Kimi review fixes.
Full acceptance passed twice after integration: 22 tooling tests,
balance/notification/process/refresh/usage-reader harnesses, universal app and
widget builds, resource lint, and signatures. Kimi `kimi-k3` max found no
blockers or majors; three minors were fixed/reconciled and re-checked clean.

The owner directed OpenCode/CheapVibeCode agents instead of Orca, GPT models at
high effort, GLM 5.3 max for the lead work, and Kimi for review.
`gpt-6.1-terra` was not available from the provider; `gpt-6.1-sol` and
`gpt-5.6-terra` were the nearest catalog options. Live API, installed-widget
visual, Keychain re-prompt, wrong-key, and live VPN checks were not performed
and are not claimed.

Stage 01 archive: all eight Tasks in the main Run are completed. The
reclaimable list is empty. Actual worker/reviewer owners were released; five
child worktrees and branches were removed. Native follow-ups: 01-08 =
task_56626dbf6dd8 / ctx_1ac40ed03b92; 01-09 = task_23f64509577c /
ctx_0bd2a6e449f1. Parent IDs are not successor IDs.

## Recovery

1. Read PLAN.md, WORKFLOW.md, TESTING.md, HANDOFF.md and the relevant stage/spec.
2. Resolve Orca and load its version-matched orchestration guide.
3. Inspect run-list and, if resuming this historical Run, run-use --id
   run_0007adffba77, task-list --run run_0007adffba77 --json, and worker-list
   --run run_0007adffba77 --json (follow pagination).
4. Recover mail through inbox --terminal run:run_0007adffba77 --limit 50 --full.
5. Inspect exact worker-show/worker-read and receipts before recovery. A retained
   ownership_transferred predecessor does not own its successor's live process.
6. For a new objective, clarify, commit its plan and wait for user approval;
   then use the owner-approved launcher (Orca by default, or an explicit
   OpenCode/CheapVibeCode override). Do not relaunch completed stage 01 or 02
   merely after compact.
