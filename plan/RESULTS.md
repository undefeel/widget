# Stage 01 results

Completed 2026-11-06. User-approved scope: whole-project review (primarily Gemini
high), confirmed fixes, and faster manual limits refresh.

## Delivered behavior

- Each due provider publishes as soon as its result is ready. Slow unrelated
  providers and token statistics no longer hold back ready limits.
- Statistics run independently on their own interval. Manual limits refresh does
  not force another scan or duplicate one already running.
- Current-snapshot merging, generation fences and completion VPN checks preserve
  newer unrelated data and pause state. Physical work guards prevent duplicates.
- Successful provider requests and idle ticks avoid redundant fallback log scans.
  Unchanged payloads are not persisted and unchanged menu content is not rendered.
- Mutable SQLite conversations use normal read-only WAL coordination and literal
  filenames; failed initialization closes its handle exactly once.
- Subprocess stdin closure cannot SIGPIPE the app; transport and child cleanup
  are bounded. Codex replies accept valid JSON field order/whitespace and reject
  unrelated/partial records. Shell lookup arguments are literal.
- Reset notifications report actual usage, detect real forward window boundaries
  and preserve old measured usage across unrelated publications. Dedupe eviction
  uses numeric reset timestamps.
- Watchdog filesystem races no longer abort mailbox waiting or infer false idle.
  Existing-worktree addenda, native follow-up identities and ownership-transfer
  handling are documented explicitly from observed runtime behavior.

## Evidence

Main integration checkpoints: 23d6871 (refresh), 5a8988f (watchdog), 8b28dfc
(process/JSON-RPC), d6f8147 (SQLite), 663a101 (notifications and final acceptance).
All code is reachable from main; subsequent completion commits change docs only.

At final integration, plan/tools/accept.sh passed:
- 22 executable fake-Orca/Git/shell tests.
- Tests/run-notifications.sh (isolated preferences and fake sink).
- Tests/run-process.sh (synthetic subprocesses and JSON-RPC records).
- Tests/run-refresh.sh (production Store with injected synthetic I/O).
- Tests/run-usage-reader.sh (temporary WAL, literal paths, busy/missing files,
  and failed-initializer close ownership).
- Resource/localization checks, universal arm64/x86_64 application and widget
  compilation, and deep strict signature verification.

Controlled limits-first publication was 6–7 ms while statistics remained held;
the harness also holds a slow provider and verifies fast-provider publication.
This is synthetic dependency/order evidence, not a real upstream latency claim.
No real provider CLI/history was used for automated checks. No installed app was
changed or launched and no interactive UI/VPN/sleep-wake checks were claimed.

Gemini high performed the initial audit and implementation reviews. Terra led
01-02 and 01-04 and inspected their full diffs. Orchestrator review validated
findings and caught the SQLite failed-init and notification integration cases;
both received regressions and fresh clean Gemini reviews. Task-specific review
reports preserve dispositions, including rejected/defensive minor observations.

## Cleanup

All eight main-Run Tasks, including two native follow-ups, reported completed.
The main Run's reclaimable worker list is empty. Actual successor-owned terminals
were released before worktree deletion; historical ownership_transferred aliases
were not mistaken for process exits. Five task worktrees/branches were removed.
