# bankd — single-writer credential broker (QuotaBar v2 architecture)

Status: **SUPERSEDED IN SPIRIT — do not build as written.** Codex design review returned
**REVISE (8 blockers)** on 2026-07-21 (internal review artifact, not published). The core
refutation: a "single-writer daemon" does NOT eliminate the races, because the writers that matter
(Claude Code, `/login`, `claude` refresh subprocesses) are EXTERNAL to the daemon and keep mutating the
shared keychain slot. The daemon's ownership-transfer swap also can't hold the never-copy invariant
during a transfer, and temp+rename gives no cross-store atomicity (keychain writes aren't rename-atomic).
The review's own finding #12 points at the genuinely better design and is now the leading direction:
**permanent per-account `CLAUDE_CONFIG_DIR` isolation + a `claude-acct <email>` launcher, so NO rotating
token is ever transferred between stores and our accounts never touch the shared slot the other
platforms write.** See HANDOFF.md "THE BIG DECISION IS OPEN" — awaiting the owner's pick between per-account
isolation (loses mid-session global swap) vs keeping global swap (accepts residual flakiness) vs hybrid.
The daemon parts below are retained only as reference for the transaction/recovery discipline any
approach still needs; the isolation approach makes most of them unnecessary.

---
Original draft (option A, before the review refuted it):

## Why (the two original sins this kills)

1. **Copies of single-owner rotating credentials.** Anthropic OAuth refresh tokens rotate
   on use. The v1 bank *copies* the keychain credential → two holders of a one-holder
   token. Every parked-token death and torn-swap race grows from this.
2. **Concurrent shell mutators.** swap/ping/poll/reconcile/hooks racing over shared files
   with mkdir locks, journals, kill-timing. Five adversarial review rounds (105 findings)
   all live in windows this substrate creates.

bankd removes both: one single-threaded daemon is the ONLY process that reads or writes
credentials; nothing else ever holds them. Races die by construction, not by hardening.

## Architecture

```
┌─────────────┐  ┌──────────┐  ┌───────────────┐
│ QuotaBar.app │  │ CLI cmds │  │ SessionStart  │
│ (SwiftUI)    │  │ (thin)   │  │ hook (thin)   │
└──────┬───────┘  └────┬─────┘  └──────┬────────┘
       └───── unix socket, JSON-RPC ───┘
                       │
                ┌──────▼──────┐     ┌───────────────────┐
                │   bankd     │────▶│ macOS keychain     │
                │ (python3,   │     │ (active account)   │
                │  asyncio,   │     ├───────────────────┤
                │  launchd    │────▶│ ~/.claude/accounts │
                │  KeepAlive) │     │  bank + archive/   │
                └──────┬──────┘     ├───────────────────┤
                       └───────────▶│ per-account grant  │
                                    │ dirs (monitor)     │
                                    └───────────────────┘
```

### Process model
- `bankd`: python3 stdlib only (asyncio + socket + json). No pip deps.
- launchd agent `com.quotabar.bankd`, KeepAlive=true, socket at
  `~/.claude/accounts/bankd.sock` (0600; peer-uid checked via SO_PEERCRED equivalent
  `LOCAL_PEERCRED`). Single instance enforced by an O_EXCL pidfile + socket bind.
- Single-threaded event loop. ALL mutations serialize through one queue. Long
  operations (a `claude -p` ping turn, an OAuth refresh) run as subprocesses awaited
  by the loop, but bank/keychain WRITES happen only on the loop thread — one writer,
  zero locks, zero lock-reclaim logic, zero ABA.

### Ownership model (never-copy)
- Each account credential has exactly ONE owner store at any time:
  - `exclusive` account, active → the macOS keychain owns it (Claude Code uses it).
  - `exclusive` account, parked → its bank file owns it.
  - `monitor_only` account → its **dedicated grant dir** owns it (see below); the
    account's terminal credential is never held at all.
- **swap(target)** = ownership transfer transaction, in-process:
  1. archive current keychain blob → `archive/<email>.<utc>.json` (fsync)
  2. adopt keychain blob into outgoing account's bank file (it becomes owner)
  3. install target's bank blob into keychain; target's bank file marked non-owner
     (kept only as last-known metadata, clearly flagged `owner: keychain`)
  4. verify readback fingerprint == target; on ANY doubt: restore from archive, report.
  All four steps in one event-loop turn + subprocess-free (keychain via `security`
  subprocess but awaited serially; no other mutator can interleave — there is no other
  mutator).
- **Never-destroy invariant:** every blob replacement (keychain or bank file) archives
  the predecessor first. Bounded: last 10 per account, pruned oldest. Archive is the
  recovery story for every residual race, including external /login collisions.

### Dedicated monitoring grants (cross-platform accounts)
- For `monitor_only` accounts (used on phone/desktop/web), QuotaBar runs a ONE-TIME
  interactive `claude /login` into an isolated `CLAUDE_CONFIG_DIR` under
  `~/.claude/accounts/grants/<email>/`. That grant's refresh token belongs to bankd
  alone — the phone/desktop/web clients hold their own separate grants and can never
  spend ours.
- The usage endpoint reports ACCOUNT-level usage regardless of which client consumed
  it → full cross-platform tracking with zero custody risk to the user's other logins.
- If a monitoring grant dies anyway (server-side revocation): the card shows
  "reconnect" and NOTHING else degrades. No terminal impact, no re-bank of anything.
- `exclusive` accounts need no grant dir (their credential is already ours).

### /login collision handling (the irreducible race, contained)
- bankd watches the keychain (poll on use + before any mutation) and compares the live
  fingerprint against the identity primitive: fingerprint ∈ exactly one owned blob AND
  metadata agrees → resolved; anything else → UNRESOLVED.
- UNRESOLVED = bankd freezes ALL mutating ops, archives the unknown blob (never
  destroys it), surfaces a QuotaBar card action: "New login detected — adopt as
  <email>? / restore previous?". Human resolves ambiguity; nothing is lost meanwhile.
- This replaces v1's reconcile.py entirely: no journal replay, because there are no
  multi-process torn writes to reconcile. bankd's own crash-mid-write safety =
  write-ahead temp file + atomic rename (trivially safe with a single writer).

### API (JSON-RPC over the socket)
- `status()` → full snapshot (accounts, usage, freshness, alerts) — what QuotaBar renders.
- `refresh(scope)` → poll usage (tiered/burst rules move here from usage.py).
- `swap(email)`, `bank_current(email)`, `remove(email)`, `set_mode(email, exclusive|monitor_only)`,
  `ping(email)`, `set_autoping(email, bool)`, `adopt_login(email)`, `restore_archive(email, ts)`.
- Auth: socket file perms + peer-uid check. No TCP, ever.

### What v1 code survives
- `usage.py`'s endpoint/tiering/burst logic → imported as a module by bankd.
- The r3–r5 identity primitive + archive helper → bankd's core (built for this).
- The 144+-assertion test suite → ported to drive bankd's API against stub stores.
- swap-account.sh etc. become thin `bankd-cli` wrappers (kept for scripting).
- QuotaBar.app: ProcessRunner swaps script exec for socket calls (UI unchanged).

### Failure modes (design targets)
- bankd down → QuotaBar shows "broker offline" + launchd restarts it; NO caller falls
  back to direct mutation (fail-closed: no broker, no writes anywhere).
- Mac asleep at ping/poll time → next wake catches up (launchd + monotonic scheduling).
- Power loss mid-write → temp+rename atomicity; archive holds predecessor.
- Server-side revocation of an exclusive parked token → needs-relogin card, same
  recovery as today, but with archive forensics (we can prove WE didn't spend it).

## Migration plan
1. Build bankd + tests (stub keychain/stub claude, same discipline as v1 suite).
2. Shadow mode: bankd runs read-only alongside v1 scripts for N days; QuotaBar still
   on scripts. Compare snapshots.
3. Cutover: QuotaBar → socket; scripts become wrappers; v1 lock/journal/reconcile
   deleted. <pro-account> → monitor_only (one-time grant login by owner).
4. OSS: ship as v2.0.0 after the same adversarial review gauntlet (fresh Codex rounds
   on bankd itself).

> Account placeholders (`<max-account>`, `<pro-account>`) stand in for the author's real
> addresses throughout these design docs. The actual mapping lives only in the owner's
> local notes and is never published here.

## Non-goals
- No multi-user, no TCP, no cloud sync. One Mac, one user.
- No auto-updating of bankd (Homebrew handles distribution).
- Windows/Linux out of scope (keychain + launchd assumptions).
