{ pkgs, ... }:

let
  # Detect source format. Same pattern as the lmstudio tool.
  detectJq = pkgs.writeText "owui-detect.jq" ''
    if (.messages and (.messages | type == "array") and ((.messages[0] // {}) | has("roleLabel"))) then
      "workpent"
    else
      "unknown"
    end
  '';

  # Normalize workpent to canonical { title, createdAt, messages: [{role, text}] }
  # createdAt is unix seconds (Open WebUI uses seconds for created_at/updated_at, ms for inner timestamp)
  normalizeWorkpentJq = pkgs.writeText "owui-normalize-workpent.jq" ''
    {
      title: (.title // "Imported conversation"),
      createdAt: (
        (.exportedAt // null) |
        if . == null then (now | floor)
        else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)
        end
      ),
      messages: [ .messages[] | select(.role == "user" or .role == "assistant") | { role, text } ]
    }
  '';

  # Build Open WebUI chat blob from canonical form + pre-generated UUIDs.
  # Args: --arg chat_id UUID, --arg model STRING, --argjson msg_ids '["uuid1","uuid2",...]'
  # Input: canonical { title, createdAt, messages }
  # Output: the full `chat` JSON blob (what goes in the `chat` column)
  toOwuiChatJq = pkgs.writeText "owui-to-chat-blob.jq" ''
    . as $canon |
    # Zip messages with their pre-generated UUIDs and compute parent/child linkage
    [ $canon.messages | to_entries[] |
      .key as $i | .value as $m |
      {
        id: $msg_ids[$i],
        parentId: (if $i == 0 then null else $msg_ids[$i - 1] end),
        childrenIds: (if $i == ($canon.messages | length - 1) then [] else [$msg_ids[$i + 1]] end),
        role: $m.role,
        content: $m.text,
        timestamp: $canon.createdAt
      } +
      (if $m.role == "user" then
        { models: [$model] }
      else
        {
          model: $model,
          modelName: $model,
          modelIdx: 0,
          done: true
        }
      end)
    ] as $linear_msgs |
    {
      id: "",
      title: $canon.title,
      models: [$model],
      params: {},
      history: {
        messages: ($linear_msgs | map({ (.id): . }) | add // {}),
        currentId: ($linear_msgs | last | .id // null)
      },
      messages: $linear_msgs,
      tags: [],
      timestamp: ($canon.createdAt * 1000),
      files: []
    }
  '';

  # Emit a SQL INSERT for the chat row.
  # Input: the chat blob from toOwuiChatJq
  # Output: the SQL statement as a single text blob
  toSqlJq = pkgs.writeText "owui-to-sql.jq" ''
    # SQL string escape: double single-quotes, wrap in single-quotes
    def sqlstr: "'" + (tostring | gsub("'"; "'''")) + "'";
    def sqljson: tojson | sqlstr;

    . as $chat |
    "INSERT INTO chat (id, user_id, title, chat, created_at, updated_at, share_id, archived, pinned, meta, folder_id) VALUES (" +
      ($chat_id | sqlstr) + ", " +
      ($user_id | sqlstr) + ", " +
      ($chat.title | sqlstr) + ", " +
      ($chat | sqljson) + ", " +
      ($chat.timestamp / 1000 | floor | tostring) + ", " +
      ($chat.timestamp / 1000 | floor | tostring) + ", " +
      "NULL, 0, 0, " +
      ({tags: [$import_tag]} | sqljson) + ", " +
      "NULL" +
    ");"
  '';

  json-to-openwebui = pkgs.writeShellApplication {
    name = "json-to-openwebui";
    runtimeInputs = [ pkgs.jq pkgs.util-linux pkgs.coreutils ];
    text = ''
      if [ $# -lt 2 ] || [[ ! "$1" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        cat >&2 <<EOF
      usage: json-to-openwebui <user_id> <input.json> [output.sql]
             json-to-openwebui <user_id> <input-dir> <output.sql>

      Emits SQL INSERT statements for Open WebUI's chat table.
      Does NOT touch the database. Apply manually:

        systemctl stop open-webui
        cp /path/to/webui.db /path/to/webui.db.bak
        sqlite3 /path/to/webui.db < output.sql
        systemctl start open-webui

      EOF
        exit 1
      fi

      USER_ID="$1"
      INPUT="$2"
      OUTPUT="''${3:-./import.sql}"
      IMPORT_TAG="imported"
      MODEL="imported-chat"

      DETECT=${detectJq}
      NORM_WORKPENT=${normalizeWorkpentJq}
      TO_CHAT_BLOB=${toOwuiChatJq}
      TO_SQL=${toSqlJq}

      # Start fresh SQL file with a header
      {
        echo "-- Open WebUI chat import"
        echo "-- Generated: $(date -Iseconds)"
        echo "-- User: $USER_ID"
        echo "BEGIN TRANSACTION;"
      } > "$OUTPUT"

      convert_one() {
        local in_file="$1"

        if ! jq empty "$in_file" 2>/dev/null; then
          echo "skip: $in_file — not valid JSON" >&2
          return 1
        fi

        local fmt
        fmt=$(jq -r -f "$DETECT" "$in_file")

        local normalizer
        case "$fmt" in
          workpent) normalizer="$NORM_WORKPENT" ;;
          unknown)
            echo "skip: $in_file — unrecognized format" >&2
            return 1
            ;;
          *)
            echo "skip: $in_file — format '$fmt' has no handler" >&2
            return 1
            ;;
        esac

        # Count messages so we know how many UUIDs to generate
        local msg_count
        msg_count=$(jq -f "$normalizer" "$in_file" | jq '.messages | length')

        if [ "$msg_count" -eq 0 ]; then
          echo "skip: $in_file — no user/assistant messages" >&2
          return 1
        fi

        # Generate one UUID per message + one for the chat row itself
        local chat_id
        chat_id=$(uuidgen)
        local msg_ids_json="["
        local i=0
        while [ "$i" -lt "$msg_count" ]; do
          if [ "$i" -gt 0 ]; then msg_ids_json+=","; fi
          msg_ids_json+="\"$(uuidgen)\""
          i=$((i + 1))
        done
        msg_ids_json+="]"

        # Pipeline: raw → canonical → chat blob → SQL
        jq -f "$normalizer" "$in_file" | \
          jq --arg chat_id "$chat_id" \
             --arg model "$MODEL" \
             --argjson msg_ids "$msg_ids_json" \
             -f "$TO_CHAT_BLOB" | \
          jq -r --arg chat_id "$chat_id" \
                --arg user_id "$USER_ID" \
                --arg import_tag "$IMPORT_TAG" \
                -f "$TO_SQL" >> "$OUTPUT"

        echo "converted: $in_file ($msg_count messages, chat_id=$chat_id)" >&2
      }

      if [ -d "$INPUT" ]; then
        for f in "$INPUT"/*.json; do
          [ -e "$f" ] || continue
          convert_one "$f" || true
        done
      else
        convert_one "$INPUT"
      fi

      echo "COMMIT;" >> "$OUTPUT"
      echo "" >&2
      echo "wrote SQL to: $OUTPUT" >&2
      echo "" >&2
      echo "to apply:" >&2
      echo "  systemctl stop open-webui" >&2
      echo "  cp ~/archive-of-infinite-fold/tower-data-plain/openwebui/data/webui.db{,.bak-\$(date +%s)}" >&2
      echo "  sqlite3 ~/archive-of-infinite-fold/tower-data-plain/openwebui/data/webui.db < $OUTPUT" >&2
      echo "  systemctl start open-webui" >&2
    '';
  };

  owui-import = pkgs.writeShellApplication {
    name = "owui-import";
    runtimeInputs = [ json-to-openwebui pkgs.coreutils ];
    text = ''
      USER_ID="7dddfe7a-5192-4104-87f6-4dd7e993e22c"

      if [ $# -lt 1 ]; then
        echo "usage: owui-import <input.json-or-dir> [output.sql]" >&2
        echo "       defaults to /tmp/owui-import-<timestamp>.sql" >&2
        exit 1
      fi

      INPUT="$1"
      OUTPUT="''${2:-/tmp/owui-import-$(date +%s).sql}"

      json-to-openwebui "$USER_ID" "$INPUT" "$OUTPUT"
    '';
  };
in
{
  environment.systemPackages = [ json-to-openwebui owui-import ];
}
