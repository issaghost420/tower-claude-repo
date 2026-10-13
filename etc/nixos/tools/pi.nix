# pi.nix — Pi-hole v6 direct-SQL CLI. Import it and rebuild:
#   imports = [ ./tools/pi.nix ];
#   programs.pi-cli.enable = true;

{ config, pkgs, lib, ... }:

let
  cfg = config.programs.pi-cli;

  piEngine = pkgs.writeShellApplication {
    name = "pi";
    runtimeInputs = with pkgs; [ sqlite coreutils gnugrep ];
    excludeShellChecks = [ "SC2016" "SC2317" ];
    text = ''
      set -o pipefail

      PI_VERSION="2.1.0"
      DB="''${PIHOLE_DB:-/mnt/dacrib/home/dacrib/ninjastack/etc-pihole/gravity.db}"
      FTLDB="''${PIHOLE_FTL_DB:-$(dirname "$DB")/pihole-FTL.db}"
      # Sidecar for our own data (hidden query-log rules). Deliberately NOT
      # inside gravity.db: pihole -g can swap/rebuild that file.
      PI_DB="''${PI_DB:-$(dirname "$DB")/pi-cli.db}"
      # FTL runs in a rootful podman container; no pihole binary on the host.
      # Set PI_CONTAINER="" to call a host-installed pihole instead.
      PI_CONTAINER="''${PI_CONTAINER:-pihole}"
      # v2 knobs
      PI_DISABLE_DEFAULT="''${PI_DISABLE_DEFAULT:-15}"   # bare `pi disable` seconds
      PI_TOGGLE_REENABLE_MIN="''${PI_TOGGLE_REENABLE_MIN:-20}"  # 0 = never auto re-enable

      # Elevate if we can't both read *and* write gravity.db ourselves.
      # (v1.0 checked readability only, so writes could die mid-command.)
      SUDO=()
      if [[ ! -r "$DB" || ! -w "$DB" ]]; then
          SUDO=(sudo)
      fi

      # Same decision for the FTL db (read-only for us) and the sidecar (rw).
      SUDO_FTL=()
      if [[ ! -r "$FTLDB" ]] \
          || { [[ -e "$PI_DB" ]] && { [[ ! -r "$PI_DB" ]] || [[ ! -w "$PI_DB" ]]; }; } \
          || { [[ ! -e "$PI_DB" ]] && [[ ! -w "''${PI_DB%/*}" ]]; }; then
          SUDO_FTL=(sudo)
      fi

      # .timeout: ride out FTL's write locks instead of failing instantly.
      _pi_sql()  { "''${SUDO[@]}"     sqlite3 "$DB"    ".timeout 5000" "$@"; }
      _pi_sqlw() { "''${SUDO[@]}"     sqlite3 "$DB"    ".timeout 5000" "$@"; }
      _pi_ftl()  { "''${SUDO_FTL[@]}" sqlite3 "$FTLDB" ".timeout 5000" "$@"; }
      _pi_pidb() { "''${SUDO_FTL[@]}" sqlite3 "$PI_DB" ".timeout 5000" "$@"; }

      # Run the pihole CLI inside its container (rootful podman).
      _pi_pihole() {
          if [[ -n "$PI_CONTAINER" ]]; then
              sudo podman exec "$PI_CONTAINER" pihole "$@"
          else
              pihole "$@"
          fi
      }

      # v6 commands: reloadlists (domain/adlists) and reloaddns (cache flush).
      # restartdns was REMOVED in v6 — don't fall back to it.
      # Returns real status; callers decide how loud to be. Never silently 0:
      # a write without a reload leaves FTL serving the old lists.
      _pi_reload() {
          _pi_pihole reloadlists >/dev/null 2>&1 \
              || _pi_pihole reloaddns >/dev/null 2>&1
      }

      _pi_reload_or_warn() {
          _pi_reload \
              || echo "⚠  change saved to gravity.db but FTL reload failed — run: pi reload" >&2
      }

      _pi_type_code() {
          case "$1" in
              allow|exact-allow|--exact-allow|0)          echo 0 ;;
              deny|block|exact-deny|--exact-deny|1)       echo 1 ;;
              ra|r-allow|allow-regex|regex-allow|--allow-regex|2) echo 2 ;;
              rd|r-deny|deny-regex|regex-deny|--deny-regex|3)       echo 3 ;;
              *) echo "" ;;
          esac
      }

      _pi_type_label() {
          case "$1" in
              0) echo "exact-allow" ;;
              1) echo "exact-deny"  ;;
              2) echo "regex-allow" ;;
              3) echo "regex-deny"  ;;
          esac
      }

      # FTL query-type ids (NOT wire numbers): 1=A 2=AAAA 3=ANY 4=SRV 5=SOA
      # 6=PTR 7=TXT 8=NAPTR 9=MX 10=DS 11=RRSIG 12=DNSKEY 13=NS 14=OTHER
      # 15=SVCB 16=HTTPS; everything else is stored as <wire type> + 100.
      _pi_qtype_code() {
          local u="''${1^^}"
          case "$u" in
              A|1) echo 1 ;;          AAAA|2) echo 2 ;;     ANY|3) echo 3 ;;
              SRV|4) echo 4 ;;        SOA|5) echo 5 ;;      PTR|6) echo 6 ;;
              TXT|7) echo 7 ;;        NAPTR|8) echo 8 ;;    MX|9) echo 9 ;;
              DS|10) echo 10 ;;       RRSIG|11) echo 11 ;;  DNSKEY|12) echo 12 ;;
              NS|13) echo 13 ;;       OTHER|14) echo 14 ;;  SVCB|15) echo 15 ;;
              HTTPS|16) echo 16 ;;
              TYPE[0-9]*)
                  local n="''${u#TYPE}"
                  [[ "$n" =~ ^[0-9]+$ ]] && echo $((n + 100)) ;;
              *) echo "" ;;
          esac
      }

      # FTL query status ids, bucketed for stats (granted vs blocked).
      # granted: forwarded 2, cached 3, retried 12/13, already-fwd 14, stale 17
      # blocked: gravity 1, regex 4, deny 5, external 6/7/8, CNAME-cloaked
      #          variants 9/10/11, busy 15, special 16, ede15 18
      PI_STATUS_GRANTED="2,3,12,13,14,17"
      PI_STATUS_BLOCKED="1,4,5,6,7,8,9,10,11,15,16,18"

      # v1.2: warn when the same literal entry exists under another list type.
      # exact-allow beats exact-deny in FTL, so a silent type-0 row quietly
      # unblocks something you think is denied. Literal match only — a regex
      # that *matches* the domain isn't caught (and is often intentional).
      _pi_cross_type_warn() {
          local type_code="$1" safe="$2" entry="$3"
          local others t
          others=$(_pi_sql "SELECT DISTINCT type FROM domainlist
                            WHERE domain='$safe' AND type != $type_code ORDER BY type;") || others=""
          [[ -z "$others" ]] && return 0
          while IFS= read -r t; do
              [[ -z "$t" ]] && continue
              echo "⚠  '$entry' also present as [$(_pi_type_label "$t")] — allow wins over deny; undo with: pi rm $entry $t" >&2
          done <<< "$others"
      }

      # SQL-escape single quotes via bash parameter expansion.
      _pi_esc() { printf "%s" "''${1//\'/\'\'}"; }

      # Normalize a hide/show value per kind.
      _pi_norm() {
          local kind="$1" value="$2"
          case "$kind" in
              domain) value="''${value,,}"; value="''${value%.}" ;;
              mac)    value="''${value,,}" ;;
          esac
          printf "%s" "$value"
      }

      _pi_help() {
          cat <<EOF
pi — Pi-hole v6 direct-SQL CLI (bypasses the WebUI when it lies)
      gravity: $DB
      ftl:     $FTLDB
      sidecar: $PI_DB ''${SUDO[*]:+(gravity: sudo)}''${SUDO_FTL[*]:+(ftl/sidecar: sudo)}
      pihole:  $(if [[ -n "$PI_CONTAINER" ]]; then echo "podman exec $PI_CONTAINER pihole"; else echo "host binary"; fi)

ADD                                          (atomic: dup -> "= already present")
  pi allow        <domain> [domain ...]   Exact allow   (type 0)
  pi deny         <domain> [domain ...]   Exact deny    (type 1)   [alias: block]
  pi allow-regex  <pattern> [...]         Regex allow   (type 2)   [aliases: ra, r-allow]
  pi deny-regex   <pattern> [...]         Regex deny    (type 3)   [aliases: rd, r-deny]
    multiple entries per call; FTL reloads once at the end
    warns if the same entry already exists under another list type
    (exact-allow beats exact-deny in FTL — stacking is usually a mistake)

BLOCKING ON/OFF                              (wraps pihole disable/enable)
  pi disable [seconds]       Disable blocking; 0 = until re-enabled.
  pi pause   [seconds]       Bare flag falls back to \$PI_DISABLE_DEFAULT
  pi -d|-p   [seconds]       (default 15): "blocking disabled for 15 seconds"
  pi enable                  Re-enable blocking now

QUERY
  pi find   <needle>           Search domainlist + gravity (LIKE %needle%).
                               If the needle looks like an IP or MAC, also shows
                               the device (hostname/MAC/iface/last-seen) and its
                               24h query totals from the FTL db
  pi list   [allow|deny|ra|rd|r-allow|r-deny|any]   Dump entries (all if no type given)
  pi groups                    List groups
  pi adlists                   List gravity sources
  pi status                    up? + 24h granted/blocked/block_rate + FTL
                               integrity + per-list counts + orphans
  pi offenders                 Top 10 clients by query volume (last 24h)
  pi orphans [--fix]           Show/repair unlinked rows + dangling group links
  pi schema                    Dump gravity.db schema
  pi tables                    List tables in gravity.db

QUERY LOG VISIBILITY           (rules live in the sidecar db, survive pihole -g)
  pi hide   <device|ip|mac|domain|type> <value>
                               Hide matching rows from 'pi querylog'
                                 domain: also hides subdomains (case-insensitive)
                                 type:   A AAAA ANY SRV SOA PTR TXT NAPTR MX DS
                                         RRSIG DNSKEY NS SVCB HTTPS, or TYPE<n>
                                         (e.g. TYPE65; stored as FTL id <n>+100)
  pi show   <kind> <value>     Un-hide a rule            [alias: unhide]
  pi hidden                    List the hidden rules
  pi querylog [-q|--show-hidden] [N] [pattern]
                               Last N queries (default 25, window: last 24h)
                               from pihole-FTL.db. Optional pattern filters
                               domain/client server-side (LIKE %pattern%);
                               output stays grep-able: pi querylog 50 | grep blocked
                               Hidden rules are filtered out; -q includes them
                               [aliases: qlog, log]

REMOVE / TOGGLE
  pi rm     <domain> [type|any]     Delete (prompts). type: allow|deny|ra|rd|any
  pi toggle <domain> [type|any]     Flip enabled 0/1. Entries toggled OFF
                                    auto re-enable after \$PI_TOGGLE_REENABLE_MIN
                                    minutes (default 20; 0 disables the timer)
    rm/toggle smart match: no exact hit -> falls back to a host-boundary
    match (domain LIKE '%.<needle>'); proceeds only when exactly ONE
    distinct domain matches, otherwise lists candidates and aborts

OPS                                          (pihole CLI runs inside the container)
  pi reload                    reloadlists → reloaddns; real errors shown,
                               fails loudly if the container is unreachable
  pi rebuild                   pihole -g (full pull + rebuild)
  pi raw    "<sql>"            Arbitrary SQL against gravity.db — use with care

  -h | --help                  This screen
  -V | --version               Version

ENVIRONMENT
  PIHOLE_DB       gravity.db path    (default /mnt/dacrib/home/dacrib/ninjastack/etc-pihole/gravity.db)
  PIHOLE_FTL_DB   pihole-FTL.db path (default: <gravity dir>/pihole-FTL.db)
  PI_DB           hidden-rules db    (default: <gravity dir>/pi-cli.db)
  PI_CONTAINER    podman container with FTL (default: pihole; "" = host binary)
  PI_DISABLE_DEFAULT      seconds for bare pi disable/pause/-d/-p (default 15)
  PI_TOGGLE_REENABLE_MIN  auto re-enable after toggle-off, minutes (default 20, 0=off)
EOF
      }

      # v2: batch add. Same atomic INSERT OR IGNORE ... RETURNING per entry,
      # but FTL reloads ONCE after the whole batch instead of per domain.
      _pi_add() {
          local type_code="$1"; shift
          if [[ $# -eq 0 ]]; then
              echo "usage: pi $(_pi_type_label "$type_code") <entry> [entry ...]" >&2
              return 2
          fi
          local changed=0 entry safe newid existing linked
          for entry in "$@"; do
              safe=$(_pi_esc "$entry")
              if ! newid=$(_pi_sqlw "INSERT OR IGNORE INTO domainlist
                       (type, domain, enabled, date_added, date_modified, comment)
                     VALUES ($type_code, '$safe', 1, strftime('%s','now'), strftime('%s','now'), 'via pi')
                     RETURNING id;"); then
                  echo "✗ add failed for '$entry' (sqlite error above)" >&2
                  continue
              fi
              if [[ -z "$newid" ]]; then
                  existing=$(_pi_sql "SELECT id FROM domainlist WHERE type=$type_code AND domain='$safe';") || existing=""
                  echo "= already present (id=''${existing:-?}) [$(_pi_type_label "$type_code")] $entry"
                  _pi_cross_type_warn "$type_code" "$safe" "$entry"
                  continue
              fi
              if ! _pi_sqlw "INSERT OR IGNORE INTO domainlist_by_group (domainlist_id, group_id)
                             VALUES ($newid, 0);"; then
                  echo "⚠  added (id=$newid) but group link failed — run: pi orphans --fix" >&2
                  continue
              fi
              # A stale (id, 0) link can survive from a long-deleted entry and
              # get hit when sqlite reuses the rowid. OR IGNORE absorbs that —
              # but verify the link is really there before claiming success.
              linked=$(_pi_sql "SELECT 1 FROM domainlist_by_group WHERE domainlist_id=$newid LIMIT 1;") || linked=""
              if [[ -z "$linked" ]]; then
                  echo "⚠  added (id=$newid) but no group link — run: pi orphans --fix" >&2
                  continue
              fi
              echo "+ added (id=$newid) [$(_pi_type_label "$type_code")] $entry"
              _pi_cross_type_warn "$type_code" "$safe" "$entry"
              changed=1
          done
          [[ "$changed" -eq 1 ]] && _pi_reload_or_warn
          return 0
      }

      # v2: disable/pause blocking, thin wrapper over pihole v6 disable.
      _pi_disable() {
          local secs="''${1:-$PI_DISABLE_DEFAULT}"
          if [[ ! "$secs" =~ ^[0-9]+$ ]]; then
              echo "usage: pi disable [seconds]   (0 = until re-enabled; default $PI_DISABLE_DEFAULT)" >&2
              return 2
          fi
          local msg
          if [[ "$secs" -eq 0 ]]; then
              msg="blocking disabled until re-enabled (pi enable)"
          else
              msg="blocking disabled for $secs seconds"
          fi
          # v6: pihole disable wants a unit suffix ("30s", "10m"); a bare
          # integer is rejected — that was the "disable failed" bug.
          local rc=0
          if [[ "$secs" -eq 0 ]]; then
              _pi_pihole disable >/dev/null || rc=$?
          else
              _pi_pihole disable "''${secs}s" >/dev/null || rc=$?
          fi
          if [[ "$rc" -eq 0 ]]; then
              echo "$msg"
          else
              echo "✗ disable failed (rc=$rc) — try: sudo podman exec $PI_CONTAINER pihole disable ''${secs}s" >&2
              return 1
          fi
      }

      # v2: top talkers from the FTL long-term db.
      _pi_offenders() {
          [[ ! -e "$FTLDB" ]] && { echo "✗ $FTLDB not found (set PIHOLE_FTL_DB)" >&2; return 1; }
          echo "── top 10 offenders (last 24h) ──"
          _pi_ftl -header -column "
            SELECT q.client,
                   COUNT(*) AS queries,
                   SUM(CASE WHEN q.status IN ($PI_STATUS_BLOCKED) THEN 1 ELSE 0 END) AS blocked
              FROM queries q
             WHERE q.timestamp >= strftime('%s','now','-1 day')
             GROUP BY q.client
             ORDER BY queries DESC
             LIMIT 10;"
      }

      _pi_find() {
          local needle="''${1:-}"
          [[ -z "$needle" ]] && { echo "usage: pi find <needle>" >&2; return 2; }
          local safe
          safe=$(_pi_esc "$needle")

          echo "── domainlist matches (%$needle%) ──"
          _pi_sql -header -column \
            "SELECT id,
               CASE type WHEN 0 THEN 'allow' WHEN 1 THEN 'deny'
                         WHEN 2 THEN 'r-allow' WHEN 3 THEN 'r-deny' END AS type,
               enabled, domain, comment
             FROM domainlist
             WHERE domain LIKE '%$safe%'
             ORDER BY type, domain;"

          local gcount
          gcount=$(_pi_sql "SELECT COUNT(*) FROM gravity WHERE domain LIKE '%$safe%';") || gcount=0
          echo ""
          echo "── gravity (blocklists) ──"
          echo "$gcount hit(s) in gravity table"
          if [[ "$gcount" -gt 0 && "$gcount" -le 20 ]]; then
              _pi_sql -header -column \
                "SELECT g.domain, a.address AS source
                 FROM gravity g LEFT JOIN adlist a ON g.adlist_id = a.id
                 WHERE g.domain LIKE '%$safe%'
                 LIMIT 20;"
          elif [[ "$gcount" -gt 20 ]]; then
              echo "(more than 20 — narrow the search or use: pi raw \"SELECT ...\")"
          fi

          # v2.1: IP/MAC needle -> device info from FTL's network tables.
          if [[ "$needle" =~ ^[0-9]+\.[0-9.]+$ || "$needle" =~ ^([0-9a-fA-F]{2}:){2,} ]]; then
              echo ""
              echo "── device / network (FTL) ──"
              if [[ ! -e "$FTLDB" ]]; then
                  echo "(no $FTLDB — set PIHOLE_FTL_DB)"
              else
                  _pi_ftl -header -column "
                    SELECT na.ip,
                           na.name                                AS hostname,
                           n.hwaddr                               AS mac,
                           n.interface                            AS iface,
                           datetime(na.lastSeen,'unixepoch','localtime') AS last_seen,
                           datetime(na.firstSeen,'unixepoch','localtime') AS first_seen
                      FROM network_addresses na
                      JOIN network n ON n.id = na.network_id
                     WHERE na.ip LIKE '%$safe%'
                        OR n.hwaddr LIKE '%$safe%'
                        OR na.name LIKE '%$safe%'
                     ORDER BY na.lastSeen DESC;"
                  # Same MAC seen on several IPs? show everything for that device.
                  local other_ips
                  other_ips=$(_pi_ftl "
                    SELECT group_concat(na2.ip)
                      FROM network_addresses na2
                     WHERE na2.network_id IN (
                           SELECT na.network_id FROM network_addresses na
                            JOIN network n ON n.id = na.network_id
                           WHERE na.ip LIKE '%$safe%' OR n.hwaddr LIKE '%$safe%')
                       AND na2.ip NOT LIKE '%$safe%';") || other_ips=""
                  [[ -n "$other_ips" ]] && echo "same device, other ip(s): $other_ips"
                  echo ""
                  echo "── last 24h for this client ──"
                  _pi_ftl -column "
                    SELECT COUNT(*) || ' queries, ' ||
                           SUM(CASE WHEN status IN ($PI_STATUS_BLOCKED) THEN 1 ELSE 0 END) || ' blocked, top: ' ||
                           COALESCE((SELECT domain FROM queries q2
                                      WHERE q2.client LIKE '%$safe%'
                                        AND q2.timestamp >= strftime('%s','now','-1 day')
                                      GROUP BY q2.domain ORDER BY COUNT(*) DESC LIMIT 1), '—')
                      FROM queries
                     WHERE client LIKE '%$safe%'
                       AND timestamp >= strftime('%s','now','-1 day');"
              fi
          fi
      }

      # v2.1 smart resolution for rm/toggle: exact match first; if nothing,
      # fall back to a host-boundary match (domain = needle or *.needle).
      # Proceeds only when exactly ONE distinct domain matches; otherwise
      # lists candidates and returns 1. Sets the globals: where, hits.
      _pi_smart_where() {
          local target="$1" tfilter="$2"
          local safe
          safe=$(_pi_esc "$target")
          local tclause=""
          if [[ "$tfilter" != "any" ]]; then
              local code
              code=$(_pi_type_code "$tfilter")
              [[ -z "$code" ]] && { echo "unknown type: $tfilter" >&2; return 2; }
              tclause=" AND type=$code"
          fi
          where="domain='$safe'$tclause"
          hits=$(_pi_sql "SELECT COUNT(*) FROM domainlist WHERE $where;") || hits=0
          [[ "$hits" -gt 0 ]] && return 0

          # host-boundary fallback: govee.com should find app.govee.com,
          # but not notgovee.com
          local cands
          cands=$(_pi_sql "SELECT DISTINCT domain FROM domainlist
                           WHERE domain LIKE '%.' || '$safe'$tclause
                           ORDER BY domain;") || cands=""
          [[ -z "$cands" ]] && return 0   # still nothing; caller prints "no matches"
          local n
          n=$(grep -c . <<<"$cands")
          if [[ "$n" -eq 1 ]]; then
              local only="$cands"
              echo "≈ no exact '$target' — using the one host-boundary match: $only" >&2
              safe=$(_pi_esc "$only")
              where="domain='$safe'$tclause"
              hits=$(_pi_sql "SELECT COUNT(*) FROM domainlist WHERE $where;") || hits=0
              return 0
          fi
          echo "✗ no exact '$target', and the subdomain match is ambiguous:" >&2
          grep . <<<"$cands" | sed 's/^/    /' >&2
          echo "  re-run with the full domain (or: pi rm/toggle <domain> any)" >&2
          return 1
      }

      _pi_list() {
          local filter="''${1:-}" where=""
          if [[ -n "$filter" && "$filter" != "any" ]]; then
              local code
              code=$(_pi_type_code "$filter")
              [[ -z "$code" ]] && { echo "unknown type: $filter (allow|deny|ra|rd|any)" >&2; return 2; }
              where="WHERE type=$code"
          fi
          _pi_sql -header -column \
            "SELECT id,
               CASE type WHEN 0 THEN 'allow' WHEN 1 THEN 'deny'
                         WHEN 2 THEN 'r-allow' WHEN 3 THEN 'r-deny' END AS type,
               enabled, domain, comment
             FROM domainlist $where
             ORDER BY type, domain;"
      }

      _pi_rm() {
          local target="''${1:-}" tfilter="''${2:-any}"
          [[ -z "$target" ]] && { echo "usage: pi rm <domain> [allow|deny|ra|rd|any]" >&2; return 2; }
          local where hits
          _pi_smart_where "$target" "$tfilter" || return $?
          if [[ "$hits" -eq 0 ]]; then
              local detail=""
              [[ "$tfilter" != "any" ]] && detail=" (type=$tfilter)"
              echo "no matches for '$target'$detail"
              return 0
          fi
          _pi_sql -column \
            "SELECT id,
               CASE type WHEN 0 THEN 'allow' WHEN 1 THEN 'deny'
                         WHEN 2 THEN 'r-allow' WHEN 3 THEN 'r-deny' END,
               domain, comment
             FROM domainlist WHERE $where;"
          printf "delete %s row(s)? [y/N] " "$hits"
          local ans; read -r ans
          case "$ans" in
              y|Y|yes|YES)
                  _pi_sqlw "BEGIN;
                    DELETE FROM domainlist_by_group
                      WHERE domainlist_id IN (SELECT id FROM domainlist WHERE $where);
                    DELETE FROM domainlist WHERE $where;
                    COMMIT;"
                  echo "− removed $hits row(s)"
                  _pi_reload_or_warn
                  ;;
              *) echo "aborted" ;;
          esac
      }

      _pi_toggle() {
          local target="''${1:-}" tfilter="''${2:-any}"
          [[ -z "$target" ]] && { echo "usage: pi toggle <domain> [allow|deny|ra|rd|any]" >&2; return 2; }
          local where hits
          _pi_smart_where "$target" "$tfilter" || return $?
          [[ "$hits" -eq 0 ]] && { echo "no matches for '$target'"; return 0; }
          _pi_sqlw "UPDATE domainlist
                    SET enabled = CASE enabled WHEN 1 THEN 0 ELSE 1 END,
                        date_modified = strftime('%s','now')
                    WHERE $where;"
          echo "⇄ toggled $hits row(s)"
          _pi_sql -column \
            "SELECT id, enabled,
               CASE type WHEN 0 THEN 'allow' WHEN 1 THEN 'deny'
                         WHEN 2 THEN 'r-allow' WHEN 3 THEN 'r-deny' END,
               domain FROM domainlist WHERE $where;"
          _pi_reload_or_warn

          # v2: anything we just flipped OFF comes back on after a while.
          # Detached sleeper: survives this process exiting, but NOT a reboot —
          # a bounced box leaves the entry off until you toggle it back.
          local mins="''${PI_TOGGLE_REENABLE_MIN:-20}"
          if [[ "$mins" =~ ^[0-9]+$ && "$mins" -gt 0 ]]; then
              local nowoff
              nowoff=$(_pi_sql "SELECT group_concat(id) FROM domainlist
                                WHERE $where AND enabled=0;") || nowoff=""
              if [[ -n "$nowoff" ]]; then
                  echo "⏱  auto re-enable in ''${mins}m (PI_TOGGLE_REENABLE_MIN=0 to opt out)"
                  ( sleep "$((mins * 60))"
                    _pi_sqlw "UPDATE domainlist
                              SET enabled=1, date_modified=strftime('%s','now')
                              WHERE id IN ($nowoff) AND enabled=0;"
                    _pi_reload
                  ) >/dev/null 2>&1 &
                  disown
              fi
          fi
      }

      _pi_status() {
          # v2: dashboard-style summary first, then the DB detail.
          if _pi_pihole status >/dev/null 2>&1; then
              echo "up: y"
          else
              echo "up: n  (container '$PI_CONTAINER' unreachable)"
          fi

          if [[ -e "$FTLDB" ]]; then
              local granted blocked
              granted=$(_pi_ftl "SELECT COUNT(*) FROM queries
                                 WHERE timestamp >= strftime('%s','now','-1 day')
                                   AND status IN ($PI_STATUS_GRANTED);" 2>/dev/null) || granted=""
              blocked=$(_pi_ftl "SELECT COUNT(*) FROM queries
                                 WHERE timestamp >= strftime('%s','now','-1 day')
                                   AND status IN ($PI_STATUS_BLOCKED);" 2>/dev/null) || blocked=""
              if [[ "$granted" =~ ^[0-9]+$ && "$blocked" =~ ^[0-9]+$ ]]; then
                  echo "last 24h: requests_granted=$granted requests_blocked=$blocked"
                  if [[ $((granted + blocked)) -gt 0 ]]; then
                      awk -v b="$blocked" -v t="$((granted + blocked))" \
                          'BEGIN { printf "block_rate=%.1f%%\n", b * 100 / t }'
                  fi
              fi
              local integ
              integ=$(_pi_ftl "PRAGMA integrity_check;" 2>/dev/null) || integ=""
              if [[ "$integ" == "ok" ]]; then
                  echo "FTL db: ok"
              else
                  echo "FTL db: DB CORRUPTED!! run 'fix-pi' on tower or dacrib to resolve"
              fi
              echo ""
          fi

          _pi_pihole status 2>/dev/null || true
          echo ""
          echo "── domainlist counts ──"
          _pi_sql -header -column \
            "SELECT CASE type WHEN 0 THEN 'exact-allow' WHEN 1 THEN 'exact-deny'
                              WHEN 2 THEN 'regex-allow' WHEN 3 THEN 'regex-deny' END AS list,
                    COUNT(*) AS total,
                    SUM(CASE WHEN enabled=1 THEN 1 ELSE 0 END) AS enabled
             FROM domainlist GROUP BY type ORDER BY type;"
          echo ""
          local orphans
          orphans=$(_pi_sql "SELECT COUNT(*) FROM domainlist d
                             LEFT JOIN domainlist_by_group g ON d.id=g.domainlist_id
                             WHERE g.domainlist_id IS NULL;") || orphans=0
          if [[ "$orphans" -gt 0 ]]; then
              echo "⚠  $orphans orphaned row(s) — visible in DB, ignored by resolver"
              echo "   fix with: pi orphans --fix"
          fi
          local dangling
          dangling=$(_pi_sql "SELECT COUNT(*) FROM domainlist_by_group g
                              LEFT JOIN domainlist d ON d.id=g.domainlist_id
                              WHERE d.id IS NULL;") || dangling=0
          if [[ "$dangling" -gt 0 ]]; then
              echo "⚠  $dangling dangling group link(s) — leftovers of deleted entries"
              echo "   fix with: pi orphans --fix"
          fi
          if [[ "$orphans" -eq 0 && "$dangling" -eq 0 ]]; then
              echo "✓  no orphaned rows or dangling links"
          fi
          if [[ -e "$PI_DB" ]]; then
              local hcount
              hcount=$(_pi_pidb "SELECT COUNT(*) FROM hidden;" 2>/dev/null) || hcount=0
              [[ "$hcount" -gt 0 ]] && echo "🕶  $hcount hidden query-log rule(s) — pi hidden | pi querylog -q"
          fi
          echo ""
          echo "── gravity ──"
          _pi_sql "SELECT COUNT(*) || ' blocked domains, ' ||
                          (SELECT COUNT(*) FROM adlist WHERE enabled=1) || ' active adlists'
                   FROM gravity;"
      }

      # Two directions of broken linkage:
      #   orphans  — domainlist rows with no group link (ignored by resolver)
      #   dangling — by_group rows pointing at deleted domainlist ids; harmless
      #              to FTL, but they collide when sqlite reuses the rowid.
      _pi_orphans() {
          local fix="''${1:-}"
          local orphans dangling
          orphans=$(_pi_sql "SELECT COUNT(*) FROM domainlist d
                             LEFT JOIN domainlist_by_group g ON d.id=g.domainlist_id
                             WHERE g.domainlist_id IS NULL;") || orphans=0
          dangling=$(_pi_sql "SELECT COUNT(*) FROM domainlist_by_group g
                              LEFT JOIN domainlist d ON d.id=g.domainlist_id
                              WHERE d.id IS NULL;") || dangling=0
          if [[ "$orphans" -eq 0 && "$dangling" -eq 0 ]]; then
              echo "✓ no orphans, no dangling links"
              return 0
          fi
          if [[ "$orphans" -gt 0 ]]; then
              echo "── $orphans orphaned row(s) (visible in DB, ignored by resolver) ──"
              _pi_sql -header -column \
                "SELECT d.id,
                   CASE d.type WHEN 0 THEN 'allow' WHEN 1 THEN 'deny'
                               WHEN 2 THEN 'r-allow' WHEN 3 THEN 'r-deny' END AS type,
                   d.enabled, d.domain
                 FROM domainlist d
                 LEFT JOIN domainlist_by_group g ON d.id=g.domainlist_id
                 WHERE g.domainlist_id IS NULL;"
              if [[ "$fix" == "--fix" ]]; then
                  _pi_sqlw "INSERT OR IGNORE INTO domainlist_by_group (domainlist_id, group_id)
                            SELECT d.id, 0 FROM domainlist d
                            LEFT JOIN domainlist_by_group g ON d.id=g.domainlist_id
                            WHERE g.domainlist_id IS NULL;"
                  echo "+ linked $orphans row(s) to group 0 (Default)"
                  _pi_reload_or_warn
              else
                  echo "run: pi orphans --fix   to link them to group 0"
              fi
          fi
          if [[ "$dangling" -gt 0 ]]; then
              echo "── $dangling dangling group link(s) (leftovers of deleted entries) ──"
              _pi_sql -header -column \
                "SELECT g.domainlist_id, g.group_id
                 FROM domainlist_by_group g
                 LEFT JOIN domainlist d ON d.id=g.domainlist_id
                 WHERE d.id IS NULL LIMIT 20;"
              if [[ "$fix" == "--fix" ]]; then
                  _pi_sqlw "DELETE FROM domainlist_by_group
                            WHERE domainlist_id IN (
                              SELECT g.domainlist_id FROM domainlist_by_group g
                              LEFT JOIN domainlist d ON d.id=g.domainlist_id
                              WHERE d.id IS NULL);"
                  echo "− removed $dangling dangling link(s)"
              else
                  echo "run: pi orphans --fix   to delete them"
              fi
          fi
      }

      # ── query-log visibility (sidecar db: survives `pihole -g` swaps) ──

      _pi_hide_usage() {
          echo "usage: pi $1 <device|ip|mac|domain|type> <value>" >&2
      }

      _pi_hidden_init() {
          _pi_pidb "CREATE TABLE IF NOT EXISTS hidden(
                      id INTEGER PRIMARY KEY,
                      kind TEXT NOT NULL CHECK(kind IN ('device','ip','mac','domain','type')),
                      value TEXT NOT NULL,
                      date_added INTEGER NOT NULL,
                      comment TEXT,
                      UNIQUE(kind, value));"
      }

      _pi_hide() {
          local kind="''${1:-}" value="''${2:-}"
          case "$kind" in
              device|ip|mac|domain|type) ;;
              *) _pi_hide_usage hide; return 2 ;;
          esac
          [[ -z "$value" ]] && { _pi_hide_usage hide; return 2; }
          local norm
          if [[ "$kind" == "type" ]]; then
              norm=$(_pi_qtype_code "$value")
              [[ -z "$norm" ]] && { echo "unknown query type: $value (A AAAA PTR TXT HTTPS SVCB ... or TYPE<n>)" >&2; return 2; }
          else
              norm=$(_pi_norm "$kind" "$value")
          fi
          if ! _pi_hidden_init; then
              echo "✗ cannot open sidecar db $PI_DB" >&2
              return 1
          fi
          local safe newid
          safe=$(_pi_esc "$norm")
          if ! newid=$(_pi_pidb "INSERT OR IGNORE INTO hidden (kind, value, date_added, comment)
                                 VALUES ('$kind', '$safe', strftime('%s','now'), 'via pi')
                                 RETURNING id;"); then
              echo "✗ failed to write $PI_DB" >&2
              return 1
          fi
          if [[ -z "$newid" ]]; then
              echo "= already hidden [$kind] $norm"
              return 0
          fi
          echo "+ hidden (id=$newid) [$kind] $norm — undo: pi show $kind $value | peek: pi querylog -q"
      }

      _pi_unhide() {
          local kind="''${1:-}" value="''${2:-}"
          case "$kind" in
              device|ip|mac|domain|type) ;;
              *) _pi_hide_usage show; return 2 ;;
          esac
          [[ -z "$value" ]] && { _pi_hide_usage show; return 2; }
          local norm
          if [[ "$kind" == "type" ]]; then
              norm=$(_pi_qtype_code "$value")
              [[ -z "$norm" ]] && { echo "unknown query type: $value" >&2; return 2; }
          else
              norm=$(_pi_norm "$kind" "$value")
          fi
          if [[ ! -e "$PI_DB" ]]; then
              echo "no hidden rules ($PI_DB doesn't exist yet)"
              return 0
          fi
          local safe gone
          safe=$(_pi_esc "$norm")
          if ! gone=$(_pi_pidb "DELETE FROM hidden WHERE kind='$kind' AND value='$safe'
                                RETURNING id;"); then
              echo "✗ failed to write $PI_DB" >&2
              return 1
          fi
          if [[ -z "$gone" ]]; then
              echo "no hidden rule for [$kind] $norm"
              return 0
          fi
          echo "− un-hidden [$kind] $norm"
      }

      _pi_hidden_list() {
          if [[ ! -e "$PI_DB" ]]; then
              echo "(no hidden rules — $PI_DB doesn't exist yet)"
              return 0
          fi
          local has
          has=$(_pi_pidb "SELECT 1 FROM sqlite_master WHERE type='table' AND name='hidden';" 2>/dev/null) || has=""
          if [[ -z "$has" ]]; then
              echo "(no hidden rules)"
              return 0
          fi
          _pi_pidb -header -column \
            "SELECT id, kind, value,
                    datetime(date_added,'unixepoch','localtime') AS added, comment
             FROM hidden ORDER BY kind, value;"
      }

      # Reads the `queries` view (FTL v6 stores int ids in query_storage; the
      # view resolves them to text). Hidden rules are matched per row:
      #   domain → exact + subdomains, case-insensitive
      #   ip     → q.client equals
      #   mac    → q.client belongs to that hwaddr (network tables)
      #   device → q.client has that hostname (network_addresses.name)
      #   type   → FTL query-type id (A=1 AAAA=2 PTR=6 TXT=7 HTTPS=16 ...)
      # v2: optional trailing pattern filters domain/client server-side;
      # output is one-row-per-line either way, so grep pipelines still work.
      _pi_querylog() {
          local show_hidden=0 limit=25 pattern=""
          while [[ $# -gt 0 ]]; do
              case "$1" in
                  -q|--show-hidden) show_hidden=1 ;;
                  *)  if [[ "$1" =~ ^[0-9]+$ ]]; then limit="$1"; else pattern="$1"; fi ;;
              esac
              shift
          done
          [[ "$limit" =~ ^[0-9]+$ ]] \
              || { echo "usage: pi querylog [-q|--show-hidden] [N] [pattern]" >&2; return 2; }
          [[ ! -e "$FTLDB" ]] && { echo "✗ $FTLDB not found (set PIHOLE_FTL_DB)" >&2; return 1; }

          local pat_where=""
          if [[ -n "$pattern" ]]; then
              local patsafe
              patsafe=$(_pi_esc "$pattern")
              pat_where="AND (q.domain LIKE '%$patsafe%' OR q.client LIKE '%$patsafe%')"
          fi

          local hidexpr="0" attach=""
          if [[ -e "$PI_DB" ]]; then
              local has
              has=$(_pi_pidb "SELECT 1 FROM sqlite_master WHERE type='table' AND name='hidden';" 2>/dev/null) || has=""
              if [[ -n "$has" ]]; then
                  local psafe
                  psafe=$(_pi_esc "$PI_DB")
                  attach="ATTACH '$psafe' AS pi;"
                  hidexpr="EXISTS (SELECT 1 FROM pi.hidden h WHERE
                      (h.kind='domain' AND (q.domain = h.value OR q.domain LIKE '%.' || h.value))
                   OR (h.kind='ip'     AND q.client = h.value)
                   OR (h.kind='type'   AND q.type = CAST(h.value AS INTEGER))
                   OR (h.kind='mac'    AND EXISTS (SELECT 1 FROM network_addresses na
                                                    JOIN network n ON n.id = na.network_id
                                                    WHERE na.ip = q.client
                                                      AND lower(n.hwaddr) = lower(h.value)))
                   OR (h.kind='device' AND EXISTS (SELECT 1 FROM network_addresses na
                                                    WHERE na.ip = q.client
                                                      AND lower(na.name) = lower(h.value))))"
              fi
          fi

          local sel_flag="" where_hid="AND NOT ($hidexpr)"
          if [[ "$show_hidden" -eq 1 ]]; then
              sel_flag="CASE WHEN $hidexpr THEN 'hidden' ELSE NULL END AS flag,"
              where_hid=""
          fi

          _pi_ftl -header -column "
            $attach
            SELECT datetime(q.timestamp,'unixepoch','localtime') AS time,
                   $sel_flag
                   CASE q.type WHEN 1 THEN 'A' WHEN 2 THEN 'AAAA' WHEN 3 THEN 'ANY'
                       WHEN 4 THEN 'SRV' WHEN 5 THEN 'SOA' WHEN 6 THEN 'PTR'
                       WHEN 7 THEN 'TXT' WHEN 8 THEN 'NAPTR' WHEN 9 THEN 'MX'
                       WHEN 10 THEN 'DS' WHEN 11 THEN 'RRSIG' WHEN 12 THEN 'DNSKEY'
                       WHEN 13 THEN 'NS' WHEN 14 THEN 'OTHER' WHEN 15 THEN 'SVCB'
                       WHEN 16 THEN 'HTTPS'
                       ELSE CASE WHEN q.type > 100 THEN 'TYPE' || (q.type - 100)
                                 ELSE 't' || q.type END
                   END AS qtype,
                   CASE q.status WHEN 1 THEN 'blocked(grav)' WHEN 2 THEN 'forwarded'
                       WHEN 3 THEN 'cached' WHEN 4 THEN 'blocked(regex)'
                       WHEN 5 THEN 'blocked(deny)' WHEN 6 THEN 'blocked(ext-ip)'
                       WHEN 7 THEN 'blocked(ext-null)' WHEN 8 THEN 'blocked(ext-nx)'
                       WHEN 9 THEN 'blocked(grav-c)' WHEN 10 THEN 'blocked(regex-c)'
                       WHEN 11 THEN 'blocked(deny-c)' WHEN 12 THEN 'retried'
                       WHEN 13 THEN 'retried(dnssec)' WHEN 14 THEN 'already-fwd'
                       WHEN 15 THEN 'blocked(busy)' WHEN 16 THEN 'blocked(special)'
                       WHEN 17 THEN 'cached(stale)' WHEN 18 THEN 'blocked(ede15)'
                       ELSE 'status-' || q.status
                   END AS status,
                   q.domain,
                   q.client
              FROM queries q
             WHERE q.timestamp >= strftime('%s','now','-1 day')
             $pat_where
             $where_hid
             ORDER BY q.timestamp DESC
             LIMIT $limit;"
          if [[ "$show_hidden" -eq 0 && "$hidexpr" != "0" ]]; then
              echo "(hidden rules filtered out — pi querylog -q to include)"
          fi
      }

      case "''${1:-}" in
          ""|-h|--help|help)                              _pi_help ;;
          -V|--version)                                   echo "pi $PI_VERSION" ;;

          allow|exact-allow|--exact-allow)                shift; _pi_add 0 "$@" ;;
          deny|block|exact-deny|--exact-deny)             shift; _pi_add 1 "$@" ;;
          ra|r-allow|allow-regex|regex-allow|--allow-regex) shift; _pi_add 2 "$@" ;;
          rd|r-deny|deny-regex|regex-deny|--deny-regex)     shift; _pi_add 3 "$@" ;;

          disable|pause|-d|-p)                            _pi_disable "''${2:-}" ;;
          enable)                                         _pi_pihole enable ;;

          find|-f|--find|search)                          _pi_find "''${2:-}" ;;
          list|ls)                                        _pi_list "''${2:-}" ;;
          groups)                                         _pi_sql -header -column \
                                                            "SELECT id, enabled, name, description
                                                             FROM 'group' ORDER BY id;" ;;
          adlists)                                        _pi_sql -header -column \
                                                            "SELECT id, enabled, address, comment
                                                             FROM adlist ORDER BY id;" ;;
          offenders|top|hammerers)                        _pi_offenders ;;
          rm|remove|-k|-r|--rm|--remove|rm-entry)         _pi_rm "''${2:-}" "''${3:-any}" ;;
          toggle)                                         _pi_toggle "''${2:-}" "''${3:-any}" ;;

          hide)                                           _pi_hide "''${2:-}" "''${3:-}" ;;
          show|unhide)                                    _pi_unhide "''${2:-}" "''${3:-}" ;;
          hidden)                                         _pi_hidden_list ;;
          querylog|qlog|log)                              shift; _pi_querylog "$@" ;;

          status)                                         _pi_status ;;
          orphans)                                        _pi_orphans "''${2:-}" ;;
          schema)                                         _pi_sql ".schema" ;;
          tables)                                         _pi_sql ".tables" ;;

          reload)                                         _pi_pihole reloadlists \
                                                              || _pi_pihole reloaddns \
                                                              || { echo "✗ reload failed — is the '$PI_CONTAINER' container running? (sudo podman ps)" >&2; exit 1; } ;;
          rebuild|gravity|-g)                             _pi_pihole -g ;;
          raw)                                            shift; _pi_sql "$*" ;;

          *) echo "pi: unknown subcommand '$1' (try: pi --help)" >&2; exit 2 ;;
      esac
