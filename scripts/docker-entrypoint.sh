#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# ──────────────────────────────────────────────────────────────────────
# Berlin-Collective Railway-bootstrap patch (2026-05-04)
# ──────────────────────────────────────────────────────────────────────
# When deploying to Railway (or any cloud where /paperclip is ephemeral),
# we need to:
#   1. Write a minimal config.json with deploymentMode=authenticated
#      so the server binds to 0.0.0.0 (not loopback) AND so the
#      `paperclipai auth bootstrap-ceo` CLI doesn't bail out silently.
#   2. Run bootstrap-ceo if no admin exists yet, capturing the invite URL.
# We do this BEFORE switching to the node user.
# ──────────────────────────────────────────────────────────────────────

CONFIG_DIR="/paperclip/instances/default"
CONFIG_FILE="$CONFIG_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ] && [ -n "$DATABASE_URL" ] && [ -n "$PAPERCLIP_PUBLIC_URL" ]; then
    echo "[bootstrap] No config found — writing minimal authenticated config"
    mkdir -p "$CONFIG_DIR"
    ALLOWED_HOST=$(echo "$PAPERCLIP_PUBLIC_URL" | sed -e 's|https\?://||' -e 's|/.*||')
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    # Use a heredoc with python to safely JSON-encode the connection string
    DB_JSON=$(printf '%s' "$DATABASE_URL" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')
    URL_JSON=$(printf '%s' "$PAPERCLIP_PUBLIC_URL" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')
    HOST_JSON=$(printf '%s' "$ALLOWED_HOST" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')

    cat > "$CONFIG_FILE" <<EOF
{
  "\$meta": { "version": 1, "updatedAt": "$NOW", "source": "configure" },
  "database": { "mode": "postgres", "connectionString": $DB_JSON },
  "logging": { "mode": "file", "logDir": "$CONFIG_DIR/logs" },
  "server": {
    "deploymentMode": "authenticated",
    "exposure": "private",
    "bind": "lan",
    "host": "0.0.0.0",
    "port": 8080,
    "allowedHostnames": [$HOST_JSON],
    "serveUi": true
  },
  "telemetry": { "enabled": false },
  "auth": {
    "baseUrlMode": "explicit",
    "publicBaseUrl": $URL_JSON,
    "disableSignUp": false
  }
}
EOF
    chown -R node:node /paperclip
    echo "[bootstrap] Config written. Running bootstrap-ceo…"
    cd /app
    BOOTSTRAP_OUT=$(gosu node pnpm paperclipai auth bootstrap-ceo 2>&1 || true)
    echo "$BOOTSTRAP_OUT"
    INVITE_URL=$(echo "$BOOTSTRAP_OUT" | grep -oE 'https?://[^ ]+/invite/[A-Za-z0-9_-]+' | head -1)
    if [ -n "$INVITE_URL" ]; then
        echo ""
        echo "──────────────────────────────────────────────────────────────"
        echo "[bootstrap] OWNER INVITE URL (open this once to set up):"
        echo "[bootstrap]   $INVITE_URL"
        echo "──────────────────────────────────────────────────────────────"
        echo ""
    else
        echo "[bootstrap] No invite URL captured — admin may already exist"
    fi
fi
# ──────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────
# Claude Code subscription auth — inject credentials from env var
# ──────────────────────────────────────────────────────────────────────
# When CLAUDE_CREDENTIALS_JSON is set (verbatim contents of a logged-in
# Mac's Claude credentials), write it into /paperclip/.claude/.credentials.json
# so Claude Code authenticates via Pro/Max subscription instead of API key.
# Re-runs on every container start so the file stays in sync with the env var.
# ──────────────────────────────────────────────────────────────────────

if [ -n "$CLAUDE_CREDENTIALS_JSON" ]; then
    echo "[bootstrap] Injecting Claude credentials from CLAUDE_CREDENTIALS_JSON"
    mkdir -p /paperclip/.claude
    printf '%s' "$CLAUDE_CREDENTIALS_JSON" > /paperclip/.claude/.credentials.json
    chmod 600 /paperclip/.claude/.credentials.json
    chown -R node:node /paperclip/.claude
fi

exec gosu node "$@"
