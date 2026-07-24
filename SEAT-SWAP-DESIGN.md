# Seat-Swap v3 — Design Draft v0 (2026-07-24, for cross-vendor review at r15)

Status: DRAFT for review. No code exists. Written the evening of the v2 rollback;
read HANDOFF.md's decision record first.

## Problem

The owner rejected v2's pin-at-launch UX after one evening: switching accounts
mid-conversation and migrating mid-flight agent runs must be SEAMLESS (v1
turn-level semantics), and the restart-with-resume ceremony — however fast — is
not an acceptable substitute for his daily rail. He explicitly accepts v1's
failure modes as the price. The question: can we keep any of v2's determinism
without giving up seamlessness?

## Foundation fact (empirical, CLI 2.1.217/218, G5c + lived evidence)

Credential pickup is TURN-LEVEL PER CONFIG DIR:
- an unpinned session reads the DEFAULT keychain slot on every request;
- a session with CLAUDE_CONFIG_DIR=<home> reads THAT home's slot on every request.

Everything below stands on this.

## Option A (RECOMMENDED): permanent-shadow hybrid — "shared rail by default, pin on demand"

The reframe: **shadow is not a transition state; shadow IS v3.**

- The DEFAULT keychain slot stays the shared rail. `/swap` (journaled
  swap-account.sh, months-hardened) moves EVERY unpinned session on its next
  request — v1 seamlessness, unchanged, zero new credential machinery.
- v2's homes/registry/claude-acct become an OPT-IN pinning facility: launch a
  session with `claude-acct <email>` when you explicitly want it IMMUNE to swaps
  (the overnight agent that must stay on the Max account; a run on the Pro
  account that must not follow a swap). Pinned sessions read their home's slot —
  deterministic, exactly v2's property, but chosen per-session instead of imposed
  globally.
- QuotaBar: cards as today; sessions surfaced as "on rail" vs "pinned to <email>";
  Swap button = rail swap (v1); a per-account "launch pinned session" affordance
  replaces Switch-as-default-rail.
- Archiver/monitoring: unchanged (already shadow-legal).

What this buys: seamlessness by default (the owner's requirement), determinism on
demand (v2's core value, now opt-in), and a NEAR-ZERO build — the epoch machinery,
homes, seeding, archiver, and swap rail all already work in shadow today. The main
work is QuotaBar UI (Swap button restore — already in flight — plus pinned-launch
affordance and rail/pinned session labeling) and retiring the assumption that
shadow must eventually flip.

Accepted costs (owner-ratified at rollback): rail sessions can drop off Fable when
the rail moves under them; ~daily UNLINKED fingerprint drift on the rail (Link
remedy); rail quota attribution is "whatever was active." All scoped to the rail:
pinned sessions and parked homes are untouched by every one of them.

## Option B: seat-swap proper — rewrite a HOME's slot in place

The original v3 sketch: sessions pin to home H; a "seat-swap" transaction writes
account B's credential into H's slot; every H-pinned session reroutes next request.

Rejected as the primary path because:
1. It recreates the shared-mutable-credential class INSIDE the structure built to
   kill it, now with registry identity confusion added (registry says H=A while
   H's seat carries B) — the UNLINKED drift class returns wearing a home costume.
2. Its only advantage over Option A is multiple independent swappable rails —
   a need the owner does not have (two accounts, one operator).
3. Every mutation needs a new locked, journaled, fenced transaction on a surface
   (home seats) the archiver also watches — a full hardening cycle for negative
   novelty.

Keep on file only if a real multi-rail need ever appears.

## Migration (Option A)

Nothing to flip. Current state (shadow, gen 19) IS the target state. Work items:
1. QuotaBar Swap button restore (in flight, rollback evening).
2. "Launch pinned session on <email>" affordance (Terminal via claude-acct).
3. Session labeling in the popover: rail vs pinned (sessions.py already tracks
   pinned sessions; rail sessions are the complement).
4. Docs: HANDOFF + ISOLATION-DESIGN addendum declaring shadow the terminal state;
   the v2 flip path (attest/flip.py) remains as dormant, tested machinery.
5. Release framing: ship v1.0.0 as the hybrid ("seamless rail + opt-in pinning"),
   which is also the honest description of what the author runs.

## Review asks (r15)

- Attack Option A's claim that rail failure modes cannot leak into pinned homes
  (the seeding/shared-file surface is the suspect seam — see fork-drift notes).
- Check swap-account.sh's `--expect-active` guard still holds when pinned
  sessions exist (it snapshots the rail, which pinned sessions never touch).
- Confirm no epoch-gated tool misbehaves if shadow is permanent (anything that
  assumes shadow is transitional).
