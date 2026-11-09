# Stage 02 — CheapVibeCode remaining token balance

Status: planned 2026-11-09; awaiting user approval. No Run, Task, or product
implementation exists for this stage.

User scope: show the remaining CheapVibeCode token balance from
<https://cheapvibecode.ru/portal/dashboard> in the AILimits macOS widget (all
sizes) and in the menu-bar panel.

Clarifications received:

- Show the balance in the existing "Лимиты AI" widget in small, medium, and
  large sizes, and in the application panel.
- Show tokens only. No ruble equivalent, percentage, or limit bar.
- Enter the API key in Settings and store it in macOS Keychain.
- Refresh the balance independently of the "request limits only with VPN"
  toggle.

## Evidence and current behavior

- The portal dashboard is authenticated HTML behind Cloudflare; an
  unauthenticated request receives 403. It is not a scraping target and no
  browser session or cookie should be reused.
- CheapVibeCode exposes `GET https://ru.cheapvibecode.ru/v1/balance` with
  `Authorization: Bearer <API key>`. Its response contains `token_balance` in
  base tokens. The public CheapVibeCode VS Code integration and third-party
  notes use this endpoint. Extra response fields must be tolerated.
- The exact successful response shape beyond `token_balance` is not documented
  publicly. It must be confirmed once with the owner's key during manual
  acceptance; that key must never appear in a test, report, command line, or
  repository file.
- The application performs provider requests and writes
  `~/Library/Application Support/AILimits/snapshot.json`. The sandboxed widget
  only reads that directory. Therefore the application owns the HTTPS request
  and Keychain access; the widget stays network-free and read-only.
- `Provider` is agent-specific: it drives CLI discovery, launch buttons, limit
  windows, percentages, and menu-bar rendering. CheapVibeCode is a single
  balance, so it must not become a fourth `Provider` case. It is a separate
  optional snapshot payload.
- `LimitsStore.refresh(force:)` currently returns before any work when VPN is
  off. Balance scheduling must run before that guard so the approved
  VPN-independent behavior is possible without changing provider behavior.
- The application is not sandboxed, so outbound HTTPS and Keychain access need
  no new application entitlement. HTTPS needs no App Transport Security
  exception. `Resources/Widget.entitlements` must remain unchanged.
- The approved baseline says no additional services, credentials, or paid
  infrastructure. This stage adds one optional external HTTPS source and one
  user-supplied secret. Approval of this plan authorizes that explicit
  exception; nothing else in the baseline changes.

## Intended outcome

- Settings gains a "Баланс" pane with an API key field, save and delete actions,
  a status line, and a link to the CheapVibeCode dashboard.
- The application refreshes the balance at launch, after wake, on manual
  refresh, and every five minutes. This happens even when the VPN gate pauses
  provider limits.
- `snapshot.json` stores the last successful token balance, its timestamp, and a
  localized error key. The widget renders the balance in all three sizes; the
  panel shows a balance card.
- A missing or invalid key never affects Claude, Codex, Antigravity, usage
  statistics, or notifications. The panel and Settings show the balance error;
  the widget keeps the last successful value.
- The API key is never written to `snapshot.json`, `UserDefaults`, logs, error
  text, widget data, or process arguments.

## Non-goals

- No ruble conversion, usage-per-period history, model catalog, key management,
  or top-up flow.
- No portal scraping, cookie/session authentication, or Cloudflare bypass.
- No change to provider limits, provider VPN behavior, notifications, usage
  scanning, menu-bar limit rendering, or existing provider intervals.
- No new package, service, dependency, widget entitlement, or build-system
  change.

## Technical design

### Shared model

Add to `Sources/Shared/Models.swift`:

```swift
struct BalanceStatus: Codable, Equatable {
    /// Last successful value. Kept when a later request fails.
    var tokens: Int?
    var updatedAt: Date?
    /// Localization key for the last failure, cleared on success.
    var error: String?
    /// Argument for a formatted key such as the HTTP status code.
    var errorCode: Int?
}

enum CheapVibeFetchResult {
    case success(tokens: Int)
    case notConfigured
    case failure(CheapVibeFailure)
    case cancelled
}

enum CheapVibeFailure {
    case unauthorized
    case rateLimited
    case network
    case invalidResponse
    case http(Int)
}
```

