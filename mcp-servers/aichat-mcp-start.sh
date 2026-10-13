#!/usr/bin/env bash
# (Re)start the llm-functions MCP bridge and make functions.json loadable by aichat.
# aichat only accepts string enums; some MCP servers (mcp-searxng safesearch: [0,1,2])
# use numbers, which makes aichat refuse to load ANY tools. Strip those enums.
set -euo pipefail

LLM_FUNCTIONS_DIR="${LLM_FUNCTIONS_DIR:-$HOME/tools/llm-functions}"
cd "$LLM_FUNCTIONS_DIR"

argc mcp start

jq 'walk(if type == "object" and (.enum | type) == "array" and any(.enum[]; type != "string") then del(.enum) else . end)' \
  functions.json > functions.json.tmp && mv functions.json.tmp functions.json

# Route every MCP tool through the loop guard (argc rebuilds these symlinks on each start)
GUARD="$HOME/tools/mcp-servers/llm-tool-guard.sh"
for bin in bin/*; do
  if [[ -L "$bin" && "$(readlink "$bin")" == *run-mcp-tool.sh ]]; then
    ln -sfn "$GUARD" "$bin"
  fi
done