'';
  };

  piCompletion = pkgs.writeTextFile {
    name = "pi-zsh-completion";
    destination = "/share/zsh/site-functions/_pi";
    text = ''
      #compdef pi

      _pi() {
          local -a subcommands
          subcommands=(
              'allow:add exact-allow entries (multiple ok)'
              'deny:add exact-deny entries (multiple ok)'
              'allow-regex:add regex-allow entry'
              'deny-regex:add regex-deny entry'
              'ra:add regex-allow entry'
              'rd:add regex-deny entry'
              'r-allow:add regex-allow entry'
              'r-deny:add regex-deny entry'
              'disable:disable blocking [seconds, default 15]'
              'pause:alias for disable'
              'enable:re-enable blocking'
              'find:search domainlist + gravity (+device info for IP/MAC)'
              'list:dump entries (optionally by type)'
              'groups:list groups'
              'adlists:list gravity sources'
              'offenders:top 10 clients by query volume (24h)'
              'rm:remove entry (prompts)'
              'toggle:flip enabled 0/1 (auto re-enables in 20m)'
              'hide:hide device/ip/mac/domain/type from pi querylog'
              'show:un-hide a query-log rule'
              'unhide:un-hide a query-log rule'
              'hidden:list hidden query-log rules'
              'querylog:query log viewer (-q includes hidden, [N] [pattern])'
              'qlog:alias for querylog'
              'status:up? + 24h granted/blocked/block_rate + FTL integrity'
              'orphans:show/repair unlinked rows'
              'schema:dump gravity.db schema'
              'tables:list tables'
              'reload:reload lists (no full rebuild)'
              'rebuild:pihole -g (full rebuild)'
              'raw:arbitrary SQL'
              'help:show help'
          )

          local -a type_filters
          type_filters=(
              'allow:exact-allow rows'
              'deny:exact-deny rows'
              'ra:regex-allow rows'
              'rd:regex-deny rows'
              'r-allow:regex-allow rows'
              'r-deny:regex-deny rows'
              'any:all types'
          )

          local -a hide_kinds
          hide_kinds=(
              'device:hide by client hostname'
              'ip:hide by client IP'
              'mac:hide by hardware address'
              'domain:hide by domain (+subdomains)'
              'type:hide by query type (A AAAA PTR TXT HTTPS ...)'
          )

          if (( CURRENT == 2 )); then
              _describe -t commands 'pi subcommand' subcommands
          elif (( CURRENT == 3 )); then
              case "$words[2]" in
                  list)             _describe -t types 'list filter' type_filters ;;
                  rm|remove|toggle) _message 'domain' ;;
                  orphans)          compadd -- --fix ;;
                  find|search)      _message 'domain or substring' ;;
                  hide|show|unhide) _describe -t kinds 'hide kind' hide_kinds ;;
                  querylog|qlog)    compadd -- -q --show-hidden ;;
                  disable|pause)    _message 'seconds (0 = until re-enabled)' ;;
              esac
          elif (( CURRENT == 4 )); then
              case "$words[2]" in
                  rm|remove|toggle) _describe -t types 'type filter' type_filters ;;
                  hide|show|unhide) _message 'value' ;;
              esac
          fi
      }

      _pi "$@"
    '';
  };
in
{
  options.programs.pi-cli = {
    enable = lib.mkEnableOption "Pi-hole direct-SQL maintenance CLI";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      piEngine
      piCompletion
      pkgs.sqlite
    ];
  };
}
