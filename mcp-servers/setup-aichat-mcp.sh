#!/usr/bin/env bash
# One-time setup: wire MCP servers into aichat through llm-functions' MCP bridge.
#   aichat -> ~/.config/aichat/functions (llm-functions) -> bridge :8808 -> MCP servers
# Re-runnable. Needs argc, jq, curl, node (see etc/nixos/packages.nix).
set -euo pipefail

LLM_FUNCTIONS_DIR="${LLM_FUNCTIONS_DIR:-$HOME/tools/llm-functions}"
MCP_JSON="$HOME/tools/mcp-servers/llm-functions-mcp.json"
AICHAT_FUNCTIONS_LINK="$HOME/.config/aichat/functions"

for bin in argc jq curl node npm git; do
  command -v "$bin" >/dev/null || { echo "missing: $bin (nix-switch first)"; exit 1; }
done

if [[ ! -d "$LLM_FUNCTIONS_DIR/.git" ]]; then
  git clone https://github.com/sigoden/llm-functions "$LLM_FUNCTIONS_DIR"
fi

# Bridge reads <llm-functions-dir>/mcp.json
ln -sfn "$MCP_JSON" "$LLM_FUNCTIONS_DIR/mcp.json"

# aichat looks for tools in ~/.config/aichat/functions
if [[ -L "$AICHAT_FUNCTIONS_LINK" || ! -e "$AICHAT_FUNCTIONS_LINK" ]]; then
  ln -sfn "$LLM_FUNCTIONS_DIR" "$AICHAT_FUNCTIONS_LINK"
else
  echo "error: $AICHAT_FUNCTIONS_LINK exists and isn't a symlink, move it and re-run"; exit 1
fi

cd "$LLM_FUNCTIONS_DIR"
argc mcp start
echo
echo "Tools aichat can see:"
jq -r '.[].name' functions.json
