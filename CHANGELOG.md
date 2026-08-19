# Changelog

All notable changes to QuotaBar. Full notes on each [GitHub release](https://github.com/ronit111/quotabar/releases).

## Unreleased

- **v111-r2 — two failure-path holes in the re-login flow.** (1) The banked
  credential is now ASSERTED to be the one the login captured.
  `bank-account.sh` re-reads the credential itself through `cred_read`, whose
  shape gate accepts a config dir's file only when the raw text carries
  `claudeAiOauth`/`oauth` — a flat blob fell through to the bare default slot,
  i.e. the ACTIVE account, and every downstream identity check still agreed
  because the email came from the target's own metadata, so the flow could report
  success with another account's tokens banked under the target's name. The
  fingerprints must now match; a mismatch is a hard failure and the pre-bank
  record is restored. `cred_read` is deliberately unchanged. (2) A pending-relogin
  journal makes an abandoned login recoverable: the config dir is recorded before
  the Terminal opens, so the per-config-dir keychain slot stays recomputable even
  if the flow is killed or the machine reboots mid-login; every abandoning path
  now terminates the login process and closes its window BEFORE deleting the dir
  (previously a login completed after a timeout wrote a live credential into a
  slot nothing could ever find again); and every entry sweeps stale entries. The
  journal doubles as the double-invocation guard — a second Re-bank while one is
  pending is refused rather than opening a second window, which the app cannot
  enforce because its busy guard clears as soon as the flow detaches.

- **One-click recovery for a revoked account (v111)**: a `needs-relogin` card
  used to need a manual ceremony — an isolated `/login`, a hand-materialized
  credential, then `bank-account.sh` pinned to that dir. Re-bank now does all of
  it. QuotaBar passes the card's email, so `bank-account.sh` can tell "capture
  the live login" from "this account's grant is dead" and hand the second case to
  the new `relogin-account.sh`: throwaway config dir inside the bank (0700), a
  Terminal window running `CLAUDE_CONFIG_DIR=<dir> claude` (the default seat is
  never touched, so running sessions never notice), seat watched for the
  credential the login writes, the G9 profile oracle required to positively name
  the target, materialize, then the UNMODIFIED bank ceremony, then the config
  dir and every keychain slot its path spellings produced are deleted, the
  auto-ping breaker cleared, and a forced poll heals the card. Picking the wrong
  account in the browser is refused and cleaned up, never banked; a seat read
  that ERRORS stays UNKNOWN and keeps waiting rather than becoming a verdict; the
  bank lock is never held across the human wait. Invoked without a tty it
  detaches so the app's action queue is not blocked behind a login, and the card
  reads "Login window opened" rather than falsely claiming "Re-banked".
  Re-banking a healthy PARKED card now refuses instead of silently snapshotting
  whichever account happened to be active. Success is graded by the first live
  poll, not by the capture.

- **Revocation notifications (v111)**: the moment a record first arms
  `needs-relogin` — `usage.py`'s `set_bank_status`, `_ping_marker.py`'s
  confirmed-dead stamp, or a v2 home stamping `needs_login_since` — a macOS
  notification fires, so a shared-account revocation is noticed now instead of
  whenever someone next looks at the menu bar. Debounced once per arming (the
  pollers re-derive the state every cycle); any return to health re-arms it.
  `ACCOUNT_BANK_NOTIFY=0` silences it.

- **Swap verifies the target credential live before committing (v110)**: a
  schema-valid bank record is not a live credential — on a shared account a
  co-user's `/login` revokes the banked grant server-side while every offline
  field still reads fresh. The swap now proves the target with one real turn in
  an isolated config dir (the same ceremony parked pings use) before any
  keychain mutation: a confirmed-dead target marks needs-relogin and aborts with
  the recovery path, a transient failure aborts retriable, and the active
  account is never touched. `ACCOUNT_BANK_SKIP_TARGET_VERIFY=1` bypasses for
  offline/emergency swaps. The app's mutating-action budget rises 90s -> 240s to
  cover the pre-flight's two 60s-capped turn attempts.

- **The refresh readback follows the seat (v110)**: recent Claude Code migrates
  ANY config dir's file credential into its per-config-dir keychain slot and
  deletes the file, and records a cleared login by blanking the blob — so the
  file-only readback quarantined every refresh and orphan slots accumulated one
  per turn. The readback now reads file-then-slot, classifies a blanked slot as
  the CLI's cleared-login stamp (dead only with a confirmed auth signature),
  deletes the harvested orphan slot, and records candidate slot service names
  beside anything quarantined. An offline `refreshTokenExpiresAt` lapse is no
  longer death evidence — records freeze during outages, so only a confirmed
  rejection may mark needs-relogin.

- **Two loud health canaries (v110)**: `credential_substrate` (active identity
  present but no credential readable through any known seat form — the
  storage-moved-again signature; explicitly not a `/login` fix; armed only on a
  confirmed double absence) and `scripts_drift` (the app executing
  release-frozen bundled scripts that differ from the maintained copy). Both
  render as health rows in the popover. `make install-linked` points a local
  install's bundled scripts at the maintained dir so drift is structurally
  impossible between releases.

- **The poller reads the active credential where the CLI stores it (v110)**: the
  usage poll was still slot-only after v107, so identity never bound and the
  active card rendered only through its bank record (including a duplicate row).
  Tri-state read, file first — and a present-but-unreadable/blanked file never
  falls back to the stale pre-migration slot.

- **A blanked home seat arms the auto-ping breaker (v109)**: a readable blob
  with empty tokens is as credential-less as a deleted one, and only a real read
  can observe it — a locked keychain still reads as UNKNOWN and never arms.


- **Writes follow the seat too (v108)**: v107 made reads file-aware, but
  `kc_write` still wrote the keychain slot — so a swap wrote a place the CLI no
  longer reads and switched nothing. Rather than duplicate `kc_write`'s ceremony
  (epoch gate, schema validation, archive-before-destroy, snapshot, pre-write
  recheck, post-write verify) for a second backend, the seat is now a detail of
  that one ceremony: a file seat is written atomically at 0600 and verified by
  re-reading the file. Swap, ping, plan-stamp repair and torn-swap reconciliation
  all follow the same seat. Redirected credential reads always mean the slot, so
  the hermetic suite can neither read nor overwrite a real credential file. The
  seeding freeze/unfreeze paths deliberately still read the slot — they verify a
  fingerprint they themselves journaled, and must keep checking what they froze.

- **Reads the credential where Claude Code actually stores it (v107)**: current
  Claude Code keeps the active account's credential in
  `$CLAUDE_CONFIG_DIR/.credentials.json`, and no longer writes the bare keychain
  slot this bank was built against. Banking therefore failed with "no credentials
  found in keychain" while the user was perfectly logged in, so the bank record
  froze and every card served a cached figure indefinitely. A new `cred_read`
  applies the same precedence `seat_read` already uses for pinned homes — a
  present, non-empty file wins, else the slot — so a file/slot migration is a seat
  change rather than a lost credential. It is deliberately not folded into
  `kc_read`, whose post-write verification must keep re-reading the slot it wrote,
  and it defers to the slot whenever credential reads are redirected (stubbed or
  faked), so a sandboxed caller can never be handed the real token.

- **A stale card now says why it is stale (v106)**: when a live fetch failed
  the poller served the last good reading with `error: None` and status "ok",
  so a card could sit on a 20-hour-old figure looking healthy with no way to
  tell a brief blip from a credential that expired yesterday. The failed
  attempt's reason is now carried onto the served row (`stale_error`, plus
  `stale_since`) without altering the cached figures. The case that exposed
  this also had a misleading message: an expired token on an account that
  classification called parked but the live re-derivation called active was
  reported as a transient poll race ("became active during poll") and repeated
  every cycle; it now reports the real, actionable state — an expired active
  token that this poller never refreshes by design.

