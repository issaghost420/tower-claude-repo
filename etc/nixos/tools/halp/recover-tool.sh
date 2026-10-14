# halp tool: sqlite_recover. aichat calls bin/sqlite_recover '<json args>'.
# Only db + service come from the model; it can't pass --yes, so sqlite-recover
# always asks the human to type "yes" on the terminal before changing anything.
# Progress goes to the terminal and to $LLM_OUTPUT (what the model sees).

json="${1:-}"
[[ -n "$json" ]] || { echo "usage: sqlite_recover '<json>'" >&2; exit 1; }
db="$(jq -r '.db // empty' <<<"$json")"
service="$(jq -r '.service // empty' <<<"$json")"
scope="$(jq -r '.service_scope // "system"' <<<"$json")"

args=(--db "$db")
if [[ -z "$service" || "$service" == "none" ]]; then
  args+=(--no-service)
elif [[ "$scope" == "user" ]]; then
  args+=(--user-service "$service")
else
  args+=(--service "$service")
fi

out="${LLM_OUTPUT:-/dev/stdout}"
set +e
if { exec 4>/dev/tty; } 2>/dev/null; then
  sqlite-recover "${args[@]}" 2>&1 | tee /dev/fd/4 >> "$out"
  rc=${PIPESTATUS[0]}
  exec 4>&-
else
  sqlite-recover "${args[@]}" >> "$out" 2>&1
  rc=$?
fi
set -e
# Always exit 0 so aichat hands the result to the model instead of aborting
echo "[sqlite-recover exit code: $rc]" >> "$out"
