#!/bin/bash
#
# test-midsession-swap.sh — does a RUNNING Claude Code session adopt a
# credential swap performed mid-session?
#
# Usage: ./test-midsession-swap.sh <claude-binary> [tripwire-label]
#
#   <claude-binary>   path to the claude binary/version to test
#   [tripwire-label]  an account that is currently EXHAUSTED (>=100% 5h util).
#                     Auto-picked from the usage cache if omitted.
#
# Method: start one persistent session (-p + stream-json stdin held open) on
# the CURRENT account, complete turn 1, then swap the live credential to the
# exhausted tripwire account using the switcher's own restore path, then send
# turn 2 IN THE SAME PROCESS:
#   - turn 2 fails with a usage-limit error  -> session ADOPTED the swap
#   - turn 2 answers normally                -> session kept its CACHED token
#
# The verdict is printed as the last line: ADOPTED | CACHED | INCONCLUSIVE.
# NOTE: pause the auto-switch timer while running this (it would immediately
# switch away from the exhausted account): launchctl unload/load the plist.

set -u
BINARY="${1:?usage: $0 <claude-binary> [tripwire-label]}"
TRIPWIRE="${2:-}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SWITCHER="$SCRIPT_DIR/claude-auto-switch.sh"
USAGE_CACHE="$HOME/.claude/account-usage-cache.json"
CLAUDE_JSON="$HOME/.claude.json"

[ -x "$BINARY" ] || { echo "binary not executable: $BINARY"; exit 2; }
[ -f "$SWITCHER" ] || { echo "switcher not found: $SWITCHER"; exit 2; }

ORIGINAL_ACCOUNT=$(python3 -c "import json;print(json.load(open('$CLAUDE_JSON'))['oauthAccount']['emailAddress'])" 2>/dev/null)
echo "session account (start): $ORIGINAL_ACCOUNT"

