#!/usr/bin/env bash
# session-start.sh - Inject Ralpr skill into Claude session
#
# This hook runs at session start to provide the Ralpr skill definition

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_FILE="$PLUGIN_DIR/skills/ralpr/SKILL.md"

# Read the skill file and output as RALPR_SKILL tag
if [[ -f "$SKILL_FILE" ]]; then
  echo "<RALPR_SKILL>"
  echo "You have access to the Ralpr plugin v2.1."
  echo ""
  echo "**Plugin location:** $PLUGIN_DIR"
  echo ""
  echo "**IMPORTANT:** All Ralpr scripts are located at: $PLUGIN_DIR/scripts/ralpr"
  echo ""
  echo "When the skill references \`RALPR_SCRIPTS\`, use: $PLUGIN_DIR/scripts"
  echo ""
  echo "---"
  echo ""
  cat "$SKILL_FILE"
  echo "</RALPR_SKILL>"
fi
