#!/bin/bash
# Background daemon that refreshes Claude OAuth tokens before expiry.
#
# Berlin-Collective patch (2026-05-08): the CLAUDE_CREDENTIALS_JSON env var only
# captures a snapshot of the Mac-keychain credentials. The access token expires
# after 8h. Without this daemon, the container would need a Railway redeploy
# every <8h to pick up fresh credentials — which is wasteful (downtime, OOM
# risk during startup) and disrupts running CEO work.
#
# Strategy:
#   - Read /paperclip/.claude/.credentials.json (written by docker-entrypoint)
#   - Every CHECK_INTERVAL seconds, decide whether to refresh
#   - If <REFRESH_BEFORE_EXPIRY seconds left, call Anthropic OAuth refresh
#     endpoint with the long-lived refreshToken to get a fresh accessToken
#   - Write the updated credentials back to the file in-place
#
# This keeps Claude Code authenticated indefinitely without any redeploy.

set -u

CREDS_FILE="${CREDS_FILE:-/paperclip/.claude/.credentials.json}"
CLIENT_ID="${ANTHROPIC_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
TOKEN_ENDPOINT="${ANTHROPIC_OAUTH_TOKEN_URL:-https://console.anthropic.com/v1/oauth/token}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1800}"          # 30 minutes
REFRESH_BEFORE_EXPIRY="${REFRESH_BEFORE_EXPIRY:-7200}"  # refresh if <2h left

log() {
    echo "[claude-refresh] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

refresh_token() {
    local creds_file="$1"

    if [ ! -f "$creds_file" ]; then
        log "credentials file missing at $creds_file — skipping"
        return 1
    fi

    # Extract current state via python (already in base image)
    local refresh_token expires_at now_ms time_left
    if ! refresh_token=$(python3 -c "import json; print(json.load(open('$creds_file'))['claudeAiOauth']['refreshToken'])" 2>/dev/null); then
        log "could not parse refreshToken from $creds_file"
        return 1
    fi
    expires_at=$(python3 -c "import json; print(json.load(open('$creds_file'))['claudeAiOauth']['expiresAt'])" 2>/dev/null)
    now_ms=$(($(date +%s) * 1000))
    time_left=$(( (expires_at - now_ms) / 1000 ))

    if [ "$time_left" -gt "$REFRESH_BEFORE_EXPIRY" ]; then
        log "token still valid for ${time_left}s — skipping refresh"
        return 0
    fi

    log "token expires in ${time_left}s — refreshing"

    # Build refresh request body via python (safely escapes the refresh token)
    local request_body
    request_body=$(REFRESH_TOKEN="$refresh_token" CLIENT_ID="$CLIENT_ID" python3 -c '
import json, os
print(json.dumps({
    "grant_type": "refresh_token",
    "refresh_token": os.environ["REFRESH_TOKEN"],
    "client_id": os.environ["CLIENT_ID"],
}))
')

    # Call Anthropic OAuth refresh endpoint
    local response http_code
    response=$(curl -sS -X POST "$TOKEN_ENDPOINT" \
        -H "Content-Type: application/json" \
        -w "\n%{http_code}" \
        -d "$request_body" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log "ERROR: refresh endpoint returned HTTP $http_code: $response"
        return 1
    fi

    # Update credentials file with new tokens
    if ! python3 - <<PYEOF "$response" "$creds_file"
import json, sys, time, os, tempfile
response = json.loads(sys.argv[1])
creds_path = sys.argv[2]

if 'access_token' not in response:
    print(f'[claude-refresh] ERROR: no access_token in response: {response}', file=sys.stderr)
    sys.exit(1)

with open(creds_path, 'r') as f:
    creds = json.load(f)

creds['claudeAiOauth']['accessToken'] = response['access_token']
if response.get('refresh_token'):
    creds['claudeAiOauth']['refreshToken'] = response['refresh_token']
expires_in = response.get('expires_in', 28800)  # default 8h
creds['claudeAiOauth']['expiresAt'] = int((time.time() + expires_in) * 1000)

# Atomic write: tmp file + rename
fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(creds_path), prefix='.creds-tmp-')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(creds, f)
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, creds_path)
    print(f'[claude-refresh] OK — token refreshed, valid for {expires_in}s')
except Exception:
    os.unlink(tmp_path)
    raise
PYEOF
    then
        log "ERROR: failed to update credentials file"
        return 1
    fi

    return 0
}

main_loop() {
    log "daemon started — checking every ${CHECK_INTERVAL}s, refresh threshold ${REFRESH_BEFORE_EXPIRY}s before expiry"
    log "credentials file: $CREDS_FILE"

    # First check happens after one full interval (creds are fresh from bootstrap on container start)
    while true; do
        sleep "$CHECK_INTERVAL"
        refresh_token "$CREDS_FILE" || log "refresh attempt failed (will retry next cycle)"
    done
}

# If invoked with --once, run a single refresh check and exit (for testing)
if [ "${1:-}" = "--once" ]; then
    refresh_token "$CREDS_FILE"
    exit $?
fi

main_loop
