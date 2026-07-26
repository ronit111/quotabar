# Per-account isolation + pinned-session swap (QuotaBar v2 — HYBRID) — rev 9

> **Read this first.** This document specifies the **optional v2 pin-at-launch mode**,
> which is **not** what QuotaBar ships by default. The shipped default is the hybrid:
> a shared credential rail moved seamlessly by `swap-account.sh`, plus opt-in pinned
> sessions via `claude-acct <email>` — see [`SEAT-SWAP-DESIGN.md`](SEAT-SWAP-DESIGN.md)
> and the "How it works" section of the [README](README.md). **Shadow is the terminal
> operating state** by owner decision on 2026-07-24; the cutover machinery described
> below (attest/flip) remains as dormant, tested, optional machinery and is off the
> default install path. Everything after this banner is the v2 specification as
> written, unchanged.

Status: **DRAFT rev 9 — under adversarial design review (r1: 8 → r2: 6 → r3: 5 →
r4: 3 → r5: 2 → r6: 2 → r7: 2 — r7 caught a silent no-op edit: the r6-prescribed §7 text had not actually landed; rev 8 lands it verbatim + closes r7 B1 gaps).
The ONE product-visible change (§0) is flagged for owner ratification. Foundation +
gate modules are built and suite-green (epoch, identity, homewrite, repoint,
registry, shim/claude-acct, archiverd, sessions, autopick_v2, seedflow, v1 fences —
143 v2 assertions + full v1 suite).**
Decision record: the owner picked **Hybrid** 2026-07-21. Reviews r1–r3 are internal
review artifacts, not published.

## §0 — THE PRODUCT CHANGE (conservative call, owner may veto in the morning)

Rev 3 proposed live-flipping running sessions via per-turn pointer traversal, gated on
access-token expiry. **Round 3 refuted the gate with upstream fact:** Claude Code also
refreshes reactively on HTTP 401 / server-side revocation, independent of local
`expiresAt`. A refresh can therefore straddle a repoint with hours left on the clock —
no local gate fences it. An unfenceable credential race is the disease this project
exists to kill; we do not ship it again behind a probability argument.

**Rev 4 model: PIN AT LAUNCH.**
- The shim resolves the pointer ONCE at launch and execs with the resolved REAL home
  path. Every session's identity is immutable for its lifetime. The straddle class
  does not exist. Repoint needs no gate and can run at any time.