# Pick the tripwire dynamically: any account currently >=100% in the cache.
if [ -z "$TRIPWIRE" ]; then
  TRIPWIRE=$(python3 -c "
import json
d = json.load(open('$USAGE_CACHE'))['accounts']
for k, v in d.items():
    if isinstance(v, dict) and (v.get('utilization') or 0) >= 100 and k != '$ORIGINAL_ACCOUNT':
        print(k); break
" 2>/dev/null)
fi
[ -z "$TRIPWIRE" ] && { echo "no exhausted (>=100%) account available as tripwire"; exit 2; }
echo "tripwire account (exhausted): $TRIPWIRE"

VERSION=$("$BINARY" --version 2>/dev/null | head -1)
echo "testing binary: $BINARY ($VERSION)"
echo

# Drive the session. CLAUDECODE must be unset or the nested session refuses to start.
env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
  python3 - "$BINARY" "$SWITCHER" "$TRIPWIRE" "$ORIGINAL_ACCOUNT" <<'PYEOF'
import json, os, re, select, subprocess, sys, time

binary, switcher, tripwire, original = sys.argv[1:5]

# --debug to stderr: the debug stream names auth/credential operations, which
# lets us see WHICH account authenticates each turn (direct evidence).
stderr_path = "/tmp/midsession-swap-debug.log"
stderr_f = open(stderr_path, "w")
proc = subprocess.Popen(
    [binary, "-p", "--output-format", "stream-json", "--input-format", "stream-json",
     "--verbose", "--debug", "--debug-to-stderr", "--model", "claude-haiku-4-5-20251001"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr_f, text=True)

def send(text):
    msg = {"type": "user", "message": {"role": "user",
           "content": [{"type": "text", "text": text}]}}
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()

# The stream emits 'rate_limit_event' per turn with rate_limit_info:
#   {"status": "allowed"|..., "resetsAt": <epoch>, "rateLimitType": "five_hour"}
# resetsAt is the ACCOUNT's 5h-window reset — a fingerprint of which account
# actually served the request. Comparing turn-1 vs turn-2 resetsAt tells us
# definitively whether the session adopted the swapped credential.
last_rate_info = {}

def wait_result(timeout=240):
    """Read events until a 'result' event; capture rate_limit_info along the way."""
    global last_rate_info
    deadline = time.time() + timeout
    buf = []
    while time.time() < deadline:
        r, _, _ = select.select([proc.stdout], [], [], 1.0)
        if not r:
            if proc.poll() is not None:
                return ("process_exited", "\n".join(buf[-10:]))
            continue
        line = proc.stdout.readline()
        if not line:
            return ("eof", "\n".join(buf[-10:]))
        line = line.strip()
        if not line:
            continue
        buf.append(line[:400])
        try:
            ev = json.loads(line)
        except ValueError:
            ev = {}
        if ev.get("type") == "rate_limit_event":
            last_rate_info = ev.get("rate_limit_info", {}) or {}
        elif ev.get("type") == "result":
            if ev.get("subtype") == "success" and not ev.get("is_error"):
                return ("success", line[:400])
            return ("error", line[:400])
    return ("timeout", "\n".join(buf[-10:]))

def grep_debug_accounts():
    """Which account emails appear in the debug stderr, in order?"""
    try:
        stderr_f.flush()
    except Exception:
        pass
    try:
        data = open(stderr_path, errors="replace").read()
    except Exception:
        return []
    return re.findall(r"[\w.+-]+@[\w.-]+\.\w+", data)

print("turn 1 (before swap)...")
send("Reply with exactly: ok")
kind1, raw1 = wait_result()
info1 = dict(last_rate_info)
print(f"  -> {kind1}  rate_limit_info: {info1}")
if kind1 != "success":
    print(f"  raw: {raw1}")
    print("VERDICT: INCONCLUSIVE (turn 1 failed — session never worked)")
    proc.kill(); sys.exit(1)

print(f"swapping live credential -> {tripwire} (exhausted)...")
swap = subprocess.run(["bash", switcher, "restore", tripwire],
                      capture_output=True, text=True, timeout=120)
print(f"  restore rc={swap.returncode}")

# Optional mechanism-bisect: run an extra command after the swap (e.g. force a
# REAL settings.json content change) to find what triggers in-session reload.
post_cmd = os.environ.get("POST_SWAP_CMD", "")
if post_cmd:
    print(f"  post-swap cmd: {post_cmd}")
    pc = subprocess.run(["bash", "-c", post_cmd], capture_output=True, text=True, timeout=60)
    print(f"  post-swap rc={pc.returncode} {pc.stdout.strip()[:120]}")
time.sleep(3)

print("turn 2 (after swap, same process)...")
send("Reply with exactly: ok again")
kind2, raw2 = wait_result()
info2 = dict(last_rate_info)
print(f"  -> {kind2}  rate_limit_info: {info2}")
print(f"  raw: {raw2[:300]}")

print(f"swapping back -> {original}...")
subprocess.run(["bash", switcher, "restore", original],
               capture_output=True, text=True, timeout=120)

try:
    proc.stdin.close()
except Exception:
    pass
proc.kill()
stderr_f.close()

emails = grep_debug_accounts()
uniq = []
for e in emails:
    if e not in uniq:
        uniq.append(e)
print(f"debug-stderr account mentions (ordered, deduped): {uniq}")
print(f"full debug log: {stderr_path}")

# Primary verdict: did the per-turn rate_limit_info fingerprint change?
# Same account -> same resetsAt + status. Adopted swap -> tripwire's window:
# different resetsAt and/or a non-allowed status (the tripwire is exhausted).
r1, r2 = info1.get("resetsAt"), info2.get("resetsAt")
s2 = info2.get("status", "")
if info1 and info2:
    if s2 not in ("", "allowed"):
        print(f"VERDICT: ADOPTED (turn 2 rate-limit status={s2!r} — exhausted tripwire answered)")
    elif r1 and r2 and r1 != r2:
        print(f"VERDICT: ADOPTED (resetsAt changed {r1} -> {r2} — different account served turn 2)")
    elif kind2 == "success":
        print("VERDICT: CACHED (same rate-limit window + success — session kept its in-memory credential)")
    else:
        print(f"VERDICT: INCONCLUSIVE (turn 2: {kind2}, info: {info2})")
elif kind2 == "success":
    print("VERDICT: CACHED? (no rate_limit_info captured, but turn 2 succeeded)")
elif kind2 in ("error", "process_exited") and "limit" in raw2.lower():
    print("VERDICT: ADOPTED (turn 2 errored with a limit message)")
else:
    print(f"VERDICT: INCONCLUSIVE (turn 2 result: {kind2})")
PYEOF