Add `var cheapVibe: BalanceStatus? = nil` to `Snapshot`. It is optional, so
existing `snapshot.json` files continue to decode. `Snapshot.empty` leaves it
`nil`. The widget preview supplies a synthetic balance.

The stored `error` is a Russian localization key, displayed through `L(...)`,
matching the project's existing key convention. Failure cases map as follows:

| Failure | Stored key |
| --- | --- |
| `unauthorized` | `Ключ CheapVibeCode недействителен` |
| `rateLimited` | `CheapVibeCode ограничил частоту запросов` |
| `network` | `Нет связи с CheapVibeCode` |
| `invalidResponse` | `Некорректный ответ CheapVibeCode` |
| `http(code)` | `CheapVibeCode вернул ошибку %d` |

### Keychain

Add `Sources/App/CheapVibe.swift` with:

- `CheapVibeKeychain.save(_:)`, `load() -> String?`, `delete()`, `hasKey()`.
- Generic-password service `dev.kodoku.AILimits`, account
  `cheapvibecode.api-key`, accessibility
  `kSecAttrAccessibleAfterFirstUnlock`.
- Add-or-update semantics; trimmed non-empty keys only; delete is idempotent.
- No logging of the key or response body.

The app is ad-hoc signed, so macOS may ask for Keychain access again after a
rebuild. Record that actual prompt during manual verification; do not treat it
as a product failure.

### HTTPS client

Add `CheapVibeClient.fetch() async -> CheapVibeFetchResult` in the same file:

- Fixed URL `https://ru.cheapvibecode.ru/v1/balance`; no user-editable base URL.
- `GET`, `Accept: application/json`, `Authorization: Bearer <key>`, and a
  product user agent. No query parameter contains the key.
- Ephemeral session with no cookies or cache, 10 s request timeout, 15 s
  resource timeout. Reject redirects so the bearer token cannot follow a
  redirect to another host.
- `200`: parse `token_balance` as a non-negative integer, also accepting a
  numeric string or an integral JSON number; ignore extra fields. Missing,
  negative, fractional, or non-numeric values are `invalidResponse`.
- `401`/`403`: `unauthorized`; `429`: `rateLimited`; other status:
  `http(code)`. Transport errors: `network`. Cancellation: `cancelled`.
- No automatic retries. Failures preserve the previous balance in the store.
- Expose the pure status/body parser for the standalone harness.

### Store integration

Extend `RefreshOperations` with test seams:

- `balanceConfigured: () -> Bool`
- `balance: () async -> CheapVibeFetchResult`

Live implementations use Keychain and `CheapVibeClient`. The refresh harness
adds compile-time stubs, as it already does for CLI fetchers, so no real
network or Keychain access is reachable from tests.

In `LimitsStore`:

- Constant `balanceInterval = 300` seconds.
- `startBalanceIfDue(force:)` is called at the very start of
  `refresh(force:)`, before `vpnPermitted()`. It starts at most one balance task
  per credential generation and never blocks provider or usage work.
- `lastBalanceAttempt` is set only when a request actually starts. If no key is
  configured, no network request or error is produced.
- `balanceGeneration` increments on save, replacement, or deletion of the key.
  A completion is applied only when its generation still matches. A stale
  completion cannot clear a newer in-flight marker or overwrite newer data.
- Saving a key cancels any old task, forces an immediate fetch, and refreshes
  the widgets after a successful publication. Deleting a key cancels work,
  clears `cheapVibe`, persists, and reloads widgets so the value disappears.
- Success sets tokens and `updatedAt`, clears the error, and publishes.
  Failure keeps the last tokens and timestamp, sets the error key (and the HTTP
  status code for the formatted error), and publishes. `notConfigured` leaves
  the last successful value; explicit key deletion clears it, so a transient
  Keychain failure cannot erase a good balance.
- `publish` includes `cheapVibe` in the change test. A balance-only update must
  not advance the limits freshness label (`generatedAt`); existing usage-update
  behavior remains unchanged.
- Every update starts from the current snapshot after the await, so a
  concurrent provider, pause, or usage publication cannot be reverted.

### Settings UI

Add `SettingsPane.balance` between "Агенты" and "Уведомления":

- Title "Баланс", symbol `creditcard.fill`, green accent.
- API key field is a `SecureField` bound to local `@State`; the saved key is
  never loaded back into the field or displayed.
- Status shows "Ключ сохранён" or "Ключ не задан"; the latest balance error is
  shown when present.
