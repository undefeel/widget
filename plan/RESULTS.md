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

# Stage 02 results

Completed 2026-11-09. Owner scope: show the remaining CheapVibeCode token
balance from the portal in all three "Лимиты AI" widget sizes and the app panel.

## Delivered behavior

- `GET https://ru.cheapvibecode.ru/v1/balance` with a Bearer API key returns the
  base token balance. The key is entered in Settings > Баланс and stored only
  in macOS Keychain; it is never written to `snapshot.json`, defaults, logs,
  URLs, errors, or widget data.
- The application refreshes the balance at launch, after wake, on manual
  refresh, and every five minutes, independently of the provider VPN gate.
  Provider limit and usage behavior is unchanged.
- One balance request runs per credential generation. Stale completions are
  discarded, current snapshot data is merged, and a failed request preserves
  the last successful tokens and timestamp while exposing a localized error.
  Deleting the key clears the balance, persists the snapshot, and reloads
  widgets.
- Small, medium, and large widgets show a compact balance footer. The panel
  shows a balance card with exact grouped tokens, update age, and error. The
  small widget omits the long "Остаток" label to avoid clipping.
- HTTP errors keep their status code in `BalanceStatus.errorCode`, so English
  and Russian locales format the message at display time.
- Old `snapshot.json` files without `cheapVibe` decode unchanged.

## Evidence

Implementation `7d8978b`; review fixes `01ae6d9`.

Full `plan/tools/accept.sh` passed twice:
- 22 tooling tests;
- `Tests/run-balance.sh`, `run-notifications.sh`, `run-process.sh`,
  `run-refresh.sh`, `run-usage-reader.sh`;
- universal arm64/x86_64 application and widget builds;
- plist/localization/entitlement lint and deep strict signature verification.

The balance parser harness covers numeric and numeric-string values, extra
fields, Int.max, negative/fractional/missing/malformed/garbage input, 401/403,
429, 500, and old snapshot decoding. The refresh harness covers VPN-off balance
publication, non-blocking/deduped requests, failure preservation, and
credential invalidation.

## Review and process

The owner directed OpenCode agents on provider CheapVibeCode instead of Orca,
GPT models at high effort, GLM 5.3 max for lead work, and Kimi for the final
review. The requested `gpt-6.1-terra` and `kimi-k3.1-pro` are not present in
the provider catalog; `gpt-5.6-terra`/`gpt-6.1-sol` and `kimi-k3` max were the
nearest available options.

GLM 5.3 max lead review found one major parser-prefix defect and two minor
Keychain issues; all were fixed and re-checked. Kimi K3 max found no blockers
or majors, three minors were fixed/reconciled, and the re-check was clean. See
`plan/specs/02-01.review.md` for the finding dispositions.

## Manual checks not performed

Live fetch with the owner's key, all three installed widget sizes for clipping,
wrong-key behavior, live VPN-off continuity, and the Keychain re-prompt after
an ad-hoc rebuild remain manual macOS checks. No installed app was changed or
launched by automated acceptance, and no interactive UI check is claimed.
