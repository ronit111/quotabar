# account-bank — multi-account Claude usage, swap, ping + Codex tracking

Track usage across multiple Claude Code accounts (and your ChatGPT/Codex
account), hot-swap which Claude account Claude Code uses to spread work across
separate rate limits, and "ping" an account to start its idle 5-hour window
before a work block.

## How Claude Code stores the login

Claude Code keeps its OAuth credentials in the macOS **login keychain** as a
generic password:

- service `Claude Code-credentials`, account `<your macOS username>`
- secret JSON: `{"claudeAiOauth": {accessToken, refreshToken, expiresAt,
  refreshTokenExpiresAt, scopes, subscriptionType, rateLimitTier}}`
  (`expiresAt` / `refreshTokenExpiresAt` are epoch **milliseconds**)

The account **identity** (email, org, plan) lives separately in `~/.claude.json`
under `oauthAccount`. A full "account" is the keychain blob **plus** that
metadata.

When `CLAUDE_CONFIG_DIR` is set, Claude Code reads **file-based** credentials
from `$CLAUDE_CONFIG_DIR/.credentials.json` instead of the keychain. We exploit
this for parked-account refresh (below). *Verified empirically 2026-07-19.*

## Architecture

```
<scripts-dir>/                       (default: ~/.local/share/quotabar/account-bank)
  lib.sh              helpers: snapshotted keychain read/write (-U only), mkdir
                      lock, portable run_with_timeout, active-email detection
  bank-account.sh     snapshot the CURRENT logged-in account into the bank
  swap-account.sh <e> re-bank current -> write target creds to keychain ->
                      update ~/.claude.json -> report. Refuses needs-relogin.
  list-accounts.sh    table: email, plan, banked_at, active marker, status
  ping-account.sh     run one minimal turn to start a 5h window (active or parked)
  usage.py            poll all providers, emit one normalized JSON doc (+ cache)
  isolated_refresh.py refresh a parked account via an isolated CLAUDE_CONFIG_DIR
  reconcile.py        recover rotated tokens from crash-recovery journals
  write_bank_record.py write a bank record atomically (blob read from STDIN)
  validate_blob.py    schema-validate a keychain blob (read from STDIN)
  swiftbar-render.py  render usage JSON as SwiftBar menu-bar text
  claude-usage.5m.sh  SwiftBar plugin (symlinked into ~/.swiftbar)
  account-warn.sh     SessionStart hook: warn when active account >= 80%

$BANK_DIR/                          the "bank" (chmod 700; default ~/.local/share/quotabar)
  <email>.json                      full account record (chmod 600)
  .keychain-snapshots/              pre-write keychain backups (last 20)
  .usage-cache.json                 last-good usage output + backoff state
  .lock/                            mkdir lock
```

Bank file (`<email>.json`):
```json
{ "email", "banked_at", "banked_at_epoch",
  "status": "ok" | "needs-relogin",
  "last_verified", "last_ping",
  "claudeAiOauth": { ...keychain blob... },
  "oauthAccount":  { ...~/.claude.json metadata... } }
```

## Providers

### Claude (swappable, refreshable when parked)
- **Active account = read-only.** Polled with its live keychain token; **never
  refreshed** (refreshing rotates the token under the live session). "Active" is
  the account whose email is in `~/.claude.json` `oauthAccount.emailAddress`.
- **Parked accounts = lazy refresh + write-back.** When a parked account's access
  token is expired and we need to poll it, we refresh it via the **isolated
  config-dir technique** (see below) and write the rotated tokens back to its
  bank file under the lock.

### Codex / ChatGPT (read-only, no swap)
- Source: `~/.codex/auth.json` (owned by the Codex CLI) → `tokens.access_token`
  + `tokens.account_id`. **We never write or refresh it** — the Codex CLI owns
  its token rotation.
- Endpoint: `GET https://chatgpt.com/backend-api/wham/usage`, headers
  `Authorization: Bearer <access_token>` + `chatgpt-account-id: <account_id>`
  (verified against steipete/CodexBar and vineellabs/usagebar source, and live).
