#!/bin/bash
# heal-plan-stamp.sh — one-shot, oracle-gated repair of the ACTIVE keychain blob's
# frozen subscriptionType stamp (v103 companion; Ronit-approved 2026-08-10).
#
# The stamp is written only by a real /login; a plan change while logged in leaves it
# stale indefinitely, and write_bank_record's crossed-identity tell (stamp vs
# ~/.claude.json organizationType) then refuses EVERY banking of the active credential:
# the poll heal corrects the copy it banks (usage.py v103), but swap-account.sh's
# re-bank-current and manual bank-account.sh still hit the gate — "Swap here" away from
# an upgraded account fails until the stamp is repaired. This script repairs the stamp
# itself, once, through the full kc_write ceremony (lock + epoch fence + snapshot +
# archive + exact-match recheck), so every writer caller agrees again.
#
# Gate mirrors usage._benign_drift_refusal's v103 correction, fail-closed at every step:
#   * stamp tier vs metadata tier must DISAGREE (else: nothing to do, exit 0);
#   * the live G9 oracle must POSITIVELY resolve the credential to the active email;
#   * oracle tier must be an EXPLICIT "max"/"pro" (free is _plan_of's absence default)
#     and must AGREE with the metadata tier — two independent live sources naming the
#     stamp as the odd one out. Any other state: exit 1, keychain UNCHANGED.
# Tokens are never modified — only the subscriptionType field changes, so live sessions
# keep authenticating with the exact same credential.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

acquire_lock 15 || { err "heal-plan-stamp: could not acquire the bank lock"; exit 1; }
trap 'release_lock' EXIT

blob="$(cred_read)"
[ -n "$blob" ] || { err "heal-plan-stamp: no live credential (checked the credentials file and the keychain slot)"; exit 1; }

act="$(active_email)"
[ -n "$act" ] || { err "heal-plan-stamp: no active identity in ~/.claude.json"; exit 1; }

# stamp + metadata tiers through the ONE tier rule (bank_common.plan_tier).
# Blob on STDIN (python3 -c, not a heredoc — a heredoc would steal stdin from the pipe).
tiers="$(printf '%s' "$blob" | python3 -c "
import json, sys
sys.path.insert(0, sys.argv[2])
import bank_common
blob = json.load(sys.stdin)
oauth = blob.get('claudeAiOauth', blob)
cj = json.load(open(sys.argv[3]))
oa = cj.get('oauthAccount') or {}
if oa.get('emailAddress') != sys.argv[1]:
    print('MISMATCH MISMATCH'); raise SystemExit(0)
st = bank_common.plan_tier(oauth.get('subscriptionType')) or 'none'
mt = bank_common.plan_tier(oa.get('organizationType')) or 'none'
print(st, mt)
" "$act" "$HERE" "$CLAUDE_JSON")" || { err "heal-plan-stamp: could not read tiers; refusing"; exit 1; }
stamp_tier="$(printf '%s' "$tiers" | awk '{print $1}')"
meta_tier="$(printf '%s' "$tiers" | awk '{print $2}')"

[ "$stamp_tier" = "MISMATCH" ] && { err "heal-plan-stamp: metadata names a different account; refusing"; exit 1; }
if [ -z "$stamp_tier" ] || [ "$stamp_tier" = "none" ] || [ "$meta_tier" = "none" ]; then
  err "heal-plan-stamp: a tier is unknown (stamp=${stamp_tier:-?}, metadata=${meta_tier:-?}); no evidence, refusing"
  exit 1
fi
if [ "$stamp_tier" = "$meta_tier" ]; then
  echo "heal-plan-stamp: stamp already consistent ($stamp_tier); nothing to do."
  exit 0
fi

# live oracle: POSITIVE identity + explicit plan, token via stdin (never argv)
oracle_out="$(printf '%s' "$blob" | python3 -c "
import json,sys; b=json.load(sys.stdin); o=b.get('claudeAiOauth', b)
sys.stdout.write(o.get('accessToken') or '')" | python3 "$HERE/identity.py")" || {
  err "heal-plan-stamp: oracle could not RESOLVE the live credential; refusing (keychain UNCHANGED)"
  exit 1
}
oracle_email="$(printf '%s' "$oracle_out" | awk '{print $3}')"
oracle_plan="$(printf '%s' "$oracle_out" | awk '{print $4}')"
[ "$oracle_email" = "$act" ] || { err "heal-plan-stamp: oracle names '$oracle_email', not '$act'; refusing"; exit 1; }
case "$oracle_plan" in max|pro) ;; *) err "heal-plan-stamp: oracle plan '${oracle_plan:-?}' is not explicit max/pro; refusing"; exit 1 ;; esac
[ "$oracle_plan" = "$meta_tier" ] || { err "heal-plan-stamp: oracle ($oracle_plan) and metadata ($meta_tier) disagree; refusing"; exit 1; }

