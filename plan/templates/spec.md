# <ID> — <English title>

Level: L1 | L2
Executor: luna
Status: todo
Dependencies: none
Orca task_id: pending
Dispatch ID: pending
Execution failures: 0

## Target

Describe the user-visible outcome and relevant baseline. This spec must be
self-contained; the worker is not expected to discover missing requirements.

## Change

List exact paths, functions, behavior and any ready-to-use product wording.
Specify integration, data/resource updates, and valid alternative behavior.

## Constraints

- Follow plan/TESTING.md.
- Use English for all agent communication. Preserve product localization.
- Do not change the approved architecture or dependencies.
- Implement only this spec; ask when ambiguous.
- Enumerate all competing paths if there is concurrency; prefer per-entity
  locks. Temporary storage failures must not delete data.

## Ownership

Exact editable files, including related data/content/resources. List shared
files that are explicitly excluded and coordination needed for them.

## Risk list

List applicable disk/deletion, concurrency and protocol risks, or `none`.

## Observable acceptance

Command: `plan/tools/accept.sh` (one full run before commit).
Add focused commands and, only for applicable risk areas, 1–3 observable test
scenarios. Record manual checks and platform limits honestly.

## Self-review

After passing acceptance, commit and run `plan/tools/self-review.sh <ID>`.
Wait using `plan/tools/wait.sh`, inspect the report using `worker-read`, release
the settled reviewer, and record findings/dispositions. Address blocker/major
(minor when cheap); reject findings only with reasons grounded in this spec or
owner decisions. At most two fix rounds. If blocker/major remain in the second
Gemini round, run `plan/tools/self-review.sh <ID> luna`; also fall back to luna
after two Gemini startup failures. Unresolved valid findings mean failure.

Report with Orca `worker_done` from this exact Task/Dispatch: commits, changed
files, acceptance evidence, all review findings/dispositions and open blockers.
