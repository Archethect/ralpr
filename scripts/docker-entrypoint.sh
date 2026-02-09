#!/usr/bin/env bash
set -euo pipefail

# Start Xvfb
Xvfb :99 -screen 0 1920x1080x24 &

# Start noVNC (if port provided)
if [[ -n "${NOVNC_PORT:-}" ]]; then
  /opt/novnc/utils/novnc_proxy --vnc localhost:5900 --listen "${NOVNC_PORT}" &
fi

# Execute the main command
exec "$@"
