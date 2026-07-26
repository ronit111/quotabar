# QuotaBar — native macOS menu bar app for multi-account AI usage

Replaces a SwiftBar text-menu plugin with a native SwiftUI menu bar app. macOS 26 host (build for macOS 14+ where APIs allow; prefer modern APIs, no legacy AppKit popover hacks). Swift 6.3 toolchain via CommandLineTools; NO Xcode project required — use a Makefile + swiftc or SwiftPM executable target producing an ad-hoc-signed .app bundle (pattern: `make bundle` → dist/QuotaBar.app, `make install` → /Applications). LSUIElement=true (menu bar only, no Dock icon).

## Data & actions layer (ALREADY EXISTS — consume, never reimplement)
The app resolves `<scripts-dir>` at runtime ($QUOTABAR_SCRIPTS_DIR, else
`~/.local/share/quotabar/account-bank`, else the copy bundled in Resources), and
`<bank-dir>` the same way the scripts do ($BANK_DIR, else `~/.local/share/quotabar`).
- Usage JSON: run `/usr/bin/python3 <scripts-dir>/usage.py` → stdout JSON: `{generated_at, stale?, stale_reason?, accounts:[{provider:"claude"|"codex", email, active, plan, status?, error?, fetched_at, five_hour:{utilization,resets_at}, seven_day:{utilization,resets_at}, worst_limit:{kind,percent,resets_at}, stale_entry?}]}`. Timeout 15s; on failure keep last data and show a stale badge. Every poll passes `ACCOUNT_BANK_PARKED_MAX_AGE=600`. Polls share the global FIFO with actions and retain TERM → process-tree SIGKILL timeout escalation.
- Swap: `/bin/bash <scripts-dir>/swap-account.sh <email>` (async; then re-poll).
- Ping: `/bin/bash <scripts-dir>/ping-account.sh <email>` (async; then re-poll). Cooldown: read `last_ping` (epoch seconds) from `<bank-dir>/<email>.json`; 1800s window → disable button and show countdown.
- Auto-ping config: `<bank-dir>/.config.json` `{"auto_ping":[emails]}` — read for the per-account indicator (the backend fires the pings). Toggle: `/bin/bash <scripts-dir>/toggle-autoping.sh <email>` (flips membership under the bank lock; then re-poll). Claude accounts only.
- Codex manual ping: resolve the user's `codex` binary once via `/usr/bin/env sh -lc 'command -v codex'` (hide the button if absent), then run `codex exec "reply with just: ok" --skip-git-repo-check` (stdin `/dev/null`) with a 90s timeout. Burns one small Codex turn per press; 30-minute cooldown persisted in UserDefaults (`codexLastPing`). No auto-ping for Codex.

## Menu bar item
- SF Symbol `bolt.fill`, NON-template so it renders tinted: green (all healthy worst<60), orange (any 60–85), red (any >85), gray (stale/no data). If any Claude account has status `needs-relogin`, use `bolt.trianglebadge.exclamationmark` (badge conveys attention; keep tint from healthy accounts).
- Icon only. NO text in the menu bar. Ever.

## Popover (MenuBarExtra with .menuBarExtraStyle(.window))
Design language: current macOS aesthetics — translucent material background (.ultraThinMaterial), SF Pro (system font), SF Symbols, generous 12–14pt padding, rounded 10pt card corners, subtle separators, automatic light/dark. Width ~320pt. Reference feel: SessionWatcher.com / native Control Center modules. NOT a terminal aesthetic: no monospace, no ASCII bars.

Layout top to bottom:
1. **Claude account cards** (fixed backend bank order; active state never reorders cards). Each card:
   - Header row: colored status dot (green/orange/red by worst limit) + email (medium weight) + plan chip (small rounded capsule, uppercase: MAX / PRO / PLUS) + "ACTIVE" capsule tint-accented on the active account.
   - Two compact gauge rows: "5h" and "Week", each a native linear `Gauge` (or ProgressView with tint matching severity color) + percentage right-aligned (SF Pro, semibold) + reset caption below in secondary color: "resets 12:00 (in 3h 08m)" — absolute local time + relative, both computed from resets_at.
   - Optional third caption when worst_limit.kind is a scoped/model limit: "model cap NN%".
   - Freshness is silent while healthy data is under 120s old. At 120s or older, or when `stale_entry`/`error` is present, show a right-aligned amber `cached Xm ago` caption and dimmed secondary gauges/numbers. A switch target reads `updating…` with reduced-opacity gauges until its targeted confirmation returns.
   - Action row (small bordered buttons): `Ping` (or "Ping · 12m" disabled during cooldown); `Switch here` on parked accounts only. Auto-ping enabled → tiny "auto-ping" caption with bolt.badge.clock symbol, secondary color.
   - needs-relogin card: red-tinted card, exclamation symbol, text "Re-login needed — run /login, pick this account, then re-bank", single button `Re-bank` → runs bank-account.sh.
