# Orca operating procedure

## Bootstrap and compatibility

Read `AGENTS.md`. The initial configuration is prepared in the current session;
no product Run or agent is started by installation or tests. Subsequent work
uses the exact roles and gates in that contract.

The helpers require Bash, Python 3 and Git. Python dependencies are standard
library only. Resolve Orca once per session: `ORCA_CLI_COMMAND` when set,
otherwise `orca-dev` when `ORCA_DEV_REPO_ROOT` is set, otherwise `orca-ide` on
Linux or `orca` on macOS. An override is one executable path, not a shell command.
Never fall back to a different executable after an error.

Before the first launch, load that executable's
`skills get orchestration --full`. Current CLI behavior verified at bootstrap:

- `worker-start --comment` is allowed only for a newly created worktree.
  `start.sh` additionally sends addenda using `orchestration send`, including
  retries into existing worktrees.
- `check --peek --wait` observes without consuming mail. `wait.sh` deliberately
  prints the returned batch and never acknowledges it. The coordinator processes
  the whole batch with its own consuming `check`; recover lost mail via inbox.
- New-child workers use explicit `--base-branch origin/main` and `--setup skip`;
  this repo has no setup hooks. No raw `git worktree` creation.
- Same-worktree reviewers are read-only by instruction. Orca worker-start has
  no read-only sandbox flag. The helper fingerprints HEAD and nonignored files
  (except STATUS) and checks them on `lead.sh --wait-all`; this detects edits,
  it is not an OS security boundary. Do not edit the checkout during a review.
- Structured/chat agents do not always expose a proven idle state. The watchdog
  nudges only a terminal-backed worker with an explicit satisfied idle probe,
  no human wait, unchanged files for at least ten minutes and no active child.
  Otherwise it leaves the assignment intact for inspection. No silence-based
  cancellation, release, retry, or worktree deletion.

## Prepare a wave

1. Clarify the new product idea with the user. Write a numbered subplan using
   the fields in `PLAN.md`. Choose L1–L4, scope and owners. Commit `plan/`; wait
   for the user's `ok`. No extra approval is needed after that for its execution.
2. Synchronize the primary `main` checkout with `origin/main`.
3. Create a Run: `orca orchestration run-create --objective "<English goal>"`.
   Record its exact Run ID in `STATUS.md` as `Run: <run_id>`.
4. Create immutable Tasks with `task-create --run <run_id> --spec-file
   plan/specs/<ID>.md --task-title "<English title>" --deps '["<task_id>"]'
   --json`. Use `[]` when independent. Append `<ID> <task_id>` to
   `plan/specs/orca-task-ids.txt`; update the subplan and commit.
5. Inspect `task-list --run <run_id> --ready --json`. Launch ready independent
   tasks with `plan/tools/start.sh <ID> luna` or `... terra`. Its stdout includes
   `<ID> <dispatch>`. STATUS is updated automatically; complete exact workspace
   paths from worker-show, stage fields and execution status yourself.

`start.sh` supports luna, luna-low, terra, sol, sol-low, sol-high as executor
labels; these map to the full model IDs in AGENTS.md. Low/high sol and luna-low
are explicit exceptions only when the approved spec calls for them. L3 requires
terra; L4 never auto-dispatches. The task must already exist in the approved Run.
The helper guards a global five-implementation limit through shared Git runtime
reservations, including nested launches made by these helpers. Do not bypass it
with raw worker-start; inspect externally created agents before starting a wave.

## Wait and answer

`plan/tools/wait.sh [timeout_ms]` defaults to 540000 ms and performs one blocking
peek, not a polling loop. Run long waits with the environment's background/yield
facility, keeping output available; a consuming mailbox watcher is forbidden.
Keep the user informed at least once per minute while actively supervising.

Process all returned messages. Answer questions using
`orca orchestration reply --id <message_id> --body "<English answer>"`.
Orca is not restarted if a timeout returns no mail. A lead waiting on nested
workers remains in its turn; `lead.sh --wait-all <dispatch...>` returns 75 when
mail needs handling, then must be resumed. A nonzero result other than 75 means
inspect failures; it does not authorize ending a turn with unfinished children.

The watchdog is evaluated at the beginning/end of the blocking wait. Its
ten-minute threshold is a minimum, not a precision timer. At most three proven
idle nudges are sent through `orchestration send`; it never steers the terminal.
Human waits and agents without idle proof need inspection. Leads handle a
worker that exhausted its continuation budget by the normal two-failure policy.

## Lead and review

Use the exact workflow in `templates/lead-spec.md`. Commit the complete lead
plan first. `lead.sh <ID> implement` reads the next explicitly pending piece;
mark pieces unambiguously. Parallel pieces use
`lead.sh <ID> part <name> <part.md>`; the lead must verify disjoint ownership
before launch. `lead.sh <ID> fix <1|2> <notes-file>` handles small review fixes.
All nested implementation workers share the lead checkout and never commit.
The lead owns integration, full acceptance and commits.