- **Switch UX = "future + assisted restart," as a PROVEN transaction (r4 NEW-1):**
  QuotaBar Switch repoints (future launches open on the target) AND offers restart of
  running sessions — under this contract, backed by the session registry (§13):
  1. Only REGISTERED sessions ({session-id, home, cwd, pid, proc-start-time,
     transcript-path} from hooks) are candidates.
  2. **Idle is TRACKED lifecycle state, never inferred (r5 blocker 1; r6 edge
     fix):** the IDLE edge is `Notification: idle_prompt` (fires when the CLI is
     genuinely waiting for the next prompt) — NOT the Stop hook, which another
     parallel Stop hook can override to continue the turn (upstream-documented).
     `UserPromptSubmit` records BUSY **write-ahead and fail-closed: our hook exits
     blocking (2) if it cannot persist BUSY**, so a persistence failure can never
     leave an active turn recorded IDLE. A missing/failed idle notification leaves
     the session BUSY (safe). No mtime heuristics, no child-process scans.
  3. **Per-session transition lease:** restart AND prompt admission contend for the
     same lease (atomic mkdir `accounts/sessions/<id>.lease/` + owner record).
     Restart: acquire lease → verify state IDLE → transition IDLE→RESTARTING (while
     held, the UserPromptSubmit hook BLOCKS new prompts in that session with an
     explanatory message) → SIGTERM {pid} → verify {pid, proc-start-time} exited →
     transcript settle → `claude-acct <email> --resume <id>` from the ORIGINAL cwd.
     **The lease is released only per step 4's journal (at REGISTERED — never at
     launch).** Duplicate restarts are impossible (lease); registry records are
     serialized under a sessions lock with generations + tombstones.
  4. **The restart controller keeps its own durable phase journal (r6/r7):**
     LEASED → STOPPING → STOPPED(verified exit) → SPAWNED{expected child pid +
     proc-start-time + target home} → REGISTERED. **REGISTERED is
     transaction-bound (r7):** it requires the successor's SessionStart registry
     entry to match the journaled transaction — same session-id AND the journaled
     expected child pid/proc-start-time AND the journaled target home AND a
     registry generation newer than the journaled pre-spawn generation. An
     unrelated or duplicate resume can never satisfy it (sweeper races included).
     **The lease is released ONLY at REGISTERED** — never at spawn. Stale-recovery
     rules are EXHAUSTIVE (r7): LEASED/STOPPING with predecessor ALIVE → release +
     no action; **STOPPING with predecessor DEAD → remain blocked + operator card**
     (the kill may have landed without STOPPED recorded); STOPPED/SPAWNED without
     REGISTERED → remain blocked + operator card (never a second spawn from
     recovery); **ABORTED with the lease still present → release the lease, no
     action** (the abort record is the transaction's terminal state); any other
     journal state → blocked + operator card. Stop timeout/failure → journal
     ABORTED, lease released, NO resume launch, manual step surfaced. A resume is
     never issued while the predecessor is alive, and duplicate resume is
     structurally impossible (lease + journal + G10's post-spawn/pre-registration
     duplicate test).
  5. **Accepted residual (owner):** kill(pid) after a start-time check is not atomic;
     the theoretical wrong-PID SIGTERM window (session exits and the OS reuses its
     pid between check and signal) is accepted as negligible-and-bounded rather than
     claimed impossible. No "PID-reuse-proof" claim is made.
  Because `projects/` is shared (§6), the SAME conversation continues on the new
  account — mid-session swap's actual value, with zero credential race and zero
  transcript interleave. Cross-home resume continuity is release-gated by G10 (§12).
- **Appendix A** preserves the live-flip variant + its accepted-residual analysis, in
  case the owner overrides. It is NOT the default and failed review.

## Empirical results (gates.py + curl, live CLI/API, macOS, 2026-07-21)

- **G1 — per-turn credential-file re-read: CONFIRMED.**
- **G2 — pointer symlink traversed per turn: CONFIRMED** (now moot for sessions — §0
  pins at launch — but proves the pointer must NEVER be passed as CLAUDE_CONFIG_DIR).
- **G3 — file beats keychain when CLAUDE_CONFIG_DIR set: CONFIRMED.**
- **G4 — bare-home scaffold:** `.claude.json`, `projects/…`, `backups/…`.
- **G9 — endpoint identity primitive: CONFIRMED (r3 NEW-1 closed with data).**
  `GET https://api.anthropic.com/api/oauth/profile`, headers
  `Authorization: Bearer <accessToken>` + `anthropic-beta: oauth-2025-04-20`:
  returns `account.uuid` (immutable id), `account.email`, plan booleans,
  `organization.rate_limit_tier`. Read-only GET; measured: no credential file/keychain
  write, no rotation. **Identity contract:** blob → identity = (uuid, email) from this
  endpoint. Classifications: 200+parse → RESOLVED; 401/403 with structured auth
  signature → INVALID-CREDENTIAL; network/timeout/5xx/other → INDETERMINATE (never a
  verdict, retry later; fail-closed for mutations). Timeout 15s. Never logged with
  token material.

Open gates (owner-present, morning): **G5** (/login write target), **G6** (same-account
dual-grant), **G8** (same-home two-process forced refresh). Build-time: **G7**
(archiver). G7/G8 acceptance contracts in §12 (r3: binary criteria, not "observe").

## The disease

1. **Storage collision** — the shared keychain slot other platforms write. Cured: homes
   bypass it (G3).
2. **Grant collision** — copied rotating tokens. Cured: one grant per home, minted by
   its own login (§7); never copied (bounded seeding exception under quiescence+CAS).

## Core architecture

### 1. Permanent per-account homes

```
~/.claude/accounts/homes/<safe-email>/
  .credentials.json   # THIS home's grant (0600) — single source of truth
  .claude.json        # PER-HOME (accepted-cost fork)
  backups/  archive/  # PER-HOME
  <else>              # symlinks into ~/.claude per the State matrix (§6)
```

Bank files = derived metadata only (plan, usage cache, resets_at, status, cooldowns).

### 2. Grant model

One independent grant per home. Cross-account same-client concurrency: production-proven
on this machine. Same-account dual grants: G6 verification; contingency = one reconnect,
detected by the v1 auth-death classifier (carried verbatim). Account-wide session
revocation kills all homes → all-cards-reconnect, N logins; accepted, no stronger claim.

### 3. Launcher, shim, real binary (r3 NEW-2/shim: FAIL-CLOSED)

- **Registry:** `REAL_CLAUDE_BIN` recorded at install in `accounts/.config.json`.
- **Resolver v2 contract:** candidates from (1) `ACCOUNT_BANK_CLAUDE_BIN`, (2) registry,
  (3) PATH, (4) known locations — EVERY candidate (all four sources, r3) is
  canonicalized (realpath — the installed CLI is itself a symlink to a versioned
  binary; compare post-canonicalization paths AND dev/inode) and REJECTED if it
  resides under `accounts/bin/` or matches the shim's dev/inode. Executable regular
  file required. Unresolved = transient error, never fallback-to-shim.
- **Shim** (`accounts/bin/claude`, PATH-prepended, never installed over the real CLI).
  **Rule precedence (r4 MAJOR): the marker is evaluated FIRST.**
  1. `CLAUDE_ACCT_SHIM=1` present → `CLAUDE_CONFIG_DIR` MUST canonicalize to a
     REGISTERED READY home (§7 registry) → exec real CLI. ANYTHING else (unset,
     non-home, unregistered, non-ready) → **HARD ERROR** with diagnostic. The marker
     is never trusted alone and never falls through to keychain.
  2. No marker, `CLAUDE_CONFIG_DIR` set under `homes/` → must be READY → exec real CLI
     (pinned/internal passthrough).
  3. No marker, `CLAUDE_CONFIG_DIR` set elsewhere → exec real CLI unchanged (user's
     own config dir; never auto-pick).
  4. No marker, unset → auto-pick → resolve pointer to the REAL home path (§4), READY
     required → exec with `CLAUDE_ACCT_SHIM=1 CLAUDE_CONFIG_DIR=<real home>`.
  Wrapper errors NEVER degrade into an unscoped real-CLI invocation (r4 MINOR): every
  failure path exits nonzero with a message. **Exit codes (r5):** 64 usage · 65 email
  unknown / home not READY · 66 marker/config pairing violation · 67 real binary
  unresolved · 78 epoch fence. (0 is unreachable — success is exec.)
- **Pinned launch:** `claude-acct <email>` resolves the home directly; never reads the
  pointer.

### 4. The pointer (bookkeeping, not a live rail)

```
~/.claude/accounts/current -> homes/<safe-email>/
```

Read at exactly two moments: shim launch resolution and QuotaBar display. NEVER passed
to a process as `CLAUDE_CONFIG_DIR` (G2 makes that a live rail; §0 forbids it).

**repoint() transaction (r3 #8 residuals closed):** under the pointer lock (§9):
write fsync'd INTENT record {txn-id, from, to, why, pid, ts} to `pointer.log` → unique
temp symlink → `rename()` → parent-dir fsync → fsync'd COMMIT record {txn-id}.
**Recovery (r4 MAJOR: serialized):** runs ONLY under the pointer lock; re-reads journal
AND live symlink inside the lock; a partial trailing line is first physically
delimited (truncate to the last newline, fsync) before any append; then a fsync'd
SYNTHETIC-COMMIT {txn-id, observed-target} is written — **after validating that the
outstanding intent's target and the observed live target are READY-registered homes
(r5); an observed NON-home target is itself an incident: freeze the pointer path and
surface, never synthesize normality.** `--back` follows commit/synthetic-commit
records only. Concurrent repoint/recovery is impossible by lock; a synthetic commit
can therefore never bind to a target that changed mid-repair.

No expiry gate, no deferral states: with pin-at-launch, repoint is always safe.

### 5. Archiver + home reconciler (tiered never-destroy; r3 kqueue fix)

- **Tier 1 — tooling writes: GUARANTEED.** One write helper: synchronous fsync'd
  pre-archive → temp+rename+fsync → G9 identity check. No other tooling write path.
- **Tier 2 — CLI writes: BEST-EFFORT, health-gated.** launchd KeepAlive python3-stdlib
  kqueue daemon. **Arm protocol (r3 MAJOR closed):** watch the PARENT DIRECTORY first
  (catches renames while file-watches re-arm); per credential file: open by path →
  register kevent → **stabilization loop: compare fstat(fd) vs lstat(path); on
  mismatch close/re-open/re-register until stable** (closes the unlinked-inode
  blind-watch). Health status file carries per-home {armed dev/inode, generation,
  last-event ts} — QuotaBar's archiver card goes warning when process heartbeat OR any
  home's armed inode is stale vs lstat. Startup: full rescan-and-archive. Initial
  durable snapshot at seeding.
- **Residual (honest):** with §0 pinning, misfiles are impossible; CLI writes are
  refresh commits and login/logout in the SAME home. A tier-2 missed intermediate is a
  same-home spent predecessor (worthless) or a logout-clear (recovered by re-login;
  surfaced, bounded). 401-reactive refreshes are same-home writes — covered by the
  same argument once the pointer is not a live rail.
- **Home reconciler:** triggered by archiver events, poll-time G9 mismatch, repair
  requests. Precondition: home provably broken (schema-invalid, or G9 says foreign/
  invalid). Under the home lock: re-verify precondition immediately pre-rename →
  temp+rename → post-commit re-read + G9 verify → converge loop (bounded). Never
  touches a home G9 calls healthy-and-own. CLI acknowledged unfenceable; microsecond
  residual accepted with reconnect ceiling + tier-2 archive floor.

### 6. State matrix (r3: control plane excluded)

- **PER-HOME:** `.credentials.json`, `.claude.json`, `backups/`, `archive/`.
- **RESERVED — NEVER projected into homes (r3 MAJOR closed):** `accounts/` in its
  entirety (homes, bank files, EPOCH, locks, pointer + log, shim dir, .config.json —
  the whole v2 control plane). No `<home>/accounts` symlink exists; seed walkers and
  drift scans skip the name unconditionally (kills the recursive cycle).
- **SHARED (dir symlinks):** every other directory in the measured enumeration
  (projects, todos, tasks, file-history, debug, session-env, shell-snapshots, statsig,
  sessions, teams, logs, telemetry, cache, tmp, paste-cache, chrome, daemon, plugins,
  skills, agents, agents-library, commands, commands-archive, scripts, memory, rules,
  workflows, jobs, assistant, design-system, income-pipeline, job-hunt, resume, .git,
  .claude).
- **SHARED (file symlinks, drift-watched):** CLAUDE.md, settings.json,
  settings.local.json, history.jsonl, statusline-command.sh, textedit-wrapper.sh,
  learnings.md, errors.md, feature-requests.md, README.md, .gitignore, .gitattributes,
  remaining files. Fork-drift detector in the archiver; **conflict direction: global
  wins, forked copy archived to the home then re-linked.**
- **Seed-time rule:** dynamic enumeration; unknown entries → shared symlink + seed
  audit log + QuotaBar review card. Rationale (measured): the tree is the owner's
  multi-session-shared system today; isolating unknowns silently breaks workflows.
- Concurrent same-session `--resume` from two homes: UNSUPPORTED, documented;
  session-UUID collision validation at build.

### 7. Seeding protocol (r1#1: G5-conditional; harvest = owner-accepted residual)

`claude-acct --add <email>` (interactive, owner present):
1. **Quiesce (owner-confirmed checklist in the flow):** quit Claude Desktop; close all
   claude sessions; QuotaBar paused; detached v1 jobs killed (pattern sweep).
   **Plus (r4 NEW-2: the freeze is GENERATION-FENCED, not a side-channel):** seeding
   acquires the FULL ordered lock barrier (§8), and — WHILE HOLDING IT, in this
   order (r8: the record must be fully populated before it exists) — snapshots the
   keychain slot, durably archives it (the F0 blob), **increments
   EPOCH.generation**, and only THEN publishes the `SEEDING` marker/journal as one
   already-complete record {txn-id, sequence, fp(F0), F0-archive-path, pgid-fields
   pending}. The barrier releases after publication; `/login` runs after release.
   (The pgid/leader fields are the single permitted later amendment — armed
   write-ahead before the login spawn; a record missing them recovers as RETAIN.) Every v1 mutator's existing pre-write fence (exact
   {state, generation} compare inside its held lock) therefore trips for ANY mutator
   admitted before the freeze — no separate marker check is even required for
   correctness; the marker's presence additionally fails-closed new entrants and
   names the transaction. **Seeding keeps a durable PHASE JOURNAL (r5 blocker 2;
   r6/r7-hardened):** the marker and journal are ONE transaction-bound record —
   {txn-id, monotonic sequence counter, DEDICATED pgid (setsid child) + leader pid +
   leader proc-start-time, fp(F0), F0-archive-path} — **initialized durably at
   freeze, BEFORE `/login` runs**, so recovery can never pair a new marker with an
   old journal (txn-id + sequence must match). Every phase record is a WRITE-AHEAD
   INTENT armed before its side effect; verified postconditions are distinct
   records; the sequence increments monotonically. Phases: QUIESCED →
   LOGIN_STARTED → [G5a: HOME_WRITTEN | G5b: HARVEST_READ{fp(L)} → HOME_WRITTEN →
   RESTORE_STARTED → RESTORED] → VERIFIED → PUBLISHED. The seeding work runs in a
   dedicated setsid process group so descendant containment is enforced, not
   assumed. **Stale-SEEDING recovery** (full barrier, generation increment):
   requires the entire journaled pgid provably dead AND the leader identity
   (pid + proc-start-time) matched, then per-phase rules — and **EVERY clear,
   whatever the phase (RESTORED/VERIFIED/PUBLISHED included), additionally requires
   the live slot fingerprint RE-READ AT CLEAR TIME to equal journaled F0**:
   QUIESCED → clear iff fp==F0; LOGIN_STARTED → clear iff fp==F0, else RETAIN +
   operator card; HARVEST_READ / HOME_WRITTEN / RESTORE_STARTED → RETAIN + operator
   card (journaled fingerprints + the archived F0 blob make restore a one-action
   operator step); RESTORED/VERIFIED/PUBLISHED → clear iff fp==F0, else RETAIN +
   operator card (an external slot change while stale — Desktop, unmanaged CLI —
   must land on a human, never on silent re-admission); **missing, corrupt,
   mismatched-txn, or unknown journal state → RETAIN (the freeze is the default
   answer to every ambiguity)**. Recovery NEVER re-admits v1 while the keychain
   state is unproven. For the minutes of seeding, v1 cannot touch the keychain —
   by fence, not by hope.
2. Skeleton per §6 (+ audit log).
3. (F0 snapshot + archive happened INSIDE step 1's freeze barrier — r8.)
4. `CLAUDE_CONFIG_DIR=<home> claude /login`.
5. **G5 branch:**
   - Home file appeared → G9 identity == target → done. **(If G5 lands here, the
     harvest branch below is DELETED from the build — r3's condition.)**
   - Keychain changed instead → **harvest:** read slot → L; REQUIRE fp(L)≠F0 AND
     G9(L)==target. Tier-1 write of L into the home. Restore: re-read slot; still L →
     write F0 back; re-read confirms F0. **Any mismatch anywhere → ABORT: archive all
     observed blobs, stop writing, home unseeded, operator alert with forensics.**
     Restoration is check-then-write; the microsecond in which an external writer
     could interpose is an **owner-accepted residual** justified by: owner-confirmed
     quiescence (Desktop quit, no sessions), the SEEDING freeze (no v1 mutators), a
     one-time seconds-long window per account-add, and the F0 archive (nothing is
     destroyed even then). This acceptance is explicit, not implied.
6. Verification turn (G1 harness) + G9 check. Initial archiver snapshot. Metadata
   record. Remove SEEDING marker (under bank lock, generation increment).

**READY registry (r4 MAJOR — no unready-home publication):** the home is staged under
`homes/.staging/<safe-email>/` throughout steps 2–6. **Publication order (r5): fsync
the staged tree → rename into `homes/<safe-email>/` → parent-dir fsync → READY
registry commit LAST** (tier-1 write). A crash leaves either a staged dir (harmless,
swept) or a reachable-but-unregistered home (recovery re-verifies then publishes or
re-stages — never auto-READY). Shim (§3), repoint (§4), and `claude-acct <email>`
all REFUSE homes without a READY entry — an email is mapped through the registry,
never through raw path construction (r4 MINOR).

### 8. Epoch, shadow, cutover (r3: full protocol)

- `accounts/EPOCH`: `{state: v1|shadow|v2, generation: N}`, atomic temp+rename+fsync.
- **Total lock acquisition order (everywhere, no exceptions):** bank lock → pointer
  lock → home locks in lexicographic safe-email order. All multi-lock holders (epoch
  flip, seeding freeze) follow it; single-lock holders are trivially compatible.
  Timeout at any step → release in exact reverse order, abort, report (no partial
  barriers).
- **Frozen registry:** the flip enumerates homes ONCE under the bank lock into the
  flip transaction; homes cannot be added during a flip (seeding takes the bank lock).
- **Fencing:** every v1 mutator records `{state, generation}` when it acquires its
  lock and re-reads EPOCH inside the held lock immediately before first mutation;
  ANY difference (state OR generation — exact compare, ABA-proof) → release + exit 78.
  The flip increments `generation` on every transition including rollbacks.
- **Tool × state matrix:** v1 mutators: `v1|shadow` (minus SEEDING freeze). v2 repoint/
  home pings/archiver: `shadow|v2`. v2 seeding: `shadow` ONLY, and only under its
  freeze marker (keychain-touching overlap is therefore impossible by construction).
  Shim auto-pick: `v2` only. QuotaBar build is epoch-aware.
- **Cutover (ordered) with LAUNCH-SURFACE ATTESTATION (r4 NEW-3):** the supported
  launch surfaces are enumerated up front: Terminal/iTerm (zsh), VS Code integrated
  terminal, launchd/cron jobs, QuotaBar itself. Cutover: quit AND restart the QuotaBar
  process (a bundle swap does not terminate the old in-memory app) → kill detached v1
  processes (sweep + verify) → install shim → **attest each surface: launch a probe in
  each and verify it resolves the shim; **"surface" means every CONCRETE live launch
  context (r5): each open shell/tab (enumerated via ps), each VS Code window host,
  each actual launchd/cron definition WITH its real command line + environment, and
  the exact old QuotaBar PID — not one representative probe per application class.**
  ANY context failing → cutover ABORTS (shim removed, nothing flipped) → flip to v2
  (full barrier) → verification pass. Existing terminals with cached PATH hashes are
  handled by attestation instructions (`hash -r`/new tabs). The SHARED SessionStart
  hook's `EPOCH==v2 && CLAUDE_CONFIG_DIR unset` check is TELEMETRY, not enforcement
  (r5) — it surfaces escaped launches loudly; it prevents nothing by itself.
  Absolute-path invocation of the real binary is DECLARED UNSUPPORTED but detected.
- **Rollback (exact inverse):** flip to shadow → remove shim → optional v1 QuotaBar.
- Already-running v1-era sessions keep the keychain grant through natural expiry.

### 9. One lock ABI

banklock mkdir protocol (token-owned, PID+start-time owner record, rename-away stale
reclaim — as implemented) at: bank `accounts/.lock/`, pointer `accounts/.pointer.lock/`,
per-home `<home>/.lock/`, sessions `accounts/.sessions.lock/`, and (v102-r2) launch
admission `accounts/.admit.lock/`. Shell mkdir / Python banklock / Swift via helper
script. No flock anywhere. Ordering per §8.

**Launch admission (v102-r2).** `claude-acct` takes ONLY `.admit.lock`, and holds it just
long enough to re-read the READY entry and write `accounts/.admissions/<pid>.json` naming
the home it is about to `exec` onto. Un-seeding takes it LAST in the §8 order (bank →
pointer → homes → admit), refuses while any admission's process is alive, and marks the
registry entry not-READY before releasing it — after which no launcher can resolve the home
at all, so the destructive work runs outside the admission lock. A launcher takes one lock
and never the bank lock, so a pinned launch cannot queue behind a poll holding it across a
network call, and no cycle is possible. An admission lives exactly as long as its pid
(`exec` preserves both pid and start time); DEAD ones are swept on sight, UNKNOWN counts as
live, and an unparseable one refuses. `gate-g8.sh --live` admits through the same fence —
it launches the real CLI too.

### 10. QuotaBar app changes

Switch = repoint + "future sessions → <email>" + assisted restart offer ("Restart N
running session(s) on <email>?" — per-session `claude-acct <email> --resume <id>`;
list is best-effort, labeled "at least N"). Add-account hosts §7. Reconnect = re-seed.
monitor_only → annotation. Archiver-health card, fork-drift card, seed-audit card.
Refresh-visibility feature ships unchanged. Full frontend-design + Design Critic pass
before build sign-off.

### 11. What survives from v1/r5

As rev 3 (identity primitive now BACKED BY G9 endpoint contract; archive helper as
tier-1 writer; auth classifier; resolver per §3 contract; env sanitization;
group-bounded runs; banklock; usage.py logic; hard-fail fixtures). v1 gets no round 7.

### 12. Gate acceptance contracts (r3: binary criteria)

- **G7 (archiver):** forced double-rename bursts around every re-arm boundary ×100 →
  **zero missed FINAL landed versions** (r4: intermediates under event coalescing are
  explicitly best-effort — the criterion is the final version, matching §5's tiered
  guarantee); daemon kill/restart mid-burst → rescan archives the landed version;
  missing-path interval → re-arm within 2s; per-home armed-inode health matches lstat
  after every phase. All assertions scripted, exit-code verdict.
- **G8 (same-home two-process refresh):** **evidenced overlap, not launch timing**
  (r4): repeated adversarial trials (≥20) with per-process logging proving both read
  the SAME predecessor fingerprint before either committed; PASS iff, across all
  trials: both outcomes recorded; final `.credentials.json` schema-valid AND G9-owned
  by the home; **the third turn FORCES another refresh (backdated expiresAt again —
  r5: a normal third turn could ride the fresh access token and miss a spent refresh
  token)** and succeeds; keychain fingerprint unchanged; archiver captured ≥1
  predecessor. Any other outcome = FAIL → release blocked.
- **G10 (cross-home resume, r4 MAJOR):** runs only AFTER the §0/§13 restart contract
  is built (r5). Scripted: session on home A at cwd X → verified stop (§0 contract)
  → `claude-acct B --resume <id>` from X → PASS iff the transcript continues
  (message count grows, no interleave), canonical session/transcript/cwd binding is
  preserved, the resumed session's G9 identity is B, the keychain fingerprint is
  unchanged, AND a duplicate-resume attempt during the transition is REFUSED by the
  lease (tested explicitly).
- **G5/G6:** scripted checklists with recorded evidence (which store changed;
  post-seed cross-refresh survival), morning, owner present.

### 13. Session registry (backs §0's restart transaction)

The SHARED SessionStart hook (reporting role, §8's detection net) REGISTERS every
managed session: {session-id, home (from CLAUDE_CONFIG_DIR), cwd, pid,
proc-start-time, transcript-path}. **Lifecycle state (r5): blocking UserPromptSubmit
hooks maintain lifecycle state — **the IDLE edge is `Notification: idle_prompt`
exclusively; Stop is recorded as advisory metadata only (r6/r7: a parallel Stop
hook can continue the turn, so Stop is never a state edge)**; UserPromptSubmit
records BUSY write-ahead (its hook exits blocking on persistence failure) and
REFUSES the prompt (with message) while its session's RESTARTING lease (§0) is
held.** All registry writes serialize under a sessions lock (banklock at
`accounts/.sessions.lock/`) with per-record generations; SessionEnd and a liveness
sweeper (pid+start-time dead → tombstone) keep it honest. QuotaBar's restart list =
live IDLE entries only. The registry is AUTHORITATIVE as a gate: no restart offer
without a live registry entry; session-ids validated as UUIDs before `--resume`
(r4 MINOR). **Lock ordering (r6):** `.sessions.lock` is never held while waiting
for a per-session lease — snapshot under the lock, release, acquire the lease,
then generation-revalidate the record; any repoint completes and releases the
pointer lock BEFORE restart work begins. Fault-injection at every restart phase
(incl. sweeper races and post-spawn/pre-registration crash) is a release gate.

## Migration plan

1. Build (§3 shim+resolver, §4 pointer, §5 archiver+reconciler, §7 seeding, §8 epoch
   gates into v1 + flip tool, §9 locks, §10 app). Codex implementation gauntlet.
2. Morning: owner ratifies §0; seeds homes (§7); G5/G6/G8 executed + recorded.
3. Shadow days + drift report; cutover; rollback rehearsed once.
4. OSS sync, final SHIP review, push, v1.0.0, Homebrew.

## Non-goals

Single Mac, single user, no TCP/cloud, no Windows/Linux archiver port.

---

## Appendix A — the vetoed live-flip variant (owner may resurrect knowingly)

Rev 3's model: pointer passed as CLAUDE_CONFIG_DIR (G2 live rail), repoint gated on
outgoing expiry buffer. Refuted: 401-reactive refresh defeats any local gate; a
straddle misfiles a rotation cross-home. Containment would be archiver+reconciler
(asynchronous; B could transiently bill/rotate A's credential before repair). Residual
ceiling: cross-account attribution for seconds + possible double-reconnect. The
review board (3 rounds) holds this unshippable at the stated bar. If the owner
overrides, this appendix becomes a flagged feature with its own acceptance gates; the
default remains §0.
