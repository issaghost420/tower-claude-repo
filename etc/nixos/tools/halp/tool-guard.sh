#!/usr/bin/env bash
# Loop guard for llm-functions MCP tools. aichat has no limit on tool-call rounds,
# so small models can call the same tool forever and blow the context.
# halp-mcp-start points every llm-functions/bin/<mcp tool> symlink here.
#
# Only active when LLM_GUARD_FILE is set (halp sets one per run):
#   - same tool + same arguments twice  -> returns "already called, answer now" instead
#   - more than LLM_GUARD_MAX calls      -> returns "limit reached, answer now"
#   - model ignores 3 of those STOPs     -> exits 1, which makes aichat abort the run
# Otherwise it hands off to llm-functions' normal run-mcp-tool.sh.

LLM_FUNCTIONS_DIR="${LLM_FUNCTIONS_DIR:-$HOME/tools/llm-functions}"
tool="$(basename "$0")"
args="${1:-}"

reply() {
  # Model ignored 3 STOPs already -> non-zero exit makes aichat abort the whole run
  echo x >> "$LLM_GUARD_FILE.stops"
  if (( $(wc -l < "$LLM_GUARD_FILE.stops") > 3 )); then
    echo "halp tool-guard: model kept calling tools after being told to stop, aborting" >&2
    exit 1
  fi
  # aichat reads tool output from $LLM_OUTPUT
  printf '%s\n' "$1" > "${LLM_OUTPUT:-/dev/stdout}"
  exit 0
}

if [[ -n "${LLM_GUARD_FILE:-}" ]]; then
  key="$tool $args"
  if grep -qxF -- "$key" "$LLM_GUARD_FILE" 2>/dev/null; then
    reply "STOP: you already called $tool with these exact arguments and the result is above in this conversation. Do not call it again. Use what you have and answer the user now."
  fi
  printf '%s\n' "$key" >> "$LLM_GUARD_FILE"
  count=$(wc -l < "$LLM_GUARD_FILE")
  if (( count > ${LLM_GUARD_MAX:-12} )); then
    reply "STOP: tool call limit (${LLM_GUARD_MAX:-12}) reached. Do not call any more tools. Answer the user now with what you have, and say what you couldn't finish."
  fi
fi

exec "$LLM_FUNCTIONS_DIR/scripts/run-mcp-tool.sh" "$tool" "$args"
