# QuotaBar — Session Handoff (updated 2026-07-24 ~21:50 IST, post-ROLLBACK)

Resume point. Read FULLY. Supersedes all prior handoffs.

## RELEASED: v1.0.0 IS PUBLIC (2026-07-25 00:15 IST)
Tag v1.0.0 on main (squash-merged; leaky wip history never reached main; remote
wip branch deleted, full history kept locally). GitHub release carries
QuotaBar-1.0.0.zip (sha256 verified against the published cask). Homebrew tap
ronit111/homebrew-quotabar is live: `brew tap ronit111/quotabar && brew install
--cask quotabar`. Shipped as the HYBRID framing. Remaining review debt: binding
cross-vendor Codex r15 (Jul 29+) now audits a RELEASED surface — findings become
v1.0.1.

## STATE IN ONE PARAGRAPH

Epoch = **shadow again (gen 19), BY OWNER DECISION** — not a failure. The flip to v2
happened 2026-07-24 18:39 (gen 18) and verified clean on every check (attestation 8/8,
pinned launch, autonomous auto-ping 19:01, Switch repoint both directions, drift class
dead). The owner then lived with v2 for one evening and **rejected pin-at-launch UX**: they
want seamless in-session switching (v1 turn-level pickup — mid-convo account moves,
mid-flight agent migration) and accept v1's failure modes as the price. Rolled back
same evening per design §8 exact inverse: `flip.py to shadow` + shim deleted + PATH
lines removed. v1 rails fully live (`/swap`/swap-account.sh, auto-ping, autopick).
**New direction: v3 "seat-swap"** — seamless switching *within* v2's structure
(pickup is turn-level PER CONFIG DIR, so rewriting the active home's keychain-slot
credential reroutes every session pinned to that home on their next request; the
shared-mutable-credential class returns but scoped to one home). Design + review
cycle required before any build.

## WHY (decision record, don't relitigate without new evidence)

- The owner's Switch use case = moving work to another account RIGHT BEFORE limits,
  including mid-conversation and mid-agent-run. v2's restart-with-resume covers the
  interactive case (one click, seconds) but NOT busy agents/loops — and they judged
  the whole restart ceremony worse than v1's silent-reroute failure modes.
- v1 failure modes they re-accept: sessions can drop off Fable when the active
  account changes under them; ~daily UNLINKED fingerprint drift (one-click Link);
  quota attribution = whatever was active.
- v2 work is PARKED, not discarded: homes stay seeded/READY, registry + archiver
  keep running (shadow-legal), epoch-aware app handles shadow, all hardening +
  gates + tests remain. Seat-swap would reuse nearly all of it.

## KNOWN POST-ROLLBACK FACTS

- The owner's session opened 19:00 Jul 24 is PINNED to <max-account>'s home (env persists);
  a v1 /swap will NOT move it. Fresh tabs launch unpinned (bare keychain) — it
  self-resolves when that session exits.
- The legacy default-slot credential is the active rail again (the popover's
  "unlinked" card concern from the v2 evening is moot under shadow).
- **QuotaBar app Swap button RESTORED (2026-07-24, rollback-day).** The Switch
  button is now epoch-aware: under v1/shadow it is "Swap here" → `swap-account.sh
  <email> --expect-active <active>` (the v1 seamless swap, same FIFO/non-SIGKILL
  path, optimistic flip + confirm); under v2 it stays "Switch here" =
  claude-acct --switch repoint + restart offers. Routing: only v2 repoints now
  (`EpochState.usesRepointSwitch == (self == .v2)`); shadow takes the swap path
  while still showing health (archiver runs in shadow). Built + installed.
  NOTE: the live app source `~/Developer/quotabar` had been left as a STALE 22-Jul
  pre-v2 snapshot (older than the installed v2 binary + the git mirror); it was
  restored from `quotabar-oss/app` (git HEAD) before this change, then re-synced.
- lib.sh `list_bank_emails` now skips v2 control-plane JSON (archiver.status etc.
  rendered as "banked accounts" in swap/remove help — found during rollback; keep
  in sync with bank_common.V2_CONTROL_JSON).
- Fork-drift/seed-audit health rows may still show (archiver runs in shadow) —
  runtime-file watchlist exclusion still worth building.

## OPEN ITEMS (in order)

1. ~~Restore a Swap button in QuotaBar~~ **DONE 2026-07-24** (epoch-aware Swap
   under v1/shadow via swap-account.sh --expect-active; Switch=repoint under v2).
2. **Binding Codex r15** (after Jul 29 2:57 PM IST — Apple Reminder set 3:05 PM):
   still valuable — it reviews the whole system incl. flip-sitting attest fixes +
   rollback-day lib.sh fix. Same harness, medium effort, NO prior findings fed:
   `codex exec --sandbox read-only -c 'plugins."codex-orchestration@codex-orchestration".enabled=false' --config 'mcp_servers={}' -c 'model_reasoning_effort="medium"' "<prompt>" </dev/null > out.txt 2>&1`
