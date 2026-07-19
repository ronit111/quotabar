# Contributing

Thanks for taking a look. This is a small, focused project and contributions are
welcome.

## Ground rules

- **Never commit credentials or personal data.** No account emails, tokens,
  keychain blobs, session IDs, cost figures, or hardcoded absolute home paths
  (`~/…` is fine, a literal home path under your username is not). Runtime
  state lives outside the repo (`~/.local/share/quotabar`); test fixtures use
  `example.com` addresses and synthetic numbers only.
- **Keep the security posture.** The scripts follow strict invariants (lock-first,
  atomic writes, secrets via stdin never argv, fail-closed keychain writes,
  exact-match keychain selector). If you change anything under `scripts/`, read
  the "Safety invariants" section of `scripts/README.md` first and preserve them.
- **The app stays offline.** `app/` makes no network calls of its own — all data
  comes from the scripts. The `make audit` target enforces this (no `URLSession`,
  keychain, analytics, or logging APIs). Keep it green.

## Building and testing

```sh
cd app
make test        # run the Swift unit tests
make typecheck   # type-check without building
make audit       # enforce the app's no-network / no-credentials invariants
make verify      # build the .app bundle and validate it
```

For the scripts, `python3 -m py_compile *.py` and `bash -n *.sh` catch syntax
errors; there is no network dependency to mock.

## Notes

- Both provider usage endpoints (Anthropic and OpenAI/Codex) are **undocumented**
  and can change or break without notice. Fixes that adapt to endpoint changes are
  the most likely kind of maintenance this project needs.
- macOS 14+ only. The app is ad-hoc signed; there is no notarized distribution.
