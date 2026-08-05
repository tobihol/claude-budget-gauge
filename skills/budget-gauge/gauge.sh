#!/bin/sh
# gauge.sh — subscription usage gauge: 5-hour session window + weekly utilization.
# Queries Claude Code's internal OAuth usage endpoint with the operator's stored
# Claude Code login. Prints ONE compact JSON line (schema in SKILL.md, alongside
# this script) and never prints the token. Safe to call from any process,
# headless included.
#
# Rate-limit hygiene: results are cached for TTL seconds and served from cache,
# so callers may invoke this freely — the endpoint is hit at most once per TTL.
#
# Token lifecycle: the stored access token lives ~8h and only refreshes when a
# CLI call actually uses the stored login. Env-token sessions (containers, CI —
# CLAUDE_CODE_OAUTH_TOKEN set) never do, so on an expired token this script
# triggers one minimal CLI call through the stored login to make the CLI
# refresh it — see SKILL.md. That call is real, subscription-billed spend
# (~6 output tokens on Haiku) and happens only on an expired stored token.

set -eu

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
gauge.sh — Claude subscription window utilization as one JSON line on stdout.

Usage: gauge.sh            print a reading (cached up to 180 s)
       gauge.sh --help     this text

Output (the public contract; details in SKILL.md next to this script):
  {"status":"ok","fetched_at":"…","five_hour_pct":11.0,"five_hour_resets_at":"…",
   "seven_day_pct":56.0,"seven_day_resets_at":"…","warnings":[…]}
or, when the state cannot be read:
  {"status":"unknown","reason":"…"}

Exit status is always 0 when a reading (ok or unknown) was printed.
"unknown" never means "unchanged" — treat it as budget state unavailable.

Requires: jq, curl, a Claude Code login on this machine. Reads the stored
login (credentials file, else macOS keychain); never writes it. On an expired
stored token it makes one minimal subscription-billed Haiku call so the CLI
refreshes its own credential.
EOF
        exit 0 ;;
    "") ;;
    *)  printf 'gauge.sh: unknown argument: %s (try --help)\n' "$1" >&2
        exit 2 ;;
esac

TTL=180                                   # seconds; the endpoint 429s if polled faster
ENDPOINT="https://api.anthropic.com/api/oauth/usage"

unknown() { printf '{"status":"unknown","reason":"%s"}\n' "$1"; exit 0; }

# Cache lives in a per-user 0700 directory; if that directory exists but is not
# ours (a squatter in a shared /tmp), caching is skipped entirely rather than
# read from or written to. The cached JSON contains no secrets.
CACHE_DIR="${TMPDIR:-/tmp}/claude-budget-gauge-$(id -u)"
CACHE="$CACHE_DIR/reading.json"
mkdir -p -m 700 "$CACHE_DIR" 2>/dev/null || true
dir_uid=$(stat -c %u "$CACHE_DIR" 2>/dev/null || stat -f %u "$CACHE_DIR" 2>/dev/null || echo -1)
[ "$dir_uid" = "$(id -u)" ] || CACHE=""

# Serve a fresh cache without touching the endpoint.
if [ -n "$CACHE" ] && [ -f "$CACHE" ]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)
    if [ $((now - mtime)) -lt "$TTL" ]; then
        cat "$CACHE"
        exit 0
    fi
fi

command -v jq >/dev/null 2>&1 || unknown "jq not installed"
command -v curl >/dev/null 2>&1 || unknown "curl not installed"