- "Сохранить" trims and stores the key, clears the field, and calls
  `store.balanceCredentialsChanged()`. "Удалить" removes the Keychain item and
  clears the visible balance.
- A `Link` opens the portal dashboard.
- Informational text: Keychain storage, five-minute refresh, VPN-independent
  behavior, and that the key is not written to `snapshot.json`.

### Panel and widget

- Add a compact `BalanceSection` to the main popover after the summary row and
  before provider sections. Show the brand, compact token amount, exact grouped
  amount in the help text, last-update age, and any error.
- Add one reusable `BalanceFooter` to `LimitsWidget.swift`:
  - small: divider plus a 9-point line with brand, compact amount, and icon;
  - medium: same footer below the three provider rings;
  - large: footer above the weekly usage line, with one shared divider.
- Show the footer only when `tokens != nil`. If the last fetch failed, keep the
  value and expose the error through help/accessibility rather than replacing
  the number.
- Use `.accessibilityElement(children: .combine)` with a localized label.
- Add a synthetic balance to `Snapshot.preview` so widget placeholders show the
  new line.
- Update the widget description to mention the CheapVibeCode balance in both
  localizations.
- Update `README.md`: data-source table row, Keychain setup, refresh behavior,
  and the three widget sizes.

### Localization keys

Add matching entries to `Resources/{ru,en}.lproj/Localizable.strings`:

- `Баланс` / `Balance`
- `Остаток: %@` / `Balance: %@`
- `Ключ CheapVibeCode не задан` / `CheapVibeCode API key is not set`
- `Ключ CheapVibeCode недействителен` / `CheapVibeCode API key is invalid`
- `CheapVibeCode ограничил частоту запросов` / `CheapVibeCode rate limit reached`
- `Нет связи с CheapVibeCode` / `Cannot reach CheapVibeCode`
- `Некорректный ответ CheapVibeCode` / `Invalid CheapVibeCode response`
- `CheapVibeCode вернул ошибку %d` / `CheapVibeCode returned error %d`
- `API-ключ` / `API key`
- `Сохранить` / `Save`
- `Удалить` / `Delete`
- `Ключ сохранён` / `Key saved`
- `Ключ не задан` / `No key set`
- `Открыть кабинет CheapVibeCode` / `Open CheapVibeCode dashboard`
- `Хранится в macOS Keychain; в snapshot.json и логи не попадает.` /
  `Stored in macOS Keychain; never written to snapshot.json or logs.`
- `Обновляется каждые 5 мин независимо от VPN.` /
  `Refreshes every 5 min regardless of VPN.`
- `Токены CheapVibeCode` / `CheapVibeCode tokens`
- `Лимиты Claude, Codex и Antigravity и баланс CheapVibeCode.` /
  `Claude, Codex and Antigravity limits plus the CheapVibeCode balance.`

## Ordered work

| ID | Description | Ready when | Dependencies | Files | Level | Executor | Status | Orca task_id | dispatch_id |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 02-01 | CheapVibeCode balance data path, app integration and all-size widget UI | Balance visible in all sizes; key only in Keychain; focused and full acceptance pass; live check matches the dashboard | Plan approval | See Ownership | L3 | terra lead + luna pieces | todo | pending | pending |

No separate 02-02 task is needed; all pieces share one L3 lead and one
integration checkout.

### Lead plan pieces

The lead commits `plan/specs/02-01.plan.md` before implementation.

| Piece | Owner | Files | Order |
| --- | --- | --- | --- |
| 02-01a data seam | terra lead | `Sources/Shared/Models.swift`, new `Sources/App/CheapVibe.swift`, `Tests/BalanceHarness.swift`, new `Tests/run-balance.sh`, both `Localizable.strings` | first |
| 02-01b store seam | luna | `Sources/App/Store.swift`, `Tests/RefreshHarness.swift` | after 02-01a |
| 02-01c widget | luna | `Sources/Widget/LimitsWidget.swift`, `README.md` | after 02-01a, in parallel with 02-01b |
| 02-01d panel and settings | luna | `Sources/App/Popover.swift`, `Sources/App/SettingsView.swift` | after 02-01b |

The lead owns final integration, any shared-file repair, full acceptance, the
commit, Gemini review, and all review dispositions. At most two luna pieces run
in parallel, with disjoint file ownership.

## Ownership

Editable:

