#!/usr/bin/env bash
# stream-renderer.sh — Render Claude stream-json as a TUI-lite view
#
# Reads stream-json lines from stdin, outputs formatted ANSI text to stdout.
# Mimics Claude Code's native interactive TUI: green dots, tool names with
# input summaries, indented output previews, and completion summaries.
#
# Usage: claude ... --output-format stream-json --verbose | stream-renderer.sh

set -uo pipefail

# ANSI codes
GREEN='\033[32m'
BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
YELLOW='\033[33m'
RESET='\033[0m'

# Render a single stream-json line
render_line() {
  local line="$1"

  # Skip non-JSON lines (entrypoint messages, etc.)
  if [[ ! "$line" =~ ^\{ ]]; then
    return
  fi

  local type
  type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null) || return

  case "$type" in
    assistant)
      # Process each content block
      local blocks
      blocks=$(echo "$line" | jq -c '.message.content[]?' 2>/dev/null) || return

      while IFS= read -r block; do
        [[ -z "$block" ]] && continue
        local block_type
        block_type=$(echo "$block" | jq -r '.type // empty' 2>/dev/null) || continue

        case "$block_type" in
          text)
            local text
            text=$(echo "$block" | jq -r '.text // empty' 2>/dev/null) || continue
            [[ -z "$text" ]] && continue
            printf "${GREEN}●${RESET} %s\n" "$text"
            ;;
          tool_use)
            local name input_summary
            name=$(echo "$block" | jq -r '.name // "?"' 2>/dev/null)
            input_summary=$(extract_input_summary "$block" "$name")
            if [[ "$name" == "Task" ]]; then
              printf "${CYAN}⬡${RESET} ${BOLD}${CYAN}%s${RESET}${DIM}(%s)${RESET}\n" "$name" "$input_summary"
            else
              printf "${GREEN}●${RESET} ${BOLD}%s${RESET}(%s)\n" "$name" "$input_summary"
            fi
            ;;
        esac
      done <<< "$blocks"
      ;;

    user)
      # Tool results — show indented output preview
      local tool_result
      tool_result=$(echo "$line" | jq -r '
        if .tool_use_result then
          .tool_use_result.stdout // .tool_use_result.stderr // empty
        elif .message.content then
          (.message.content[]? |
            if .type == "tool_result" then
              if (.content | type) == "string" then .content
              elif (.content | type) == "array" then (.content[]? | select(.type == "text") | .text)
              else empty end
            else empty end)
        else empty end
      ' 2>/dev/null)

      if [[ -n "$tool_result" ]]; then
        # Show first 2 lines of output, truncated
        local preview
        preview=$(echo "$tool_result" | head -2 | cut -c1-120)
        local total_lines
        total_lines=$(echo "$tool_result" | wc -l | tr -d ' ')

        if [[ -n "$preview" ]]; then
          while IFS= read -r pline; do
            printf "  ${DIM}└ %s${RESET}\n" "$pline"
          done <<< "$preview"

          if [[ "$total_lines" -gt 2 ]]; then
            local remaining=$((total_lines - 2))
            printf "  ${DIM}  … +%d lines${RESET}\n" "$remaining"
          fi
        fi
      fi
      ;;

    result)
      local turns cost duration
      turns=$(echo "$line" | jq -r '.num_turns // "?"' 2>/dev/null)
      cost=$(echo "$line" | jq -r '(.total_cost_usd // 0) | tostring | .[0:6]' 2>/dev/null)
      duration=$(echo "$line" | jq -r '(.duration_ms // 0) / 1000 | floor | tostring' 2>/dev/null)
      printf "\n${GREEN}✓${RESET} ${BOLD}Done${RESET} (%s turns · \$%s · %ss)\n" "$turns" "$cost" "$duration"
      ;;
  esac
}

# Extract a human-readable input summary for a tool_use block
extract_input_summary() {
  local block="$1"
  local name="$2"

  case "$name" in
    Bash)
      echo "$block" | jq -r '.input.command // "" | .[0:120]' 2>/dev/null
      ;;
    Read|NotebookRead)
      echo "$block" | jq -r '.input.file_path // ""' 2>/dev/null
      ;;
    Edit)
      echo "$block" | jq -r '.input.file_path // ""' 2>/dev/null
      ;;
    Write|NotebookEdit)
      echo "$block" | jq -r '.input.file_path // .input.notebook_path // ""' 2>/dev/null
      ;;
    Grep)
      echo "$block" | jq -r '(.input.pattern // "") + " " + (.input.path // "")' 2>/dev/null
      ;;
    Glob)
      echo "$block" | jq -r '.input.pattern // ""' 2>/dev/null
      ;;
    Task)
      echo "$block" | jq -r '.input.description // "" | .[0:80]' 2>/dev/null
      ;;
    Skill)
      echo "$block" | jq -r '.input.skill // ""' 2>/dev/null
      ;;
    WebFetch)
      echo "$block" | jq -r '.input.url // ""' 2>/dev/null
      ;;
    WebSearch)
      echo "$block" | jq -r '.input.query // ""' 2>/dev/null
      ;;
    *)
      # MCP tools or unknown — show first key=value
      echo "$block" | jq -r '.input | to_entries | .[0:2] | map(.value | tostring | .[0:60]) | join(", ")' 2>/dev/null
      ;;
  esac
}

# Main loop: read stream-json lines and render.
# || true ensures a rendering failure on one line never kills the pipeline.
while IFS= read -r line; do
  render_line "$line" || true
done
