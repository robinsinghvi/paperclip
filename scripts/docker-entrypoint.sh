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

# Railway volumes are created as root — ensure node can write
if [ -d /paperclip ] && [ "$(stat -c '%u' /paperclip 2>/dev/null || stat -f '%u' /paperclip)" != "$PUID" ]; then
    chown -R node:node /paperclip
fi

# Codex CLI requires `codex login` to store auth in ~/.codex/ for the Responses API.
# OPENAI_API_KEY env var alone is insufficient (v0.118.0+). This is idempotent and
# writes to the persistent /paperclip volume (HOME=/paperclip).
if [ -n "$OPENAI_API_KEY" ] && command -v codex >/dev/null 2>&1; then
    echo "Configuring Codex CLI auth from OPENAI_API_KEY..."
    printf '%s' "$OPENAI_API_KEY" | gosu node codex login --with-api-key 2>/dev/null || true
fi

# Clone or refresh the Gramms monorepo onto the persistent volume so agents can
# read their AGENTS.md, deliverables/, and producthunt/video/ sources. Gated on
# GRAMMS_REPO_URL so SmartCue-only deployments are unaffected. Uses the existing
# GITHUB_TOKEN (shared with Webmaster/SmartCue) for auth; assumes `repo` scope.
if [ -n "${GRAMMS_REPO_URL:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    REPO_DIR=/paperclip/repos/gramms-ai-v2
    REPO_BRANCH=${GRAMMS_REPO_BRANCH:-develop}
    AUTHED_URL=$(echo "$GRAMMS_REPO_URL" | sed -E "s#https://#https://x-access-token:${GITHUB_TOKEN}@#")
    mkdir -p /paperclip/repos
    chown node:node /paperclip/repos
    if [ ! -d "$REPO_DIR/.git" ]; then
        echo "[entrypoint] cloning Gramms repo into $REPO_DIR ($REPO_BRANCH)"
        gosu node git clone --depth 50 --branch "$REPO_BRANCH" "$AUTHED_URL" "$REPO_DIR" || echo "[entrypoint] WARN: gramms clone failed"
    else
        echo "[entrypoint] refreshing Gramms repo in $REPO_DIR ($REPO_BRANCH)"
        (cd "$REPO_DIR" \
            && gosu node git remote set-url origin "$AUTHED_URL" \
            && gosu node git fetch --depth 50 origin "$REPO_BRANCH" \
            && gosu node git reset --hard "origin/$REPO_BRANCH") || echo "[entrypoint] WARN: gramms refresh failed"
    fi
fi

# Write .mcp.json into the cloned Gramms repo so Claude Code agents get MCP
# server access. Gated on EMAIL_USER so non-Gramms deployments are unaffected.
# BetterStack is an HTTP MCP (no local process). Email uses imap-email-mcp (stdio).
REPO_DIR=/paperclip/repos/gramms-ai-v2
if [ -d "$REPO_DIR" ] && [ -n "${EMAIL_USER:-}" ]; then
    MCP_JSON="$REPO_DIR/.mcp.json"
    # Build the mcpServers object
    MCP_SERVERS=""

    # Email MCP (imap-email-mcp) — requires EMAIL_USER + EMAIL_PASS
    if [ -n "${EMAIL_PASS:-}" ]; then
        MCP_SERVERS="\"email\": {
      \"command\": \"npx\",
      \"args\": [\"-y\", \"imap-email-mcp\"],
      \"env\": {
        \"IMAP_HOST\": \"${EMAIL_IMAP_HOST:-imap.secureserver.net}\",
        \"IMAP_PORT\": \"${EMAIL_IMAP_PORT:-993}\",
        \"SMTP_HOST\": \"${EMAIL_SMTP_HOST:-smtpout.secureserver.net}\",
        \"SMTP_PORT\": \"${EMAIL_SMTP_PORT:-465}\",
        \"EMAIL_USER\": \"${EMAIL_USER}\",
        \"EMAIL_PASS\": \"${EMAIL_PASS}\"
      }
    }"
    fi

    # BetterStack HTTP MCP — requires BETTERSTACK_API_TOKEN
    if [ -n "${BETTERSTACK_API_TOKEN:-}" ]; then
        if [ -n "$MCP_SERVERS" ]; then
            MCP_SERVERS="$MCP_SERVERS,
    "
        fi
        MCP_SERVERS="${MCP_SERVERS}\"betterstack\": {
      \"type\": \"http\",
      \"url\": \"https://mcp.betterstack.com\",
      \"headers\": {
        \"Authorization\": \"Bearer ${BETTERSTACK_API_TOKEN}\"
      }
    }"
    fi

    if [ -n "$MCP_SERVERS" ]; then
        cat > "$MCP_JSON" <<MCPEOF
{
  "mcpServers": {
    $MCP_SERVERS
  }
}
MCPEOF
        chown node:node "$MCP_JSON"
        echo "[entrypoint] wrote .mcp.json with MCP config into $REPO_DIR"
    fi
fi

exec gosu node "$@"