# patch ONLY the stamp; compact JSON as kc_write requires
patched="$(printf '%s' "$blob" | ORACLE_PLAN="$oracle_plan" python3 -c "
import json,os,sys
b=json.load(sys.stdin)
o=b.get('claudeAiOauth')
(o if isinstance(o,dict) else b)['subscriptionType']=os.environ['ORACLE_PLAN']
sys.stdout.write(json.dumps(b,separators=(',',':')))")"
[ -n "$patched" ] || { err "heal-plan-stamp: could not patch the blob; refusing"; exit 1; }

# (Codex P2a) the oracle round-trip takes seconds and an external /login rewrites
# ~/.claude.json without honoring this lock — re-verify the active metadata
# IMMEDIATELY before mutating; any movement refuses (keychain unchanged).
# ACCEPTED RESIDUAL (Codex 2026-08-10, ruled not-fixed): a metadata rewrite during
# kc_write's own validate/snapshot/archive work is not re-checked at the final write
# syscall. Every token-changing race (any real /login) is refused by kc_write's
# byte-level final recheck; a metadata-only move cannot make the stamp wrong, because
# the stamp written is the oracle's attestation about THIS credential, not about the
# metadata. Closing it would mean threading metadata assertions into lib.sh's shared
# kc_write — a larger blast radius than the theoretical window justifies (swap's
# re-bank carries the same shaped window under the same protections).
recheck="$(python3 -c "
import json, sys
sys.path.insert(0, sys.argv[2])
import bank_common
cj = json.load(open(sys.argv[3]))
oa = cj.get('oauthAccount') or {}
ok = oa.get('emailAddress') == sys.argv[1]
mt = bank_common.plan_tier(oa.get('organizationType')) or 'none'
print(('same' if ok else 'moved'), mt)
" "$act" "$HERE" "$CLAUDE_JSON")" || { err "heal-plan-stamp: metadata recheck failed; refusing"; exit 1; }
[ "$recheck" = "same $meta_tier" ] || {
  err "heal-plan-stamp: active metadata moved during the oracle call ($recheck); refusing (keychain UNCHANGED)"
  exit 1
}

printf '%s' "$patched" | kc_write; wrc=$?
if [ "$wrc" -ne 0 ]; then
  # (Codex P2b) kc_write's contract: rc 78 fenced / rc 10-11 refused leave the keychain
  # UNCHANGED; a generic rc 1 can mean a timeout AFTER the write landed — indeterminate.
  case "$wrc" in
    78|10|11) err "heal-plan-stamp: kc_write refused (rc $wrc, see above); keychain UNCHANGED" ;;
    *) err "heal-plan-stamp: kc_write failed (rc $wrc); keychain state INDETERMINATE — verify with:"
       err "                 kc_read | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"claudeAiOauth\"][\"subscriptionType\"])'" ;;
  esac
  exit 1
fi
# (Codex P1a) kc_write verifies by cred_fingerprint, which deliberately EXCLUDES
# subscriptionType — the one field this repair changes. Its success therefore cannot
# prove the stamp landed; re-read and check the stamp AND the untouched tokens.
verify="$(cred_read | HEAL_WANT="$patched" python3 -c "
import json, os, sys
after = json.load(sys.stdin)
ao = after.get('claudeAiOauth', after)
want = json.loads(os.environ['HEAL_WANT'])
wo = want.get('claudeAiOauth', want)
same_tokens = all(ao.get(k) == wo.get(k) for k in ('accessToken', 'refreshToken', 'expiresAt'))
print('ok' if (ao.get('subscriptionType') == wo.get('subscriptionType') and same_tokens) else 'bad')
" 2>/dev/null)"
if [ "$verify" != "ok" ]; then
  err "heal-plan-stamp: post-write verification FAILED — the stamp did not land as intended;"
  err "                 inspect the keychain (a snapshot + archive of the predecessor were taken)."
  exit 1
fi
echo "heal-plan-stamp: keychain stamp corrected $stamp_tier -> $oracle_plan for $act"
echo "                 (tokens untouched, verified post-write; snapshot + archive taken by kc_write)"
exit 0