- Response: `rate_limit.primary_window` / `secondary_window` each with
  `used_percent` (0–100) and `reset_at` (epoch **seconds**); windows are
  classified as 5h vs weekly by `limit_window_seconds` (≈18000 vs ≈604800), not
  by name (a Plus account may report only a weekly window in `primary_window`).
- On 401 → renders "re-auth needed (run codex)". Optional gated nicety
  (`ACCOUNT_BANK_CODEX_PING=1`, default **off**): let the Codex CLI refresh
  itself via `codex exec` on a 401, then retry once.

## Parked-account refresh: the isolated config-dir technique

Instead of hand-rolling an OAuth refresh call, we let **Claude Code itself**
refresh a parked token:

1. `mktemp -d`, write the parked account's `{"claudeAiOauth": {...}}` to
   `<tmpdir>/.credentials.json` (chmod 600).
2. Run `CLAUDE_CONFIG_DIR=<tmpdir> claude -p "reply with just: ok" --model haiku`
   (60s cap; falls back to the default model if haiku is unavailable).
3. Read the (rotated) creds back from `<tmpdir>/.credentials.json`, write them
   into the bank file under the lock, delete the tmpdir.

The **login keychain is never touched** — the active session is unaffected. No
unverified client_id, no hand-rolled OAuth. `isolated_refresh.py` implements
this and is used by both `usage.py` (lazy refresh) and `ping-account.sh` (parked
ping). The raw OAuth-endpoint refresh is **not** used (it was replaced by this);
the client_id was verified in the Claude Code binary but this technique is safer.

## Ping (manual, per account)

A "ping" runs one minimal turn to **start an idle 5-hour window**, so the clock
is already running before a work block. `ping-account.sh [email|--active]`:
- **active** → `claude -p` directly (keychain login).
- **parked** → the isolated config-dir turn; the turn bills the parked account
  and, if its token was expired, the CLI refreshes it (keep-alive bonus), written
  back to the bank.
- **30-minute per-account cooldown** (`last_ping` in the bank file).
- A `needs-relogin` account is refused with recovery instructions.
- After success, the usage cache is refreshed so the menu bar reflects the new
  window.

Manual ping is always available. Auto-ping (below) covers the "keep a window
running" case without a manual click. (Codex ping via `codex exec` is a possible
future option, not built.)

## Removing an account

`remove-account.sh <email>` forgets a **parked** Claude account: it deletes the
bank record (`$BANK_DIR/<email>.json`) and drops the email from the
`auto_ping` list in `$BANK_DIR/.config.json`. Auto-pick needs no edit — it
enumerates bank files, so a removed account leaves the pool automatically. The
account can be re-added at any time by just `/login`-ing to it again (the
SessionStart hook auto-banks it).

Same lock/journal discipline as swap: acquire the bank lock **first**, reconcile
crash-recovery journals, then decide under the lock. All mutations are atomic (the
bank file is renamed-away then unlinked; the config is written via the shared
0600 atomic-write helper).

**Safety rule — the live active account can never be removed.** Under the lock the
script re-derives the active account from `~/.claude.json` (`oauthAccount`) and
**refuses** (exit 1) if `<email>` is active: *"cannot remove the active account;
swap to another account first."* The active account owns the live keychain item,
so removing its bank record would strand the running session's tracking — swap to
another account first, then remove. The **keychain is never touched** either way;
`.keychain-snapshots` history is intentionally left in place. Removing an account
that was never banked is a clean no-op (exit 0), not an error.

QuotaBar surfaces this as a trailing `…` control on **parked** Claude cards only
(never the active card, never Codex). Tapping it shows a native confirmation, then
runs `remove-account.sh` through the same global action queue as ping/switch/toggle;
the card disappears on the next poll.

## Auto-ping (opt-in, piggybacked on the poll — no new scheduler)

Auto-ping keeps a 5-hour window running for opted-in accounts: when the SwiftBar
poll (every 5 min) notices an account's 5h window has **lapsed**, it fires a ping.

- **Config:** `$BANK_DIR/.config.json` (0600),
  `{"auto_ping": ["you@example.com", "second@example.com"]}`.
  `usage.py` reads it fail-soft — a missing or malformed file just disables the
  feature. **To disable:** remove an email from the list, or delete the file.
