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

exec gosu node "$@"
