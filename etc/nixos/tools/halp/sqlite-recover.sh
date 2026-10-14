# sqlite-recover — recover a corrupted SQLite database, with guardrails.
# Generic version of fix-pi: any db, any service.
#
#   sqlite-recover --db ~/ninjastack/etc-pihole/pihole-FTL.db --service podman-pihole.service
#   sqlite-recover --db ~/app/data.db --user-service myapp.service
#   sqlite-recover --db ./notes.db --no-service
#
# - refuses to touch a healthy db, and won't mistake "can't open it" for corruption
# - shows the plan and needs you to type "yes" in the terminal (--yes skips, halp never passes it)
# - stops the service, re-checks, recovers into a new file, checks THAT, then swaps
# - original db (+ -wal/-shm) kept as <db>.broken_<timestamp>; owner and mode preserved
# - always restarts the service on the way out, even on error or Ctrl-C

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF_HELP'
sqlite-recover — recover a corrupted SQLite database, with guardrails.

USAGE
  sqlite-recover --db PATH (--service UNIT | --user-service UNIT | --no-service) [--dry-run] [--yes]

  --service UNIT       system unit that uses the db (stopped with sudo during recovery)
  --user-service UNIT  user unit (systemctl --user)
  --no-service         nothing has the db open
  --dry-run            check and show the plan, change nothing
  --yes                don't ask for confirmation
EOF_HELP
}

DB="" UNIT="" SCOPE="" NO_SERVICE=0 YES=0 DRY=0
while (( $# )); do
  case "$1" in
    --db) DB="${2:-}"; shift 2 ;;
    --service) UNIT="${2:-}"; SCOPE=system; shift 2 ;;
    --user-service) UNIT="${2:-}"; SCOPE=user; shift 2 ;;
    --no-service) NO_SERVICE=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$DB" ]] || { usage >&2; exit 2; }