- **Detection** happens inside the normal poll (no extra process). An account's
  window is "lapsed" when its `five_hour.resets_at` is absent or in the past. A
  freshly-started window reports low utilization but a *future* `resets_at`, so
  we key off `resets_at` (not utilization) — that avoids re-firing right after a
  ping and holds the cost to **~1 ping per 5h window ≈ ~5 turns/day/account**.
- **Firing** spawns `ping-account.sh` fully **detached** (`start_new_session`,
  stdout+stderr to `$BANK_DIR/.autoping.log`, 0600, truncated at 50 KB)
  so the poll never blocks on it (plugin stays ~1.4 s). The ping takes the bank
  lock itself, so a parked-account auto-ping (which rotates tokens via the
  isolated profile) cannot race a concurrent swap.
- **Debounce:** the existing 30-min per-account cooldown, keyed off **both**
  `last_ping` and `last_autoping`. `usage.py` records `last_autoping` *before*
  spawning, so a crashed ping can't re-fire more than once per cooldown.
- **Never fires** for a needs-relogin account, an account with a poll error, or
  one showing only a cached (stale) figure. Requires the bank lock (skipped in
  read-only mode).
- The SwiftBar dropdown shows a per-account toggle (`toggle-autoping.sh`):
  "auto-ping: on — click to disable" / "off — click to enable".
