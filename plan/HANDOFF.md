# Session handoff

## Completed

- Project uploaded to `git@github.com:undefeel/widget.git`, main, initial product
  commit `f57193f` (existing remote README history preserved).
- User requested a Codex sol orchestrator, terra L3 lead, luna workers, Gemini
  first-pass reviewer, Orca-only operation, English agent communication and Russian
  user communication. This is recorded in AGENTS.md and plan/WORKFLOW.md.
- Bootstrap includes planning/testing documents, spec templates, start/lead/
  self-review/review/wait/merge/accept entrypoints and executable fake-Orca tests.
- Universal arm64/x86_64 macOS app/widget build, resources and signatures passed.
  Tooling checks use disposable Git repos/local bare remotes and launch no agents.

## Latest user steering

After bootstrap: compact, review mainly with Gemini high, fix findings, and speed
up limits refresh on button click. The user explicitly clarified: review the
whole project, prioritize limits refresh. They permit separating statistics or
running it in background so it does not delay limits.

No exposed tool can compact this root session directly. `/compact` is a user
interface command; do not report it as done merely because this handoff exists.
The saved files allow safe continuation after the user invokes it.

## Prepared work and gate

`01-review-refresh.md` is the concrete stage plan. `01-01.md` is a whole-project
read-only audit spec for `gemini-3.8-flash-high`; `01-02.md` is a terra-led refresh
implementation spec. No Run/Task/Dispatch has been created for that stage.

The user's workflow explicitly requires committing a new plan and waiting for
their `ok`. Do not start stage 01 until that approval arrives. An approval after
compaction applies to this prepared plan; do not ask for the same approval again.

## Source evidence

`Sources/App/Store.swift` starts CLI requests, local fallback reads and usage
scan concurrently, then awaits all in one tuple before publishing. force:true
forces statistics too. A single isRefreshing guard spans everything. Both
Popover's refresh button and App.refreshNow call refresh(force:true).

The proposed implementation separates limits and usage lifecycle/publication,
preserves VPN gating and intervals, and fences late updates to avoid overwriting
new state. Real provider CLI latency may still dominate; the plan asks for
controlled fake-data latency/order evidence, not an invented external speedup.

## Next actions after approval

1. Read STATUS/PLAN/WORKFLOW/TESTING and current Git state; no speculative memory
   lookup is needed. Resolve Orca and load its version-matched orchestration skill.
2. Create the main Run, Tasks with dependencies, map task IDs and commit/push the
   plan. Use `review.sh 01-01` for the mapped read-only audit Task; its spec gives
   the complete audit range. Wait via the non-consuming helper and inspect report.
3. Record/triage findings. Update exact specs/addenda. Dispatch terra for 01-02
   using start.sh from main synchronized with origin/main. Additional fixes need
   exact bounded specs, levels and ownership based on confirmed findings.
4. Follow acceptance/review/merge/cleanup rules. Report evidence and unresolved
   blockers. Do not install or launch the user's application unless asked.

## Tool caveats

`--comment` is only for new worktrees; retries receive addenda via send.
Mailbox observers use --peek. Review read-only mode is prompt-enforced plus a
checkout fingerprint, not an OS sandbox flag. Idle nudges require explicit
terminal evidence and never imply permission to stop/retry/delete anything.
Unknown launch outcomes retain a blocking shared-Git reservation for reconciliation.