`self-review.sh <ID> [luna]` starts a reviewer in the same checkout and prints
its Dispatch. No Gemini effort flag is supplied; its exact model is
`gemini-3.8-flash-high`. Wait and verify the fingerprint through
`lead.sh --wait-all <review-dispatch>`; this wait is usable by L1–L2 workers too.
Use `worker-read --dispatch <id>` for the complete report if the bounded report
was truncated. Save findings and dispositions in `plan/specs/<ID>.review.md`.
Release settled reviewers before proceeding. The helper's private review Run
keeps nested mail separate; use the parent Dispatch's exact preamble when
sending the final worker_done to the original coordinator.

For an explicitly approved whole-project audit, create/map a read-only review
Task first, then use `review.sh <ID> [luna]`. Unlike self-review, it launches the
existing mapped Task in the main Run. Its immutable spec must contain
`Read-only` and `Review base:` with the exact audit range and reporting rules.
No implementation agents may edit the checkout during the audit. Wait and
verify its fingerprint through `lead.sh --wait-all` as with self-review.

Two Gemini startup failures trigger a luna review. Never count those as two
implementation failures. A first-pass clean Gemini review is followed by terra's
own full read on L3. For L1–L2 the requested control-review trigger is remaining
blocker/major findings in the second Gemini round. Valid unresolved findings
must be fixed or reported failed, even if another reviewer overlooks them.

## Merge and cleanup

Read the stat first, inspect relevant patches, review report and acceptance
evidence. Bring the review report into the integration checkout and commit plan
updates. Then run `plan/tools/merge.sh <ID> <worker-branch>` from clean `main`.
This serially ff-syncs main, merges with `--no-ff`, runs full acceptance once,
records STATUS and pushes `HEAD:main`. A conflict/test/push failure stops in
place with evidence; no automatic reset/abort or claim of successful publication.
The primary checkout is main already, so no second checkout needs a separate ff.
If integrating elsewhere, do not run this helper: first return to primary main.

Record `done` in the stage after successful acceptance/merge, commit/push plan
state. Then inspect the exact Dispatch and call
`orca orchestration worker-release --dispatch <id>`. A zero exit is not enough:
`release_pending`, `release_unknown` and `retained` need their receipt's next
action. Never remove a checkout while its owned process is unproven/live.
Only after proven cleanup:
`orca worktree rm --worktree path:<exact-path> --delete-branch --json`.
Update STATUS after release/removal. Paginate `worker-list --run <run_id>
--terminal-state reclaimable --json`; it must be empty before stage completion.

## Recovery and artifacts

Follow `STATUS.md`. Raw receipts are in ignored `plan/.runtime/`. The shared Git
directory's `orca-plan-runtime/` holds repository-wide launch reservations and
Dispatch records, so child worktrees share capacity accounting. These are local
recovery evidence, not a substitute for the tracked plan or Orca state.

`unresolved-start.json` blocks further launches after an unknown/failed mutation.
Inspect its exact command, saved receipt and worker-show/worker-read. Reconcile
the Dispatch into the registry and STATUS before removing that reservation.
For a proven readiness failure, release only as directed by the receipt, then
`RETRY_OF=<dispatch> plan/tools/start.sh <ID> <same-role> path:<same-worktree>`.
Never retry a lost launch as a fresh request; use its exact `--retry-request`
when the receipt provides one. Stop at the three-start circuit breaker.

New Task specs are immutable. Put scope corrections/fix instructions in
`plan/specs/<ID>.addendum.md`, commit, and retry the same Task with the addendum.
Wrong specs and missing ownership are specification errors, not execution
failures. Track actual red acceptance/rejected review failures separately.

Before a retry into an existing worktree, synchronize the current task spec and addendum as plan-only commits in that checkout. Confirm its AGENTS contract requires reading local addenda before work. A queued post-start send alone is insufficient proof that the correction entered the implementation context; require explicit disposition in the report. Preserve old runtime receipts, but archive a stale helper-Run cache before launching a new agent in the same checkout.


## Native follow-up identity and custody

A send to a settled worker can return delivery=follow_up with a NEW Task and
Dispatch. Use those exact IDs from the receipt/current preamble, never combine
the parent's task_id with the successor dispatch_id. Record runtime-created
follow-ups under a local tracking ID and keep their parent artifact relationship
explicit. Reconcile them into shared capacity records before launching more work.

A release result ownership_transferred is not a stop confirmation. The successor
may still be implementing in that checkout. Inspect worker-list/worker-show and
retain one implementation owner; do not launch a parallel writer because the
predecessor's assignment settled. Release the actual successor after it reports.

If a review fingerprint changes, inspect both uncommitted changes AND the full
reviewed-commit-to-HEAD range. A claim that only STATUS is dirty does not explain
a HEAD change. Rerun review for changed product/test code; explicitly record any
manual verification that only coordination/report commits changed and the reviewed
source/test tree stayed identical. Never call that a successful automated
fingerprint certification.