- **Needs-login breaker requires a provably-absent seat (v105.1)**: the
  v105 classifier trusted the ping turn's own message, but a caller that
  cannot read the keychain (locked, denied, or headless) gets the identical
  "not logged in" text for a perfectly healthy credential — so a diagnostic
  run from the wrong context could stand auto-ping down on a working home.
  The verdict is now corroborated against the seat itself and only a
  provably-absent seat arms the breaker; an unreadable seat is treated as
  unknown and falls back to ordinary backoff.

- **Auto-ping no longer hot-loops on a home it cannot fix (v105)**: the
  post-failure debounce was flat at 5 minutes, so a home whose credential was
  gone got re-pinged every poll cycle indefinitely — 60 consecutive failures
  over ~33 hours were observed on both homes before anyone noticed, and nothing
  upstream could have stopped it (v104's expired-seat-token trigger stays true
  forever on such a home). The ping turn's output was also discarded, so "no
  credential at all" was indistinguishable from a network blip. Now the turn's
  output is captured, classified and deleted without ever being logged; a home
  reporting no credential is skipped by auto-ping until a login makes a ping
  succeed; and consecutive failures double the cooldown up to a 6-hour cap, so
  a broken home costs a handful of turns per day instead of ~144. Any success
  clears both brakes, and the manual Ping button is deliberately unchanged so a
  fresh login can always be verified by hand. Transient responses (403, 429,
  timeout, network) veto the no-credential verdict, matching the existing
  fail-closed posture for parked-token death.

