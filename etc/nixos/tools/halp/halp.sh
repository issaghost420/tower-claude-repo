# halp — ask the local LLM (aichat -> LM Studio) a question, with web search,
# file reading and create-only file writing through MCP tools.
#
#   halp "why is nix-switch failing"     ask (keeps a rolling window of recent turns)
#   halp -n "new topic"                  flush the history, then ask
#   halp --flush                         flush the history
#   halp --history                       show what's in the window
#
# The zsh wrapper in halp.nix pipes in the current directory + recent commands.
# History is question/answer text only (no raw tool output), so it stays small.
# HALP_ROLES_DIR, HALP_MCP_START are set by halp.nix.

HALP_STATE="${HALP_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/halp}"
HIST="$HALP_STATE/history.jsonl"
TURNS="${HALP_TURNS:-6}"                  # how many past Q/A pairs to send
MAX_CHARS="${HALP_HISTORY_CHARS:-12000}"  # and at most this many chars of them
TIMEOUT="${HALP_TIMEOUT:-180}"

usage() {
  cat <<'EOF_HELP'
halp — ask the local LLM, with web search and file tools.

USAGE
  halp QUESTION...          ask (remembers the last few turns)
  halp -n QUESTION...       start fresh (flush history), then ask
  halp --flush              flush history
  halp --history            show the current history window
  halp --restart-tools      restart the MCP bridge

ENV
  HALP_TURNS=6              past question/answer pairs sent with each question
  HALP_HISTORY_CHARS=12000  cap on history size sent
  HALP_TIMEOUT=180          seconds before the run is killed
  HALP_DEBUG=1              show aichat's errors
EOF_HELP
}

mkdir -p "$HALP_STATE"

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --flush)
    rm -f "$HIST"
    echo "halp: history flushed" >&2
    exit 0 ;;
  -n|--new)
    rm -f "$HIST"
    shift ;;
  --history)
    if [[ -s "$HIST" ]]; then
      tail -n "$TURNS" "$HIST" | jq -r '"\u001b[1m> \(.q)\u001b[0m\n\(.a)\n"'
    else
      echo "halp: history is empty" >&2
    fi
    exit 0 ;;
  --restart-tools)
    (cd "${LLM_FUNCTIONS_DIR:-$HOME/tools/llm-functions}" && argc mcp stop >/dev/null 2>&1) || true
    exec "$HALP_MCP_START" ;;
esac

question="$*"
if [[ -z "$question" ]]; then
  usage >&2
  exit 2
fi

shell_ctx=""
if [[ ! -t 0 ]]; then
  shell_ctx="$(cat)"
fi

# Rolling window: newest turns first until TURNS or MAX_CHARS is hit, then back in order
history=""
if [[ -s "$HIST" ]]; then
  history="$(tail -n "$TURNS" "$HIST" | jq -rs --argjson max "$MAX_CHARS" '
    reverse
    | reduce .[] as $t ({out: [], n: 0, full: false};
        ("User: \($t.q)\nYou: \($t.a)") as $s
        | if .full or (.n + ($s | length) > $max) then .full = true
          else .out = [$s] + .out | .n += ($s | length) end)
    | .out | join("\n\n")')"
fi

prompt=""
if [[ -n "$history" ]]; then
  prompt+="Earlier in this conversation (oldest first; your tool results are not included, re-check with tools if you need details):
$history

---
"
fi
if [[ -n "$shell_ctx" ]]; then
  prompt+="$shell_ctx

"
fi
prompt+="Question: $question"

# Bridge doesn't survive reboots, start it if it's down
if ! curl -fsS --max-time 2 http://localhost:8808/health >/dev/null 2>&1; then
  echo "⏳ starting MCP bridge..." >&2
  # llm-functions waits forever if the bridge dies (e.g. a broken MCP server path), so cap it
  timeout 60 "$HALP_MCP_START" >/dev/null 2>&1 || echo "⚠️  MCP bridge failed to start, no tools this time (halp --restart-tools to see why)" >&2
fi

guard="$(mktemp -t halp-guard.XXXXXX)"
out="$(mktemp -t halp-out.XXXXXX)"
trap 'rm -f "$guard" "$guard.stops" "$out"' EXIT

errout=/dev/null
if [[ -n "${HALP_DEBUG:-}" ]]; then
  errout=/dev/stderr
fi

export AICHAT_ENV_FILE="${AICHAT_ENV_FILE:-$HOME/.secrets/lms.env}"
export AICHAT_ROLES_DIR="$HALP_ROLES_DIR"
export LLM_FUNCTIONS_DIR="${LLM_FUNCTIONS_DIR:-$HOME/tools/llm-functions}"
export LLM_GUARD_FILE="$guard"
export LLM_GUARD_MAX="${HALP_MAX_TOOLS:-12}"
# halp only exposes read + create-only tools, skip llm-functions' confirm prompt for them
export LLM_MCP_SKIP_CONFIRM='web_search_searxng_web_search|web_search_web_url_read|local_files_read_file|local_files_read_multiple_files|local_files_list_directory|local_files_directory_tree|local_files_search_files|local_files_get_file_info|local_files_list_allowed_directories|local_files_create_file'

set +e
printf '%s\n' "$prompt" \
  | timeout "$TIMEOUT" aichat -r halp 2>"$errout" \
  | sed '/<think>/,/<\/think>/d; /<think>/,$d' \
  | tee "$out"
rc=${PIPESTATUS[1]}
set -e

if (( rc == 124 )); then
  echo "⚠️  halp: timed out after ${TIMEOUT}s" >&2
elif (( rc != 0 )); then
  echo "⚠️  halp: aichat exited $rc (tool loop abort or error, rerun with HALP_DEBUG=1 to see it)" >&2
elif [[ -s "$out" ]]; then
  jq -nc --arg q "$question" --rawfile a "$out" '{t: (now | todate), q: $q, a: ($a | rtrimstr("\n"))}' >> "$HIST"
  # keep the file itself small too
  tail -n 50 "$HIST" > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
fi
exit "$rc"
