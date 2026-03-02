#!/bin/bash
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if echo "$COMMAND" | grep -q "sudo"; then
  DISPLAY_CMD=$(echo "$COMMAND" | cut -c1-100)
  osascript -e "display notification \"$DISPLAY_CMD\" with title \"Claude Code\" subtitle \"Sudo password needed\""
fi

exit 0