- **One ping per cycle (finding #10).** `maybe_autoping` fires at most a single
  detached ping per poll — the **most-lapsed** eligible account (earliest/absent
  5h `resets_at`) — so two lapsed accounts never race the same lock with one
  losing while cooldown-suppressed. It does **not** stamp `last_autoping` before
  spawning; the cooldown is recorded inside `ping-account.sh` only after it takes
  the lock and knows the outcome (success → `last_ping`, failure →
  `last_ping_failed`, 5-min), so a ping that never actually ran can't suppress the
  next attempt.
- **Phase-stagger — keeps the two accounts' resets offset so a refill is never far
  away.** Before firing a **parked** auto-ping, if the window it would start
  (`now + 5h`) would land within **75 min** of another Claude account's current
  `five_hour.resets_at`, the ping is **held** (logged `stagger-hold:<email>`) and
  retried next cycle, until firing would give a ≥ 75 min phase gap **or** it has
  been held **2.5 h** (then it fires regardless — a running window beats perfect
  phase). The **active** account is never held (its window serves live work). A
  missing reset on the other account means no hold. The hold start
  (`stagger_hold_since` in the bank record, preserved across re-bank) makes the
  2.5 h cap survive restarts; it is cleared on fire. Zero extra token cost — this
  only delays pings.

## Scheduler reality (there is no daemon of ours — finding #9)

Auto-ping and auto-pick are **not** background jobs. Both run **only when
`usage.py` runs**, and `usage.py` runs from exactly two callers:

1. **QuotaBar's in-process 5-minute loop** (`Services.swift`) — the normal
   steady-state scheduler. It calls `usage.py` (which runs `maybe_autoping`) every
   5 minutes while the app is open.
2. **The SessionStart hook** (`account-warn.sh`) — runs once per new Claude Code
   session.

**Enforcement is Launch-at-Login:** QuotaBar must be set to launch at login so the
5-minute loop actually exists. If QuotaBar is **not** running, the only thing that
fires auto-ping/auto-pick is starting a new session. To cover that gap, when the
hook finds the cache stale (>10 min) **and** `pgrep -x QuotaBar` shows the app is
not running, it does one full `usage.py` poll (hard 5 s cap, `maybe_autoping`
included) instead of a bare active-only request — so opening a session still gives
hook-time auto-ping coverage with the app closed. With QuotaBar running the hook
just reads its fresh cache and never does the heavier poll. There is still **no
launchd job, watcher, or polling loop of ours** (efficiency directive intact).

## Auto-bank on first login (SessionStart hook)

Before auto-pick, the hook checks whether the active keychain account has a bank
file. If not, it runs `bank-account.sh` (fast, locked, idempotent) and announces
"New account <email> auto-banked (plan: X) — now tracked in the usage bar and
auto-pick pool." So **adding an account is just `/login` once** — the next
session banks it automatically. Fail-soft (a lock-busy bank just retries next
session).

## Login-sync (automatic re-bank)

At every session start the hook compares the live keychain blob (token + plan)
to the active account's bank record; on any drift it re-banks silently — so a
routine `/login` needs no manual Re-bank and the plan chip stays accurate. A
plan change is announced ("plan change detected (pro -> max)"). The Re-bank
button in QuotaBar remains only for **needs-relogin** recovery of parked
accounts.

## Auto-pick (SessionStart hook — plan-tiered account selection)

`account-warn.sh` upgrades from warn-only to auto-pick when `.config.json` has
`{"auto_pick": true}`. Absent that, it stays warn-only. There is no `home_base`
key — the policy is pure **plan tiering**: max-plan accounts are always preferred
(that's where Fable-class availability lives). Plan comes from each account's
`subscriptionType` (surfaced by `usage.py`). Policy lives in `autopick.py` so it
is unit-tested in isolation:

- **Active is a MAX account:**
  - worst-limit < 90% → stay.
  - worst-limit ≥ 90% → swap to the healthiest *other* max whose worst is lower.
  - no better max, and **all** max accounts ≥ 99% → swap to the healthiest pro.
  - no better max, not all max exhausted → stay and warn (hot max, nowhere better).
- **Active is a PRO account:** return to the healthiest max as soon as **any** max
  account's worst-limit is < 99%. Else, if the pro is hot (≥ 90%): swap to a
  healthier *other* pro; if **all** pro AND max accounts are provably exhausted
  (≥ 99%, fresh data) → swap to the healthiest free account. Else stay (warn ≥ 80%).
- **Active is a FREE account:** climb back up as soon as anything refills —
  highest tier first (any max < 99%, else any pro < 99%).
- **Tier ladder is Max > Pro > Free.** Unknown/missing plans belong to no tier:
  never a target, never tiered, and they block tier-down fallbacks (can't prove a
  tier exhausted without fresh data on every account in it). Tier-down targets
  must themselves be < 99%.
- **Never swaps** on stale/cache-miss data, on lock contention, or to a
  needs-relogin / errored / cached-figure account.

**Target selection among same-tier candidates (reset-proximity refinement).** When
the max branch has several *other* maxes to move to, or the pro branch has several
maxes to return to, the target is **not** simply the lowest-percent one:
1. **Headroom guard** — prefer targets with worst-limit **< 90%** (a near-dead
   window is a wall, not free quota).
2. Among those, prefer the **soonest** `five_hour.resets_at` (use-it-or-lose-it:
   spend the headroom of a window about to reset, keep fresh windows in reserve).
3. Tie-break equal/missing resets by lowest worst-%. A missing `resets_at` sorts
   **last** (unknown expiry = no strategic value) but is never excluded for that
   alone; if the headroom guard would leave no candidate, it falls back to the
   healthiest of the original set so a warranted swap is never dropped.
This reorders *which* eligible account is chosen; it adds no swap trigger and
changes no threshold. (Pro-fallback still picks the healthiest pro.)

Mechanics: cache-first (uses `.usage-cache.json` < 10 min for the full
multi-account picture; a cache miss falls back to a single 3 s active-only poll,
which can only warn — never swap). A swap runs `swap-account.sh` via subprocess
with a **2 s lock-wait** and a 4 s cap — it either finishes fast or aborts cleanly
*before any write* if the lock is busy, falling back to a warn note. Always exits
0; measured runtime ~0.6 s (no swap) to ~1 s (with swap), well under the 5 s
budget.

**Announcement (turn-level — verified 2026-07-19):** credential pickup is
per-request, so a hook-time swap moves the current session too, from its next
turn. The message says exactly that: "Auto-pick: swapped active account to
<email> (<pct>%, <reason>) — this and all running sessions now bill it (was
<previous> at <pct>%)." `ACCOUNT_BANK_AUTOPICK_DRYRUN=1` previews without swapping.

## Parked-token death — the known steady-state failure mode

With two saved Claude accounts, expect one to eventually need a manual re-login:
parked refresh tokens rotate and can be revoked server-side. This is **normal**,
not an edge case.

### Transient vs revoked — only a confirmed rejection marks a token dead (finding #1)

A parked refresh runs a real `claude` turn in an isolated config dir, and that
turn can fail for many reasons that have **nothing** to do with the credentials:
the `claude` binary isn't resolvable under a minimal GUI `PATH`, the process
can't launch, the turn times out, the network is down, or it exits nonzero for an
unrelated reason. Marking the account `needs-relogin` on any of those (which
forces a manual `/login`) is a **false death** — the token was fine.

`refresh_via_config_dir` therefore returns a structured `RefreshResult`
(`auth_failed`, `reason`) and the system splits the two cases:

- **Confirmed revocation → `needs-relogin`.** Only when (a) the turn actually ran
  and its stderr carries an authentication signature — `Failed to authenticate`,
  `OAuth session expired`, `could not be refreshed`, `invalid_grant`/
  `invalid_token`, or a 401/403 — **or** (b) the refresh token is provably past
  its `refreshTokenExpiresAt`, **or** (c) a live parked poll returns HTTP 401/403.
  These are the *only* paths that set `needs-relogin`.
- **Transient → keep the account, retry next cycle.** Resolver-not-found, launch
  error, timeout, network, non-auth nonzero exit, or a changed-but-malformed
  readback: the status is **left unchanged** (an `ok` account stays `ok`), the
  cached figure is served, and a distinct error is surfaced (`refresh deferred:
  <reason>`). A ping reports this as rc 6 ("transient — will retry"), never a
  dead token.

Signatures of each outcome from `isolated_refresh.py` (exit codes): `3` =
confirmed dead (auth rejection / refresh-token expiry); `4` = malformed readback
(record left untouched); `5` = turn didn't confirm the 5h window (token may be
alive); `6` = transient (resolver/launch/timeout/non-auth nonzero). Only exit `3`
makes `ping-account.sh` write `needs-relogin`.

- A **confirmed** refresh rejection, or a 401/403 on a parked poll → the bank
  file's `status` is set to `needs-relogin` (under lock); the stale entry is
  **kept**, not deleted. Transient failures never do this.
- `needs-relogin` accounts are not polled/refreshed again until re-banked.
- The SwiftBar plugin shows them red as "re-login needed" (no stale
  percentages) and excludes them from the title figures.
- `swap-account.sh` and `ping-account.sh` refuse them; `account-warn.sh` never
  recommends them.
- **Recovery is always the same two clicks:** run `/login` in Claude Code, pick
  that account (the browser session is usually still authorized — no password),
  then `bash bank-account.sh` to re-bank it fresh (which clears the flag).

Our exposure is smaller than a pure usage-tracker's: a swap makes the parked
account **live again**, refreshed by Claude Code itself, and we never create
extra OAuth grants.

## Efficiency posture (standing directive)

- **No processes of ours.** SwiftBar's 5-minute plugin cadence is the only
  scheduler. No launchd jobs, watchers, or polling loops.
- **Tiered polling.** Active Claude + Codex every run; **parked** Claude accounts
  only when their cached reading is >30 min old (`fetched_at` per account in the
  cache). Parked usage barely moves.
- **Zero token spend** except user-initiated pings (haiku-tier, 30-min cooldown)
  and the lazy parked-refresh turn (only when a parked token is actually
  expired). No proactive keep-alive on a schedule.
- **Network hygiene.** 5s timeouts, one retry on network errors only. After 3
  consecutive all-network-failure runs, back off to 30-min attempts and serve
  the stale cache (marked `stale`). The SessionStart hook does a single 3s poll
  with no retry, and only if the cache is >10 min old.
- `usage.py` is stdlib-only python3 (no venv/pip), starts in well under 1s
  excluding network. The plugin shell forks exactly one python process.
- On a per-provider network hiccup, that provider's **last-good** figure is
  reused (rendered "(cached)") so a Codex hang never blanks the bar.

Config knobs (env): `ACCOUNT_BANK_TIMEOUT` (5), `ACCOUNT_BANK_REFRESH` (1),
`ACCOUNT_BANK_PARKED_MAX_AGE` (1800), `ACCOUNT_BANK_CODEX_PING` (0),
`ACCOUNT_BANK_PING_MODEL` (haiku), `ACCOUNT_BANK_NO_PARKED_REFRESH` (0),
`ACCOUNT_BANK_CLAUDE_BIN` (unset → auto-resolve).

### The `claude` binary resolver (findings #3–#5)

`isolated_refresh.py` (`resolve_claude_bin`) and `lib.sh` (`claude_bin`) share
**one** contract: honor `ACCOUNT_BANK_CLAUDE_BIN` only if it is an actually-
executable file; else `command -v` / `which`, then `~/.local/bin/claude` and the
homebrew paths; every candidate must be a real, executable regular file (so an
alias/function description from `command -v`, or a non-executable match, is
rejected). There is **no** login-shell (`sh -lc`) fallback — it runs synchronously
after lock acquisition and a slow login profile could block the bank lock
unboundedly, and its stdout can be contaminated. When the binary can't be
resolved the resolver returns empty/error and the caller treats it as a
**transient** failure (retry), never a dead token.

### The hook path never does parked refresh (finding #2)

A parked refresh spawns a `claude` grandchild that can rotate the refresh token
server-side. The SessionStart hook bounds its `usage.py` poll with a ~5 s timeout
that kills `usage.py` but **not** that grandchild — so a rotation landing right
before the kill would leave the bank holding the now-spent old token (a permanent
false death). To close this, the hook passes `ACCOUNT_BANK_NO_PARKED_REFRESH=1`:
`usage.py` then **skips** the isolated-refresh turn for parked expired tokens and
just serves the cached/stale figure. Parked refresh happens only from QuotaBar's
untimed 5-minute poll or an explicit ping (neither has a short external timeout).
Defense-in-depth: `refresh_via_config_dir` runs `claude` in its own process group
(`start_new_session`) and, even on a timeout-kill, reads back and **journals** any
rotated creds before returning, so `reconcile.py` recovers the rotation on the
next locked op (verified end-to-end).

## Safety invariants (hardened after a cross-vendor security review)

1. **Lock first, decide under the lock.** `usage.py`, `swap`, `ping`, and `bank`
   acquire the bank lock *before* reading active identity / keychain / bank
   records, and re-derive active-vs-parked under it. A concurrent swap therefore
   cannot make a "parked" account active mid-operation and get its token rotated.
2. **Lock is token-owned.** `release` only removes the lock if we still own it
   (random token match). Stale reclaim requires age > 5 min AND holder pid dead,
   via atomic rename-away-then-verify. All lock holders trap `INT/TERM/HUP/PIPE`
   (not just `EXIT`) so a signal never leaks the lock.
3. **Lock failure → read-only.** If the lock can't be acquired, `usage.py` polls
   and prints but performs no refresh, no bank-status write, no cache write.
4. **Keychain writes go through `kc_write`:** exact service+account match only
   (no service-only fallback); snapshot-first and **fail-closed** (abort if the
   live item can't be snapshotted); the secret travels via `security -i` **stdin**,
   never argv; and it **refuses to create** a missing item unless
   `ACCOUNT_BANK_BOOTSTRAP=1`.
5. **Secrets never enter argv.** Blobs are piped to `python`/`security` via stdin
   (`printf` is a shell builtin, so it forks no process whose argv is visible).
6. **All writes are atomic:** `mktemp(0600)` in the same directory then rename —
   bank files, snapshots, `~/.claude.json`, and the cache. No truncate-in-place,
   no umask window.
7. **Swap is transactional (finding #1).** Metadata (`oauthAccount`) is
   pre-validated (must be non-empty and match the target email) before the
   keychain write; if the `~/.claude.json` update fails after the keychain write,
   the keychain is rolled back to the pre-swap blob. The keychain+metadata commit
   is additionally protected two ways so an external timeout can never leave target
   creds paired with the previous account's metadata:
   - **Phase journal** (`.swap-journal.json`, 0600): the pre-swap blob + from/to
     emails are written *before* the keychain write and cleared *after* the
     metadata commit. If interrupted in between (even SIGKILL/crash),
     `reconcile.py` — run under the lock at the start of every op — restores the
     keychain to the pre-swap blob whenever `~/.claude.json` still names the
     pre-swap account (torn), or just drops the journal when the metadata already
     names the target (completed). `ACCOUNT_BANK_RECONCILE_DRYRUN=1` exercises the
     rollback decision without touching the keychain.
   - **Signal deferral, SIGTERM-only:** `swap-account.sh` ignores INT/TERM/HUP/PIPE
     across the sub-second commit, and `account-warn.sh` bounds a hung swap with a
     **SIGTERM only** (no SIGKILL mid-commit) plus a 2 s lock-wait, so a hook-time
     timeout defers rather than tears. `--expect-active <email>` (finding #11):
     the hook passes the account it decided against; the swap aborts (exit 3) if
     the live active account changed under the lock, so a stale auto-pick can't
     stomp a newer manual/QuotaBar switch.
   Swapping to the already-active account is a pure no-op (re-bank only, never a
   keychain write).
8. **Crash-recovery journal.** A parked refresh writes rotated creds to a 0600
   journal before committing them to the bank; `reconcile.py` (run under the lock
   at the start of every bank/swap/ping/usage op) merges any orphaned journal
   before proceeding, so a crash between rotation and commit never loses a token.
9. **Robust inputs.** The cache and every bank record are schema-validated on
   load; malformed shapes/values are discarded, never crash the run. Explicit
   token-field checks (no `assert`, which vanishes under `PYTHONOPTIMIZE`).
10. The active Claude account is never refreshed; the Codex token is never written.
11. Token values are never printed. Bank + snapshot files (600, dir 700) are the
    only places full tokens live. `usage.py` also has a total-run deadline so a
    stalled provider can't stack retries unbounded.

## Tested vs pending

**Tested live (one Claude Max account + one Codex Plus account):**
- V1 keychain round-trip — byte-identical (sha256 match); write path non-corrupting.
- V2 bank + list — banked, 600 perms, status column.
- V3 usage.py — real Claude percentages.
- V4 SwiftBar — valid output, IST resets, colors, Codex `▸` section, ping items.
- V5 hook merge — warn appended to SessionStart, all 5 pre-existing hooks intact.
- **Isolated config-dir** — confirmed Claude Code reads `.credentials.json` from
  `CLAUDE_CONFIG_DIR`, runs the turn, and does NOT touch the keychain (live login
  byte-identical afterward).
- V7 Codex — live `wham/usage` poll, real percentage, window classification.
- V8 ping (active) — real haiku turn started the window; cooldown enforced.
- V9 needs-relogin — usage skips, render red + excluded from title, swap/ping
  refuse, warn excludes. Plus stale-substitution and 3-strike backoff verified.

**Pending (needs a second banked Claude account):**
- Parked-account **lazy refresh** and **parked ping** end-to-end token rotation
  write-back (the isolated mechanism and parked polling are verified).

Mid-session external-swap pickup is now **verified turn-level** (see Swap
semantics above), no longer pending.

## Operating notes

**Add a Claude account:** just `/login` to it once. The next session's
SessionStart hook auto-banks it (see Auto-bank above) — no manual `bank-account.sh`
needed. You can still bank on demand with `bash <scripts-dir>/bank-account.sh`.

**Swap semantics (turn-level, not session-level):** after a swap, **every running
Claude Code session — including the current one — bills the swapped account from
its next request.** Credentials are read from the keychain per turn, not cached
for the session's lifetime. Observed in testing: after a swap from account A to
account B, a session that had *started* on A kept working while A's 5h meter froze
and B's climbed. Session UIs may keep **displaying** the old account — that's
cosmetic. `/login` is only for adding a new account or reviving a needs-relogin
one, never to "pick up" a swap.

**SwiftBar (optional, legacy):** the QuotaBar menu-bar app is the primary UI, but
the same renderer also runs as a SwiftBar plugin. Install SwiftBar
(`brew install --cask swiftbar`), point its plugin dir at `~/.swiftbar`, and
symlink `claude-usage.5m.sh` in. The plugin resolves the real scripts dir by
following the symlink, so keep the file inside the scripts dir and only symlink
it into SwiftBar.
