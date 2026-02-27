#!/bin/bash
# entrypoint.sh — IT-Stack mattermost container entrypoint
set -euo pipefail

echo "Starting IT-Stack MATTERMOST (Module 07)..."

# Source any environment overrides
if [ -f /opt/it-stack/mattermost/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/mattermost/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