3. ~~**Release strategy decision**~~ **DECIDED 2026-07-24: v1.0.0 ships TONIGHT
   framed as the HYBRID** — "seamless shared rail + opt-in pinned sessions", which
   is the honest description of what the author actually runs (SEAT-SWAP-DESIGN.md
   Option A). Not held for seat-swap v3; not shipped as v2-as-designed. The v2
   pin-at-launch machinery ships as documented-optional (`install.sh --with-pinning`),
   with ISOLATION-DESIGN.md banner-flagged as the optional mode. Homebrew tap
   `ronit111/quotabar`, cask `quotabar`, goes live with the release.
4. **Seat-swap v3 design: DRAFTED 2026-07-24 → `SEAT-SWAP-DESIGN.md`** (v0, for
   r15 cross-vendor review). Recommendation is Option A "permanent-shadow
   hybrid": shared rail by default (v1 /swap seamlessness), homes as OPT-IN
   per-session pinning — i.e., the current post-rollback state IS the v3
   architecture; near-zero build (pinned-launch affordance + rail/pinned session
   labeling remain). Option B (rewriting home seats in place) documented and
   rejected — it recreates the shared-mutable-credential drift class inside v2's
   structure. r15 review asks are listed in the doc.
5. Backlog (unchanged value, lower priority now).
   DONE in the v1.0.1 confirmation pass (2026-07-26), both previously listed here:
   - SessionStart hook identity residual CLOSED. The hook no longer re-banks
     ambiguous drift at all: it re-banks only what it can prove offline (an
     UNCHANGED access token whose refresh/expiry rotated — an access token is
     issued to exactly one account) via `bank_common.hook_rebank_refusal`, and
     ANNOUNCES every deferral to the oracle-gated poll heal. No oracle HTTP call
     was added inside the 5s hook budget; the hazard is avoided, not traded.
     RESIDUAL (deliberate, documented in usage.py `_benign_drift_refusal`): a
     PLAN-TIER change is now the one drift class NEITHER path writes
     automatically — the hook announces it and names `bank-account.sh`, the poll
     still refuses it. Rare and user-initiated; revisit only with a real reason.
   - archiverd single-instance enforcement COMPLETE. The v101 lock coordinates
     new-code daemons; the upgrade preflight (`archiverd.other_archiverd_pids`,
     after lock acquisition) now also catches a PRE-upgrade daemon, which holds
     no lock — same uid, python argv[0], an argument whose basename is
     archiverd.py, not `--once`/`--converge`, and the SAME bank (read from the
     candidate's own env via `ps -E`). install.sh --with-pinning warns with the
     same detector before writing the plist.
   Still open: un-seed flow; pre-limit nudge;
   limit-stalled restart offer; hide "Link account" under v2; legacy-login card
   re-caption — plus v1.0.1 visual candidates from the release-eve polish pass (each
   needs a small logic change, deliberately deferred): collapse the health-banner
   gap (PopoverLayout.estimatedHeight couples to it), continuous gauge color ramp
   (Severity is 3-step model-side), live ticking Ping countdown (needs a timer),
   friendly plan-chip names (raw backend strings like MAX_20X render uppercased).
   (fork-drift runtime-file exclusion DONE 2026-07-24 — archiverd.py
   `_drift_check` now skips daemon.lock/daemon.status.json/gh-pr-status-cache.json
   + any *.lock.)

## STANDING FACTS (see reference_account_bank_quotabar.md memory for the rest)

- Accounts appear here as placeholders (`<max-account>`, `<pro-account>`) only. The
  real address-to-account mapping lives solely in the owner's local memory and is
  never written into this repo.

- Credential pickup is TURN-level PER CONFIG DIR (G5c + lived evidence): the
  default slot for unpinned sessions, `Claude Code-credentials-<sha256(dir)[:8]>`
  for pinned ones. This is the fact seat-swap v3 stands on.
- Worker≠judge: Codex reviews (medium effort), Claude/Opus fixes. NEVER feed prior
  findings into a review prompt (r7 contamination). Same-vendor review = interim-only.
- Both trees byte-synced always: ~/.claude/scripts/account-bank ↔ quotabar-oss/scripts
  (retired-file diffs + `retired/` dir + repo-root install.sh are known-OK
  exceptions). Full suites: `bash tests/run_tests.sh` in each.
- Rollback inverse (if v2 ever returns): re-stage shim from scripts/bin, re-add
  PATH lines (zprofile+zshrc), attest (per-PID acks; gate now excludes its own
  process tree), flip. All gates/fixes from 2026-07-24 remain valid.
- launchctl print gui/<uid>: loaded jobs = `services = {` table, NOT the `=> ` map.
- A `/login` changes the ACTIVE account (plan → Fable/Max gating): if a session
  drops off Fable, check the active account, re-bank + /swap back.