[[ -e "$DB" ]] || die "$DB not found"
DB="$(realpath -- "$DB")"
[[ -f "$DB" ]] || die "$DB is not a regular file"
[[ "$DB" != /nix/store/* ]] || die "$DB is in the read-only nix store"
if [[ -n "$UNIT" && "$NO_SERVICE" == 1 ]]; then
  die "pick one of --service/--user-service/--no-service"
fi
if [[ -z "$UNIT" && "$NO_SERVICE" == 0 ]]; then
  die "say what uses the db: --service UNIT, --user-service UNIT, or --no-service"
fi

dir="$(dirname -- "$DB")"
SUDO=()
if [[ ! -r "$DB" || ! -w "$dir" || ! -O "$DB" ]]; then
  SUDO=(sudo)
fi

SYSCTL=(systemctl)
if [[ "$SCOPE" == user ]]; then
  SYSCTL=(systemctl --user)
elif [[ "$SCOPE" == system ]]; then
  SYSCTL=(sudo systemctl)
fi
if [[ -n "$UNIT" ]]; then
  # `systemctl cat` works unprivileged, just to confirm the unit exists
  if [[ "$SCOPE" == user ]]; then
    systemctl --user cat "$UNIT" >/dev/null 2>&1 || die "user unit $UNIT not found"
  else
    systemctl cat "$UNIT" >/dev/null 2>&1 || die "unit $UNIT not found"
  fi
fi

integrity() {
  "${SUDO[@]}" sqlite3 -readonly "$1" "PRAGMA integrity_check;" 2>&1 || true
}

# Exit 0 if healthy, die if it can't even be checked, return 1 if corrupt
check() {
  local res
  res="$(integrity "$DB")"
  if [[ "$res" == "ok" ]]; then
    return 0
  fi
  if grep -qiE "unable to open|not a database|permission denied|authorization denied|no such file" <<<"$res"; then
    die "can't check $DB, not treating this as corruption: $res"
  fi
  say "✗ corruption confirmed:"
  head -n 5 <<<"$res" | sed 's/^/    /'
  return 1
}

if check; then
  say "✓ $(basename -- "$DB") is healthy, nothing to do"
  exit 0
fi

ts="$(date +%Y%m%d_%H%M%S)"
backup="$DB.broken_$ts"
rec="$DB.recovered_$ts"

say ""
say "Plan:"
say "  db:       $DB ($(du -h -- "$DB" | cut -f1), owner $(stat -c '%U:%G %a' -- "$DB"))"
if [[ -n "$UNIT" ]]; then
  say "  service:  $UNIT ($SCOPE) will be stopped, then started again"
else
  say "  service:  none"
fi
say "  recover:  sqlite3 .recover -> $rec, must pass integrity_check"
say "  swap:     current db (+ -wal/-shm) -> $backup*"
if (( ${#SUDO[@]} )); then
  say "  sudo:     yes, for the file operations"
fi

if (( DRY )); then
  say "(dry run, nothing changed)"
  exit 0
fi

if (( ! YES )); then
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    die "needs a terminal to confirm (nothing changed)"
  fi
  printf '\nType "yes" to recover %s: ' "$(basename -- "$DB")" >&3
  read -r ans <&3 || ans=""
  exec 3>&-
  [[ "$ans" == "yes" ]] || die "aborted, nothing changed"
fi

stopped=0
start_service() {
  if (( stopped )); then
    "${SYSCTL[@]}" start "$UNIT" || say "!! failed to start $UNIT, start it by hand"
    stopped=0
  fi
}
on_exit() {
  if (( stopped )); then
    say "!! restarting $UNIT before exit"
    start_service
  fi
  "${SUDO[@]}" rm -f -- "$rec"
}
trap on_exit EXIT
trap 'exit 130' INT TERM HUP

if [[ -n "$UNIT" ]]; then
  say "stopping $UNIT"
  "${SYSCTL[@]}" stop "$UNIT"
  stopped=1
fi

# State can change once the writer is gone (e.g. a WAL checkpoint), check again
if check; then
  say "✓ healthy once $UNIT stopped, nothing to do"
  exit 0
fi

say "recovering..."
if ! "${SUDO[@]}" sqlite3 -readonly "$DB" ".recover" | "${SUDO[@]}" sqlite3 "$rec" >/dev/null; then
  say "warning: .recover reported errors, checking the result anyway"
fi

res="$(integrity "$rec")"
tables="$("${SUDO[@]}" sqlite3 -readonly "$rec" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)"
if [[ "$res" != "ok" || "$tables" == "0" ]]; then
  die "recovered db failed checks (integrity: ${res:0:200}, tables: $tables). Original left untouched"
fi

"${SUDO[@]}" chown --reference="$DB" -- "$rec"
"${SUDO[@]}" chmod --reference="$DB" -- "$rec"
"${SUDO[@]}" mv -- "$DB" "$backup"
for ext in -wal -shm; do
  if [[ -e "$DB$ext" ]]; then
    "${SUDO[@]}" mv -- "$DB$ext" "$backup$ext"
  fi
done
"${SUDO[@]}" mv -- "$rec" "$DB"
say "✓ recovered db swapped in ($tables tables)"

if [[ -n "$UNIT" ]]; then
  say "starting $UNIT"
  start_service
  sleep 3
  say "--- $UNIT: $("${SYSCTL[@]}" is-active "$UNIT" 2>&1 || true) ---"
  if [[ "$SCOPE" == user ]]; then
    journalctl --user-unit "$UNIT" --since "-2min" --no-pager 2>/dev/null \
      | grep -iE "imported|corrupt|malformed|damaged|disk I/O error" | tail -n 20 || true
  else
    sudo journalctl -u "$UNIT" --since "-2min" --no-pager 2>/dev/null \
      | grep -iE "imported|corrupt|malformed|damaged|disk I/O error" | tail -n 20 || true
  fi
fi

say "--- done ---"
say "old db kept at $backup (rm it once you're confident)"
