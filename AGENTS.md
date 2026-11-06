# Project agent contract

This repository uses Orca with a Codex orchestrator, Codex leads/workers, and a
Gemini first-pass reviewer. Read `plan/STATUS.md`, `plan/PLAN.md`,
`plan/WORKFLOW.md`, and `plan/TESTING.md` before working. `plan/` is the source of
truth for scope, decisions, ownership, task state, and recovery.

## Language and roles

- Speak Russian with the user. All Orca specs, plans, addenda, questions,
  replies, reviews, reports, and inter-agent messages must be English.
- Preserve the product's Russian/English localizations. The exclusion of Claude
  concerns development agents; it does not remove Claude support from AILimits.
- Orchestrator: `gpt-6.1-sol`, medium; plans, specs, dispatch, acceptance, merges,
  STATUS. Do not implement product code except small merge repairs (typos,
  imports, configuration).
- L3 lead: `gpt-6.1-terra`, medium; owns the complete task in its own worktree,
  writes a committed plan, delegates small pieces, reviews and finishes them.
- Worker: `gpt-6-luna`, high; implements the exact spec, asks about ambiguity,
  makes no independent architecture decisions.
- First review: `antigravity`, `gemini-3.8-flash-high`, read-only.
- Control review: `codex`, `gpt-6-luna`, high, read-only.
- Use full provider model IDs. Launch agents only through Orca, never internal
  subagents or direct provider CLIs. No Claude development agents.

## Planning gates

For a new product idea, clarify first, write and commit the plan, then wait for
the user's approval before execution. Classify every task before launch:

| Level | Scope | Owner |
| --- | --- | --- |
| L1 | Local, obvious change with an example | luna |
| L2 | Fully specified logic in 1–2 modules | luna |
| L3 | Design choice, cross-module effects, concurrency, migrations, security, shell generation, unclear bug | terra lead, luna pieces |
| L4 | Subsystem architecture or failed L3 | sol analysis, then stop and ask user |

L1–L2: approximately 800 changed lines and 10 files in one subsystem. L3:
approximately 1,500 lines, split into pieces of at most 300 lines in 1–3 files.
Prefer complete vertical slices; split only when necessary or truly independent.
At most five implementation agents across the repository, including nested
leads/workers. Reviewers are excluded. A lead can have at most three parallel
luna pieces, with disjoint file ownership.

## Execution and review

- Before implementing an assigned Task, read the current checkout's
  `plan/specs/<ID>.md` and every existing `<ID>.addendum.md`. The Orca Task
  brief is immutable and may predate owner corrections. Addenda are mandatory;
  the final report must explicitly state their disposition. Do not rely solely
  on a previously completed implementation or a previous review artifact.
- Follow `plan/WORKFLOW.md` and the version-matched Orca skill. Resolve the CLI
  as specified there; inspect `skills get orchestration --full` and command help
  when flags differ. Do not invent flags or bypass a circuit breaker.
- Every code spec uses the template in `plan/templates/`, includes exact paths,
  generous Ownership, `Follow plan/TESTING.md`, and observable acceptance.
- Leads must not finish a turn while nested workers are pending. Wait visibly
  through `plan/tools/lead.sh --wait-all`; process questions and resume waiting.
- L1–L2 workers commit passing implementation, run Gemini self-review, address
  blocker/major findings in at most two fix rounds, and report dispositions.
  Run the luna control review if blocker/major remain in Gemini's second round;
  also use luna after two Gemini startup failures. Unresolved valid findings
  mean failure, not success. Escalate after two execution failures.
- L3 leads run Gemini, personally inspect the full diff, and fix or delegate
  small corrections in at most two rounds. After two failed pieces, finish the
  implementation themselves. Large omissions are new pieces, not fix rounds.
- Reviewers never edit, commit, launch agents, or demand tests beyond the spec.
- A native `send` to a settled worker can create a new follow-up Task and
  Dispatch. Report with the actual current preamble identities; parent IDs are
  context only. Reconcile the receipt into plan state and shared capacity records.
- A release receipt `ownership_transferred` does not prove process exit or permit
  another writer in the checkout. Inspect the successor Dispatch before any
  relaunch; keep one implementation owner per checkout.
- Use `worker_done` with explicit success/failure and evidence, commits,
  acceptance results, review findings/dispositions, and remaining blockers.
- Read `git diff --stat` first, then relevant patches. Never merge an unseen
  Codex diff. Tail noisy validation output to 40 lines, preserving exit status.
- Merge serially through `plan/tools/merge.sh`; update plan state, push to main,
  release settled workers, then safely remove their Orca worktrees. Do not
  delete a worktree based on silence or unverifiable liveness.

## Escalation and stops

Two failed executions on the same valid spec escalate luna → terra → sol →
stop and ask. Readiness failures, wrong specs, and silence are not execution
failures. Inspect commits, `worker-show`, and `worker-read` before recovery.
Retry startup on the same Task/worktree using `RETRY_OF`; preserve receipts.
After three chained startup failures, stop. Never create a new Run/Task to
bypass the breaker.

Ask the user before changing architecture/stack in `PLAN.md`, obtaining secrets,
keys or paid services, proceeding past the last escalation, or recovering a
circuit-broken Task. Do not invent additional approval gates.
