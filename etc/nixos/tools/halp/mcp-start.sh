# halp-mcp-start: (re)start the llm-functions MCP bridge that gives aichat its tools.
#   aichat -> ~/.config/aichat/functions (llm-functions) -> bridge :8808 -> MCP servers
# Idempotent: clones llm-functions and links it into aichat on first run.
# HALP_MCP_JSON and HALP_TOOL_GUARD are set by halp.nix.

LLM_FUNCTIONS_DIR="${LLM_FUNCTIONS_DIR:-$HOME/tools/llm-functions}"
functions_link="${AICHAT_CONFIG_DIR:-$HOME/.config/aichat}/functions"

if [[ ! -d "$LLM_FUNCTIONS_DIR/.git" ]]; then
  git clone --depth 1 https://github.com/sigoden/llm-functions "$LLM_FUNCTIONS_DIR"
fi

# Bridge reads <llm-functions-dir>/mcp.json
ln -sfn "$HALP_MCP_JSON" "$LLM_FUNCTIONS_DIR/mcp.json"

# aichat looks for tools in ~/.config/aichat/functions
if [[ -L "$functions_link" || ! -e "$functions_link" ]]; then
  ln -sfn "$LLM_FUNCTIONS_DIR" "$functions_link"
else
  echo "halp-mcp-start: $functions_link exists and isn't a symlink, move it and re-run" >&2
  exit 1
fi

cd "$LLM_FUNCTIONS_DIR" || exit 1
argc mcp start

# aichat only accepts string enums; some MCP servers (mcp-searxng safesearch: [0,1,2])
# use numbers, which makes aichat refuse to load ANY tools. Strip those enums.
jq 'walk(if type == "object" and (.enum | type) == "array" and any(.enum[]; type != "string") then del(.enum) else . end)' \
  functions.json > functions.json.tmp
mv functions.json.tmp functions.json

# Route every MCP tool through the loop guard (argc rebuilds these symlinks on each start)
jq -r '.[] | select(.mcp) | .name' functions.json | while read -r tool; do
  ln -sfn "$HALP_TOOL_GUARD" "bin/$tool"
done

echo "halp-mcp-start: bridge up, tools: $(jq -r '[.[] | select(.mcp) | .name] | join(" ")' functions.json)"
