# QuotaBar

A native macOS menu bar app that tracks AI usage limits across multiple accounts,
for people who hold more than one paid AI subscription and switch between them.

QuotaBar shows the current 5-hour and weekly usage for each of your Claude Code
accounts and your ChatGPT/Codex account, side by side, in the menu bar. It can
also switch which Claude account Claude Code is logged into, so you can move work
onto a different account's rate limit without logging out and back in by hand.

It has two parts:

- **`app/`** — the SwiftUI menu bar app (the UI). It makes no network calls of its
  own; everything it shows comes from the scripts.
- **`scripts/`** — a set of bash + Python scripts (the "account bank") that read
  usage from the providers, store per-account credentials locally, and perform the
  account switches. These also work on their own from the command line, or as a
  SwiftBar plugin.

> **Status:** personal tool, released as-is. Both usage endpoints it reads are
> **undocumented** (see [Security](#security-and-privacy)) and may change or break
> at any time. macOS 14+, Apple Silicon.

## What it does

- **Per-account usage at a glance.** The menu bar icon is tinted by the active
  account's worst current limit (green / amber / red), with a dropdown showing each
  account's 5-hour and weekly windows, reset times, and plan tier.
- **Switch accounts ("swap").** One click writes a banked account's credentials
  into Claude Code's login and updates its identity file, so your running Claude
  Code sessions bill that account from their next request. No browser re-login.
- **Auto-pick (opt-in).** At the start of a new Claude Code session, a hook can
  automatically select the healthiest account by plan tier and remaining quota,
  rather than you choosing manually.
- **Ping / auto-ping (opt-in).** A "ping" runs one minimal turn on an account to
  start its idle 5-hour window early, so the clock is already running before a work
  block. Auto-ping keeps a window running for opted-in accounts. Both are rate-
  limited (30-minute cooldown) and cost a few small turns per day at most.
- **Codex / ChatGPT usage (read-only).** Your Codex usage is displayed alongside
  Claude. QuotaBar never modifies or refreshes the Codex token — the Codex CLI owns
  it.

These features exist to make owning several subscriptions less tedious to manage.
QuotaBar does not create accounts, generate credentials, or circumvent any
provider's controls — it reads the same usage the provider shows you and switches
between logins you already own.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon.
- Xcode Command Line Tools (`xcode-select --install`) — provides `swiftc`.
- [Claude Code](https://claude.com/claude-code) installed and logged into at least
  one account. Optionally the Codex CLI for ChatGPT usage.
- Python 3 (the system `python3` is fine; the scripts are stdlib-only, no pip).

## Install

There is no notarized download — you build it yourself. From the repo root:

```sh
./install.sh
```

That installs the scripts to `~/.local/share/quotabar/account-bank` and builds and
installs `QuotaBar.app` into `/Applications`. To build only the app:

```sh
cd app && make install   # or: make bundle  (build to app/dist.noindex without installing)
```

### First launch (Gatekeeper)

The app is **ad-hoc signed, not notarized**, so Gatekeeper blocks the first launch.
Right-click `QuotaBar.app` in `/Applications`, choose **Open**, then **Open** again
in the dialog. After that it launches normally. Alternatively:

```sh
xattr -dr com.apple.quarantine /Applications/QuotaBar.app
```

Set QuotaBar to launch at login from its menu — the auto-pick and auto-ping
features only run while the app is open.

### One-time Keychain authorization (for fast swaps)

Claude Code stores its login in your macOS login keychain. By default, each time a
tool other than Claude Code reads that item, macOS shows a password prompt. To let
the swap scripts read it without prompting every time, run this once:

```sh
security set-generic-password-partition-list \
  -s "Claude Code-credentials" -a "$USER" -k "" -S "apple:,apple-tool:"
```

This adds Apple-signed tools (including `/usr/bin/security`, which the scripts use)
to that **one** keychain item's access list. It does not reveal the secret and does
not affect any other item — it only stops the repeated GUI prompt. macOS asks for
your login password once to apply it.

### Adding accounts

Run `/login` in Claude Code and sign into each account you want tracked. Then bank
it once so QuotaBar knows about it:

```sh
bash ~/.local/share/quotabar/account-bank/bank-account.sh
```

If you enable the SessionStart hook (below), banking happens automatically the next
time you start a Claude Code session — adding an account becomes just `/login`.

### Optional: SessionStart hook (auto-bank, auto-pick, auto-ping)

Auto-bank / auto-pick / auto-ping run inside Claude Code's SessionStart hook. This
is opt-in because it edits your Claude Code settings. To enable, add
`account-warn.sh` as a SessionStart hook in your Claude Code `settings.json`, and
turn on the features you want in `~/.local/share/quotabar/.config.json`
(e.g. `{"auto_pick": true, "auto_ping": ["you@example.com"]}`). See
[`scripts/README.md`](scripts/README.md) for the full behavior and safety model.

## Security and privacy

QuotaBar handles login credentials, so its data flows are worth understanding
before you trust it. This is the honest accounting.

**What it reads.**

- **Claude Code's credentials** from the macOS login keychain (generic-password
  item `Claude Code-credentials`) and account identity from `~/.claude.json`. These
  are Claude Code's own files — QuotaBar reads the same login you already use.
- **Codex's token** from `~/.codex/auth.json` (owned by the Codex CLI), read-only.

**Where it stores things.** Banked account records (a copy of each account's
credentials plus metadata), keychain snapshots, the usage cache, and the lock all
live under `~/.local/share/quotabar` (directory `700`, files `600`). Nothing
sensitive is written inside this repo or anywhere world-readable. The app's log is
`~/Library/Logs/QuotaBar.log` and never contains token values.

**Network.** The app itself makes **no** network connections — the `make audit`
target mechanically enforces the absence of any networking, keychain, analytics, or
logging APIs in the app binary. The scripts contact exactly two hosts, both the
providers' own usage endpoints:

- Anthropic's usage API, using your existing Claude token.
- `chatgpt.com/backend-api/wham/usage`, using your existing Codex token.

There is **no telemetry, no analytics, no third-party server, no phone-home.**
Nothing is sent anywhere except those two provider endpoints, and only to read your
own usage.

**Both usage endpoints are undocumented.** Neither Anthropic nor OpenAI publishes
the usage endpoint this tool reads. They can change response shapes, move, or
disappear without notice, which would break the usage display until the scripts are
updated. Treat the numbers as best-effort.

**Account mutation is local and conservative.** Switching accounts is done entirely
by the local scripts, under a lock, and is hardened against interruption:

- Keychain writes are exact-match only, snapshot-first and **fail-closed** (they
  abort if the current item can't be backed up first), send the secret through
  `security`'s stdin (never a command-line argument), and **refuse to create** a
  missing keychain item unless explicitly bootstrapped.
- All file writes are atomic (`mktemp` + rename, `0600`).
- A swap is transactional: if updating the identity file fails after the keychain
  write, the keychain is rolled back; a crash mid-swap is repaired from a journal on
  the next run so the keychain and identity file can't be left disagreeing.
- The active account is never token-refreshed (refreshing rotates the token under a
  live session); the Codex token is never written. Token values are never printed.

The full invariant list is in [`scripts/README.md`](scripts/README.md)
("Safety invariants"). The scripts were hardened following a cross-vendor security
review, but this is a personal tool with no warranty — read the code before running
it with your credentials.

## Configuration

Environment variables (all optional):

| Variable | Default | Purpose |
| --- | --- | --- |
| `BANK_DIR` | `~/.local/share/quotabar` | Where banked records, cache, lock, snapshots live. |
| `QUOTABAR_SCRIPTS_DIR` | `~/.local/share/quotabar/account-bank` | Where the app looks for the scripts (falls back to the copy bundled in the app). |
| `XDG_DATA_HOME` | `~/.local/share` | Base for the two defaults above. |
| `ACCOUNT_BANK_TIMEOUT` | `5` | Per-request network timeout (seconds). |
| `ACCOUNT_BANK_PING_MODEL` | `haiku` | Model used for a ping turn. |
| `ACCOUNT_BANK_CODEX_PING` | `0` (off) | Allow the Codex CLI to self-refresh on a 401. |

The app resolves the scripts directory at launch (env override → installed location
→ the copy bundled inside `QuotaBar.app`) and resolves the bank directory the same
way the scripts do, so the two always agree.

## Uninstall

```sh
rm -rf /Applications/QuotaBar.app ~/.local/share/quotabar ~/Library/Logs/QuotaBar.log
```

Remove the SessionStart hook from your Claude Code `settings.json` if you added it.
Your Claude Code and Codex logins are untouched.

## License

MIT — see [LICENSE](LICENSE).