- `Sources/Shared/Models.swift`
- `Sources/App/CheapVibe.swift` (new)
- `Sources/App/Store.swift`
- `Sources/App/Popover.swift`
- `Sources/App/SettingsView.swift`
- `Sources/Widget/LimitsWidget.swift`
- `Resources/ru.lproj/Localizable.strings`
- `Resources/en.lproj/Localizable.strings`
- `Tests/BalanceHarness.swift` (new)
- `Tests/run-balance.sh` (new)
- `Tests/RefreshHarness.swift`
- `README.md`
- `plan/specs/02-01.md`, `plan/specs/02-01.plan.md`, `plan/specs/02-01.review.md`,
  `plan/02-cheapvibecode-balance.md`, `plan/STATUS.md`, `plan/RESULTS.md`

Explicitly excluded:

- `Resources/Widget.entitlements`, `Resources/App-Info.plist`,
  `Resources/Widget-Info.plist`, `build.sh`, `plan/tools/`, and all provider
  fetchers. If an entitlement or Info.plist change appears necessary, stop and
  ask; do not add one speculatively.
- No changes to Claude, Codex, Antigravity, usage scanning, notifications, or
  menu-bar rendering.

## Risk list

- **Credential disclosure.** The key must stay in Keychain and must never enter
  snapshot data, logs, error messages, URLs, process arguments, test fixtures,
  or review output. Redirects must not forward the bearer token.
- **Concurrency.** Balance work runs before the VPN gate and beside provider
  and usage work. One request per generation, stale completions discarded,
  current-snapshot merge, and no blocking of the limits indicator are required.
- **Protocol drift.** The public evidence confirms only `token_balance`.
  Parsing must tolerate extra fields and common numeric representations, fail
  closed on malformed data, and preserve the last good value.
- **Backward compatibility.** Old `snapshot.json` files without `cheapVibe`
  must decode. The widget must render unchanged when no balance exists.
- **Keychain after ad-hoc rebuilds.** Access prompts may reappear; this is a
  manual verification note, not a reason to store the key in plain text.
- **Widget space.** The small and medium layouts are tight. Verify all sizes
  with a real installed widget; do not claim a visual check that was not
  performed.

## Observable acceptance

Focused:

1. `Tests/run-balance.sh`: numeric and numeric-string `token_balance`, extra
   fields, malformed/missing/negative values, status mapping, and decoding an
   old snapshot without `cheapVibe`.
2. `Tests/run-refresh.sh`:
   - VPN off still fetches and publishes the balance while provider reads
     remain blocked and the pause remains visible;
   - a held balance request does not delay limits publication, and a duplicate
     refresh does not start a second request;
   - a failure preserves the last tokens and timestamp while setting the error,
     and deleting the key clears the balance and discards an in-flight result.
3. `plan/tools/accept.sh` once before the implementation commit and once at
   merge. This includes the universal app/widget build, all standalone Swift
   harnesses, resources, and signatures.

Manual macOS checks (record actual observations):

- Build/install, open Settings > Баланс, save the owner's real key, and compare
  the displayed compact and exact values with the portal dashboard.
- Verify all three widget sizes show the balance without clipping; verify the
  no-key state hides it.
- Verify a wrong key shows the invalid-key message without affecting provider
  limits.
- Turn VPN off and confirm providers pause while the balance continues to
  update.
- Delete the key and confirm the balance disappears from panel and widget.
- Note any Keychain prompt after rebuilding.

Automated acceptance never uses the real key, portal session, or network.

## Review

After full acceptance and commit, run Gemini `gemini-3.8-flash-high` through
`plan/tools/self-review.sh 02-01`. The lead personally reads the full diff and
dispositions every finding in `plan/specs/02-01.review.md`. Fix blocker/major
findings in at most two rounds; large omissions become another piece. Run the
luna control review only if blocker/major findings remain after Gemini's second
round, or after two Gemini startup failures.

## Approval boundary

Approval of this document authorizes:

- adding the optional CheapVibeCode HTTPS balance source and its user-supplied
  API key stored in macOS Keychain;
- extending the snapshot schema and the app/widget presentation as described;
- updating localizations, tests, README, and plan state;
- creating the Stage 02 Run and Orca Task after approval.

It does not authorize portal scraping, any other credential or service, a
plain-text key store, changes to provider VPN behavior, or product code outside
the stated Ownership. No Run or implementation starts before the user's
approval.
