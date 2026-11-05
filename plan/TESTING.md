# Verification policy

Every code spec must say: **Follow plan/TESTING.md**.

## Risk-based tests

Name 1–3 observable test scenarios in the spec only for relevant risks:
filesystem writes/deletion, concurrency, and protocols. Examples include safe
snapshot replacement, competing refreshes, CLI JSON-RPC handling, or shell
argument transport. Other changes need appropriate build/manual checks without
inventing test scenarios. Do not add implementation-mirroring tests for simple,
reversible presentation or text changes.

- During implementation, run only focused checks for owned changes.
- Run complete acceptance once before the implementation commit. The merge
  helper runs complete acceptance once after the integration merge.
- A lead runs focused checks per piece, and full acceptance after all pieces.
  Parallel pieces do not run full builds or commit shared working-tree changes.
- Never weaken/delete existing tests unless the spec expressly permits it.
- Execute shell tools against stubs: verify arguments, exit status, side effects,
  mail handling, and failed receipts; searching their source is not a test.
- Performance measurements belong only in performance tasks.
- Reviewers may request only the tests called for by the spec and this policy.

## Current project commands

Full acceptance: `plan/tools/accept.sh`.

This runs whitespace checks, Python tooling checks and executable stub tests,
shell syntax checks, plist/resource validation and, on macOS, `./build.sh` plus
signature verification. The full build compiles both the application and widget
for arm64 and x86_64. A non-macOS host exits unsuccessfully for full acceptance;
`plan/tools/accept.sh --tools-only` explicitly checks only portable tooling.

There is no configured Swift unit-test runner, Swift linter, or frontend.
Do not claim those ran. Do not introduce a new test/build architecture without
owner approval. Focused Swift checks should use compiler commands from
`build.sh`, with temporary outputs, or a targeted standalone harness specified
by the task. `-run` in the general operating model means the equivalent narrow
filter of an existing runner, not a Go command in this repository.

Application/widget UI, notifications and VPN behavior may need manual checks in
a logged-in macOS session. Record what was actually observed. Acceptance never
installs, launches the app, changes user preferences, reads usage logs, or runs
real agent CLIs. Build scripts generate icons from installed app bundles.

When changing numbers/rules, search all related source, README, localizations and
plan references. Update product text/data together. Protocol tests must allow
valid alternative representations; race tests must enumerate competing paths.

Preserve pipeline failures when tailing output: use `set -o pipefail`, or capture
the complete output to a temporary file, print its last 40 lines, and propagate
the original exit code.
