# Changelog

All notable changes to QuotaBar. Full notes on each [GitHub release](https://github.com/ronit111/quotabar/releases).

## Unreleased

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
