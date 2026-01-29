#!/usr/bin/env bash
# iteration-complete.sh - Detect review/refactor iteration completion
#
# This hook runs after Bash tool calls to detect when a ralpr label is set,
# signaling the end of an iteration.

set -euo pipefail

# The hook receives tool input as argument
INPUT="${1:-}"

# Check if this was a gh pr edit that set a ralpr:review or ralpr:refactor label
if echo "$INPUT" | grep -qE 'gh pr edit.*--add-label.*ralpr:(review|refactor):[0-9]+'; then
  cat << 'EOF'
<ralpr-iteration-complete>
✓ Iteration label set. This iteration is COMPLETE.

STOP NOW. Do not continue to the next iteration in this session.
The orchestrator will spawn a fresh Claude session if confidence threshold is not met.

Output your iteration result JSON and end your response.
</ralpr-iteration-complete>
EOF
fi
