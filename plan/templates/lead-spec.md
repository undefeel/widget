# <ID> — <English title>

Level: L3
Executor: terra
Status: todo
Dependencies: none
Orca task_id: pending
Dispatch ID: pending
Execution failures: 0

## Target

Complete user-visible outcome and current architecture/context.

## Change

Exact modules, public interfaces, invariants and required behavior. Explain the
design decisions delegated to the lead within the approved architecture.

## Constraints

- Follow plan/TESTING.md.
- English agent communication; preserve product localization.
- No architecture/stack changes without owner approval.
- Enumerate concurrent entry points and failure paths; no data deletion on
  transient storage errors. Keep valid alternatives passing acceptance.

## Ownership

Exact file paths, related data/content, and excluded shared files.

## Risk list

Applicable disk/deletion, concurrency or protocol risks, or `none`.

## Observable acceptance

Command: `plan/tools/accept.sh`. Add focused commands and 1–3 scenarios only
for risk-list areas. Full acceptance once after all pieces, before commit.

## Lead workflow

1. Commit `plan/specs/<ID>.plan.md`: files, functions, signatures, invariants,
   tests and ordered pieces, each at most 300 lines in 1–3 files.
2. Never finish your turn while a nested worker is pending. Orca does not
   reliably wake nested coordinators. Remain available, wait through
   `plan/tools/lead.sh --wait-all <dispatch...>`, handle questions and resume.
3. `lead.sh <ID> implement` starts a sequential piece from the committed plan.
   For parallel work, `lead.sh <ID> part <name> <part.md>`; at most three
   concurrent parts with disjoint file ownership. Parts do not commit and run
   only focused checks. The lead validates integration and commits.
4. The wait helper nudges only workers proven idle with no result, at most three
   continuations. Unknown/human-wait states require inspection, never restart.
5. Run focused checks after each piece. After two unsuccessful implementations,
   finish the piece yourself. Shrink the second attempt when appropriate.
6. After full acceptance/commit, run Gemini with `self-review.sh <ID>`, then
   personally inspect the full diff. Use at most two small fix rounds through
   `lead.sh <ID> fix <N> <notes-file>`. Large omissions become another piece.
7. Complete unresolved work yourself. Send `worker_done` only after all children
   settle, with commits, tests, review findings/dispositions and open blockers.