- **Idle-home staleness fix (v104)**: a monitored (parked) home's token
  idle-expires ~8h after its last turn; polls then served the cached row for
  hours ("cached Nm ago") because the auto-ping lapse check read that same
  stale row. An expired home seat token is now a lapse-equivalent auto-ping
  trigger, checked live and fail-closed (validated credential only), with the
  existing cooldown and one-per-cycle gates unchanged.

- **Frozen plan-stamp heal (v103)**: the keychain credential's plan stamp is
  written only at login, so a plan change on the active account froze it and
  the crossed-identity gate refused every re-bank (empty card + UNLINKED twin).
  The poll heal now banks an oracle-attested corrected copy — displays,
  linking, and auto-pick recover with no re-login. Two review rounds, fixed to
  clean; one finding ruled benign-by-design in-code.
- **`heal-plan-stamp.sh`**: standalone, oracle-gated repair of the keychain
  stamp itself (full snapshot/archive/recheck write ceremony, post-write
  verification), unfreezing swap and manual re-banks after a plan change
  without a re-login.

## v1.0.2 — 2026-07-26

- **Update hint**: QuotaBar checks GitHub releases once a day (anonymous,
  disclosed in the README, settings toggle) and shows a quiet dismissible
  footer line when a newer version exists.
- **Un-seed flow**: fully remove a pinned/monitored account — registry-verified
  targeting, a launch-admission fence, archive-before-delete of every
  credential seat form.
- **Plan-tier auto-heal**: a plan change on the same account re-links
  automatically (identity-confirmed) with a one-time notice.
- **Pinned session launcher** on each account card.
- Visual: continuous gauge color ramp, live Ping countdown, friendly plan
  chips ("MAX 20×"), tightened health-banner rhythm.
- SessionStart hook announcements debounced.
- Three review rounds on the delta, fixed to clean.

## v1.0.1 — 2026-07-26

- **Benign credential drift auto-heals** during polls (identity-confirmed via
  the account API); the UNLINKED chip now appears only for genuine problems.
- Binding cross-vendor security audit of v1.0.0: 17 findings fixed — crash-
  durable swap transaction, fail-closed account removal, archiver daemon
  single-instancing with upgrade preflight, unified data-dir resolution,
  bundled-runtime preference on upgrade, clean runtime-only release bundle,
  version-guarded releases.

## v1.0.0 — 2026-07-25

- First public release: menu-bar meters for multiple Claude Code accounts,
  seamless journaled account swap, auto-pick and auto-ping, opt-in pinned
  sessions, Homebrew tap.
