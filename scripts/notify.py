#!/usr/bin/env python3
"""notify.py — the ONE place account-bank posts a macOS notification.

Today it has exactly one subject: an account's grant was revoked server-side and the
record armed `needs-relogin`. That state used to be visible only if the owner happened
to look at the menu bar, so a revocation on the SHARED account could sit unnoticed for
hours while auto-ping stood down (v105's circuit breaker) and the card quietly showed a
stale figure. The notification makes the arming an event.

Debounce contract — ONCE PER ARMING, not once per poll. The pollers re-derive
"needs-relogin" every cycle, so the notification is gated on a marker file
(`<bank_dir>/.relogin-notified.json`, 0600) that records which accounts have already
been announced. `clear()` removes the entry, and every path that returns an account to
health calls it, so the NEXT revocation notifies again. `REPEAT_AFTER_S` is a backstop
for an account that stays broken across days, not a retry.

Never raises (a notification failure must never break a poll or a ping), never carries
credential material, and never blocks: osascript gets a hard timeout and its output is
discarded. `ACCOUNT_BANK_NOTIFY=0` disables the whole surface; `ACCOUNT_BANK_NOTIFY_BIN`
redirects the binary so the hermetic tests never post a real notification.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

MARKER_NAME = ".relogin-notified.json"
# (r2 nit) Well under the 15s budget usage.py's poll runs on: this fires from inside
# set_bank_status, and a wedged `display notification` must not be able to eat a poll.
OSASCRIPT_TIMEOUT_S = 3
REPEAT_AFTER_S = 7 * 24 * 3600      # backstop only; see the debounce contract above

# argv-based, so no title/message text can ever be parsed as AppleScript. The strings
# travel as `run` arguments; the script itself is a fixed constant.
_SCRIPT = (
    "on run argv\n"
    "  display notification (item 2 of argv) with title (item 1 of argv)\n"
    "end run\n"
)


def enabled():
    return os.environ.get("ACCOUNT_BANK_NOTIFY", "1") != "0"


def notify(title, message):
    """Post one notification. Returns True if the binary reported success."""
    if not enabled():
        return False
    binpath = os.environ.get("ACCOUNT_BANK_NOTIFY_BIN", "/usr/bin/osascript")
    if not (os.path.isfile(binpath) and os.access(binpath, os.X_OK)):
        return False
    try:
        r = subprocess.run([binpath, "-", str(title), str(message)],
                           input=_SCRIPT, capture_output=True, text=True,
                           timeout=OSASCRIPT_TIMEOUT_S)
        return r.returncode == 0
    except Exception:
        return False


def _marker_path(bank_dir):
    return os.path.join(bank_dir, MARKER_NAME)


def _load(bank_dir):
    try:
        d = json.load(open(_marker_path(bank_dir)))
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def _store(bank_dir, d):
    """Atomic 0600 write. A failure here is swallowed: worst case the notification
    repeats or is skipped once — neither is worth failing a poll over."""
    try:
        fd, tmp = tempfile.mkstemp(dir=bank_dir, prefix=".notify.")
        with os.fdopen(fd, "w") as f:
            json.dump(d, f)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, _marker_path(bank_dir))
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        return False


def relogin_armed(bank_dir, email, reason=""):
    """Announce that `email` just armed needs-relogin. Debounced. Returns True if a
    notification was actually posted."""
    if not email or not bank_dir or not os.path.isdir(bank_dir):
        return False
    now = int(time.time())
    d = _load(bank_dir)
    prev = d.get(email)
    if isinstance(prev, dict):
        try:
            if now - int(prev.get("at", 0) or 0) < REPEAT_AFTER_S:
                return False
        except Exception:
            return False
    # Record BEFORE posting: if osascript is slow or wedged, a concurrent poll must
    # not queue a second copy of the same announcement.
    d[email] = {"at": now}
    _store(bank_dir, d)
    msg = "%s needs a re-login. Open QuotaBar and hit Re-bank on its card." % email
    if reason:
        msg += " (%s)" % reason
    return notify("QuotaBar — account revoked", msg)


def clear(bank_dir, email):
    """Forget that `email` was announced, so the next revocation notifies again."""
    if not email or not bank_dir or not os.path.isdir(bank_dir):
        return False
    d = _load(bank_dir)
    if email not in d:
        return False
    d.pop(email, None)
    return _store(bank_dir, d)


def _main(argv):
    if len(argv) >= 4 and argv[1] == "say":
        notify(argv[2], argv[3])
        return 0
    if len(argv) < 4:
        sys.stderr.write("usage: notify.py relogin|clear <bank_dir> <email> [reason]\n"
                         "       notify.py say <title> <message>\n")
        return 2
    cmd, bank_dir, email = argv[1], argv[2], argv[3]
    if cmd == "relogin":
        relogin_armed(bank_dir, email, argv[4] if len(argv) > 4 else "")
    elif cmd == "clear":
        clear(bank_dir, email)
    else:
        sys.stderr.write("notify.py: unknown command %r\n" % cmd)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
