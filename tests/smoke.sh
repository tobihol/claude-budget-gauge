#!/bin/sh
# smoke.sh — exercises gauge.sh's --help and every `unknown` branch that can be
# reached without touching your real login: each case runs in a sandbox with a
# fresh $HOME and $TMPDIR (cold cache) and, where needed, fake credentials or
# command shims, so your stored token is never read, sent, or refreshed.
#
#   tests/smoke.sh          sandboxed branches only (case 4 needs network)
#   tests/smoke.sh --live   additionally one real reading with your login
#                           (may spend ~6 Haiku tokens if your stored token
#                           happens to be expired — the documented self-heal)
#
# Branches not covered, by design:
#   - "jq/curl not installed"  — trivial guard; verify with a stripped PATH if
#     you care, but a PATH without jq breaks the test harness itself.
#   - "endpoint rate-limited" / "unexpected response schema" — only the real
#     endpoint can produce these; forging them would test the forgery.
set -u

GAUGE="$(cd "$(dirname "$0")/../skills/budget-gauge" && pwd)/gauge.sh"
FAILS=0

check() { # $1 name, $2 expected status, $3 required reason substring, $4 output
    status=$(printf '%s' "$4" | jq -r '.status // empty' 2>/dev/null)
    reason=$(printf '%s' "$4" | jq -r '.reason // empty' 2>/dev/null)
    if [ "$status" = "$2" ] && { [ -z "$3" ] || printf '%s' "$reason" | grep -q "$3"; }; then
        printf 'PASS  %s\n' "$1"
    else
        printf 'FAIL  %s\n      got: %s\n' "$1" "$4"
        FAILS=$((FAILS + 1))
    fi
}

sandbox() { # fresh HOME + TMPDIR + shim dir; nothing of the real login leaks in
    SB=$(mktemp -d)
    mkdir -p "$SB/home/.claude" "$SB/tmp" "$SB/bin"
}

fake_creds() { # $1 = expiresAt in epoch milliseconds
    printf '{"claudeAiOauth":{"accessToken":"sk-ant-fake-smoke-test","expiresAt":%s}}' "$1" \
        > "$SB/home/.claude/.credentials.json"
}

# --help prints the contract and exits 0
if "$GAUGE" --help | grep -q '"status":"unknown"'; then
    printf 'PASS  --help\n'
else
    printf 'FAIL  --help\n'; FAILS=$((FAILS + 1))
fi

# an unrecognized argument is a human error → non-zero exit, nothing on stdout
if "$GAUGE" --bogus >/dev/null 2>&1; then
    printf 'FAIL  bad argument should exit non-zero\n'; FAILS=$((FAILS + 1))
else
    printf 'PASS  bad argument rejected\n'
fi

# 1. no login: empty HOME, and a failing `security` shim so the macOS keychain
#    is never consulted
sandbox
printf '#!/bin/sh\nexit 1\n' > "$SB/bin/security"; chmod +x "$SB/bin/security"
out=$(HOME="$SB/home" TMPDIR="$SB/tmp" PATH="$SB/bin:$PATH" "$GAUGE")
check "no login → unknown" unknown "no Claude Code OAuth token" "$out"

# 2. expired token, refresh fails: expired fake creds + a `claude` shim that
#    fails, so the self-heal path runs (against the shim) and comes up empty
sandbox
fake_creds 1
printf '#!/bin/sh\nexit 1\n' > "$SB/bin/claude"; chmod +x "$SB/bin/claude"
out=$(HOME="$SB/home" TMPDIR="$SB/tmp" PATH="$SB/bin:$PATH" "$GAUGE")
check "expired + failed refresh → unknown" unknown "expired and auto-refresh failed" "$out"

# 3. endpoint unreachable: unexpired fake creds, curl forced through a dead
#    proxy — the TLS handshake never completes, so not even the fake token
#    leaves this machine
sandbox
fake_creds "$(( ($(date +%s) + 3600) * 1000 ))"
out=$(HOME="$SB/home" TMPDIR="$SB/tmp" \
      https_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 "$GAUGE")
check "unreachable endpoint → unknown" unknown "endpoint unreachable" "$out"

# 4. endpoint rejects the token: same unexpired fake creds against the real
#    endpoint (needs network; sends only the obviously-fake token)
sandbox
fake_creds "$(( ($(date +%s) + 3600) * 1000 ))"
out=$(HOME="$SB/home" TMPDIR="$SB/tmp" "$GAUGE")
check "rejected token → unknown" unknown "rejected the stored OAuth token" "$out"

# --live: one real reading with the real login
if [ "${1:-}" = "--live" ]; then
    out=$("$GAUGE")
    status=$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null)
    case $status in
        ok|unknown) printf 'PASS  live reading (%s)\n      %s\n' "$status" "$out" ;;
        *) printf 'FAIL  live reading\n      got: %s\n' "$out"; FAILS=$((FAILS + 1)) ;;
    esac
fi

[ "$FAILS" -eq 0 ] && printf 'all passed\n'
exit $((FAILS > 0))
