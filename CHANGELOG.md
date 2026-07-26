# Changelog

All notable changes to QuotaBar. Full notes on each [GitHub release](https://github.com/ronit111/quotabar/releases).

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