# Sets TOKEN and EXPIRES_MS from the stored login: credentials file (Linux/WSL),
# else macOS keychain. If the file exists but yields no token, the keychain is
# still tried. Read at call time, held only in this process's memory, never
# written anywhere.
read_login() {
    TOKEN=""
    EXPIRES_MS=0
    for src in file keychain; do
        creds=""
        case $src in
            file)
                [ -f "$HOME/.claude/.credentials.json" ] || continue
                creds=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null || true) ;;
            keychain)
                command -v security >/dev/null 2>&1 || continue
                creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true) ;;
        esac
        [ -n "$creds" ] || continue
        TOKEN=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true)
        EXPIRES_MS=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null || echo 0)
        creds=""
        [ -n "$TOKEN" ] && break
    done
    # A malformed expiresAt must degrade to 0, not crash the always-JSON contract.
    case $EXPIRES_MS in ''|*[!0-9]*) EXPIRES_MS=0 ;; esac
}

read_login
[ -n "$TOKEN" ] || unknown "no Claude Code OAuth token found (not logged in?)"

# Expired access token: the endpoint only accepts the stored login's short-lived
# (~8h) access token — the long-lived CLAUDE_CODE_OAUTH_TOKEN gets permission_error.
# Self-heal by exercising the stored login once (the CLI then refreshes the
# credential itself; this script never writes the credential store): one minimal
# Haiku call, ~6 output tokens, subscription-billed. One attempt, no retry.
now_ms=$(( $(date +%s) * 1000 ))
if [ "$EXPIRES_MS" -gt 0 ] && [ "$now_ms" -ge "$EXPIRES_MS" ]; then
    if command -v claude >/dev/null 2>&1; then
        env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
            MAX_THINKING_TOKENS=0 \
            claude -p "Reply with exactly: ok" --tools "" --no-session-persistence \
            --model claude-haiku-4-5 >/dev/null 2>&1 || true
        read_login
    fi
    if [ -z "$TOKEN" ] || { [ "$EXPIRES_MS" -gt 0 ] && [ "$now_ms" -ge "$EXPIRES_MS" ]; }; then
        unknown "stored OAuth access token expired and auto-refresh failed — run any claude call without CLAUDE_CODE_OAUTH_TOKEN in the environment (or: claude auth login), then retry"
    fi
fi

# A real claude-code User-Agent avoids the aggressively rate-limited bucket.
VERSION=$(claude --version 2>/dev/null | awk '{print $1; exit}' || true)
UA="claude-code/${VERSION:-2.1.222}"

# The Authorization header goes in via curl's stdin config, not argv (argv is
# visible in `ps`); the token therefore never appears in a process listing.
resp=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
       | curl -s -m 15 -K - \
              -H "anthropic-beta: oauth-2025-04-20" \
              -H "User-Agent: $UA" \
              "$ENDPOINT") || unknown "endpoint unreachable"

out=$(printf '%s' "$resp" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    if (.five_hour.utilization? != null) then
      {status: "ok",
       fetched_at: $ts,
       five_hour_pct: .five_hour.utilization,
       five_hour_resets_at: .five_hour.resets_at,
       seven_day_pct: .seven_day.utilization,
       seven_day_resets_at: .seven_day.resets_at,
       warnings: [ (.limits // [])[]
                   | select(.severity? and .severity != "normal")
                   | {kind, percent, severity,
                      model: (.scope.model.display_name? // null)} ]}
    else empty end' 2>/dev/null) || true

if [ -z "${out:-}" ]; then
    # 429, auth failure, or a schema change — distinguish the common cases.
    if printf '%s' "$resp" | jq -e '.error.type == "rate_limit_error"' >/dev/null 2>&1; then
        unknown "endpoint rate-limited (retry after ~3 min; is another poller running?)"
    fi
    if printf '%s' "$resp" | jq -e '.error.type == "authentication_error" or .error.type == "permission_error"' >/dev/null 2>&1; then
        unknown "usage endpoint rejected the stored OAuth token — run claude auth login in this environment, then retry"
    fi
    unknown "unexpected response schema (endpoint may have changed — see SKILL.md fallbacks)"
fi

if [ -n "$CACHE" ]; then
    printf '%s\n' "$out" > "$CACHE.$$" && mv "$CACHE.$$" "$CACHE"
fi
printf '%s\n' "$out"