2. **Codex section**: one slim card, header "Codex" with the ChatGPT account email, same gauge rows. Single action: a `Ping` button (or "Ping · 12m" during cooldown) that runs `codex exec` as above; hidden entirely when the `codex` binary can't be resolved. No Switch/auto-ping.
3. **Footer row** (small, secondary): "Updated 22s ago" (relative, ticking) · Refresh button (arrow.clockwise, triggers immediate poll) · gear menu with "Launch at Login" toggle (SMAppService.mainApp) and "Quit".
- Stale state: amber capsule "cached data · cached 9m ago" at top when JSON is stale/lock-failed or a poll failed. Retry every 30s while the popover remains open.

## Behavior
- Poll on app launch and every 5 min while running. On popover open, when any card is older than 60s or has no verifiable `fetched_at`, poll with `ACCOUNT_BANK_FORCE_FRESH=*`. Debounce starred open-polls app-side to at most one per 60s, including while one is queued behind another poll. Never block the UI thread; async Process execution.
- All numbers/colors derive from the JSON. Thresholds: <60 green, 60–85 orange, >85 red (match backend).
- Swap/Ping: run script async, show a brief spinner on the button, re-poll when it exits, surface script failure as a transient red caption on the card (stderr first line), never a modal. A successful swap flips only the ACTIVE chip optimistically, releases its spinner, and performs its serialized confirmation poll with `ACCOUNT_BANK_ONLY=<target-email>`; the target remains explicitly updating until that poll returns. Every switch attempt appends `switch: script Xms, confirm Yms` to the diagnostic failure log; a skipped confirmation records `0ms`.
- Usage polls and all mutating actions (ping/switch/rebank/toggle-autoping/codex-ping) run through one global FIFO — exactly one process at a time. A request waiting behind another shows a "queued" state on its card until it reaches the head. One action per card at a time. Mutating actions time out after 90s with SIGTERM only, wait 10s, then release the queue without SIGKILL, show "still finishing — refresh shortly", and re-poll after 5s.
- The account region hugs its content when small; once it would exceed ~560pt it becomes a bounded ScrollView with the footer pinned outside, so lower cards and the footer stay reachable.

## DO NOT
- Do NOT read or write the macOS Keychain, `<bank-dir>/*.json` beyond the read-only fields listed, or any credential material. Scripts are the only actuators.
- Do NOT make any network call other than the ONE allowlisted update check (below). The app's only I/O: the account-bank scripts (usage.py, ping/swap/bank/toggle-autoping/un-seed, and the v2 seam scripts `claude-acct`, `sessions.py`, `restart.py`), the resolved `codex` binary, an `osascript` launch of Terminal for the owner-interactive add-account flow and for a pinned session (`claude-acct <email>`), the bank-dir reads listed, UserDefaults for its own prefs (launch-at-login, `codexLastPing`, `seedAuditAckTs`, `updateCheckEnabled`, `updateLastCheck`, `updateDismissedVersion`), one plain-text failure log at `~/Library/Logs/QuotaBar.log` (diagnostic messages only, never token/credential material), the epoch-aware runtime marker (below), and `NSPasteboard` for the user-invoked "Copy usage summary". Nothing else touches the filesystem or network. The Makefile `audit` rule enforces exactly this surface.
- **Allowed network call — the update check (v1.0.2):** at most once per 24h (timestamp persisted, so relaunches don't re-fire), an unauthenticated `GET https://api.github.com/repos/ronit111/quotabar/releases/latest` with `User-Agent: QuotaBar/<CFBundleShortVersionString>`, on an ephemeral URLSession (no cookies, no cache, no credentials). It sends nothing about the user, the machine, or their accounts. `tag_name` is semver-compared against `CFBundleShortVersionString`; when newer, the footer shows one dismissible hairline caption (`<version> available · brew upgrade --cask quotabar`), dismissible per version. Failures are silent — no error chrome, retried in the next window. Gear-menu toggle "Check for Updates", default ON; off means no request at all. The `audit` rule ALLOWLISTS this precisely rather than permitting networking generally: exactly one `URLSession(` call site in Services.swift and no other URL literal in that file.
- **Allowed write under accounts/ — the runtime marker (v2):** on launch the app writes `accounts/quotabar.runtime.json` = `{"pid": <pid>, "epoch_aware": true}` (atomic, 0600), keeps it fresh, and removes it on a clean quit. This is the SOLE file the app writes under `~/.claude/`; `attest-cutover.sh` fails closed unless the RUNNING QuotaBar pid matches an epoch-aware marker. It carries no credential material. The `audit` rule pins Services.swift to exactly the 2 log writes + this 1 marker write, and to exactly one `removeItem` (the marker teardown).
- Do NOT bundle, log, or display tokens. Do NOT add analytics.
- Do NOT modify anything under ~/.claude/ (scripts belong to another system), EXCEPT the app's own runtime marker at `accounts/quotabar.runtime.json` (above).
- Do NOT disable or uninstall the SwiftBar plugin — switchover is handled separately after verification.
- Do NOT auto-enable launch-at-login; it's an off-by-default toggle.
- Do NOT invent extra features beyond this spec.

## Deliverables
Source in this directory (App.swift + views + model, Makefile, Info.plist), built dist/QuotaBar.app (ad-hoc signed), installed to /Applications, launched once. Verify: app runs, icon appears, popover renders with live data from usage.py, Ping cooldown state correct. Report build steps taken, file list, and any spec deviations with reasons.
