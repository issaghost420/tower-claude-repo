{ pkgs, ... }:

let
  # ── Format Detection (JSON inputs) ──
  detectJq = pkgs.writeText "cc-detect.jq" ''
    if type == "array" then
      if (.[0] // {} | has("role")) then "openai-array" else "unknown" end
    elif (.messages and (.messages | type == "array")) then
      if ((.messages[0] // {}) | has("roleLabel")) then "workpent"
      elif ((.messages[0] // {}) | has("versions")) then "lmstudio"
      elif has("history") then "openwebui"
      elif ((.messages[0] // {}) | has("role") and has("text")) then "canonical"
      elif ((.messages[0] // {}) | has("role") and has("content")) then "openai"
      else "unknown"
      end
    elif has("chat") then "openwebui-wrapped"
    else "unknown"
    end
  '';

  # ── Normalizers → { title, createdAt, messages: [{role, text}] } ──
  # createdAt is unix SECONDS, pulled from source when present, else "now".

  normalizeWorkpentJq = pkgs.writeText "cc-norm-workpent.jq" ''
    {
      title: (.title // "Imported conversation"),
      createdAt: (
        (.exportedAt // .createdAt // null) |
        if . == null then (now | floor)
        elif type == "number" then (. | floor)
        else (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch (now | floor))
        end
      ),
      messages: [ .messages[] | select(.role == "user" or .role == "assistant") | { role, text } ]
    }
  '';

  normalizeLmstudioJq = pkgs.writeText "cc-norm-lmstudio.jq" ''
    {
      title: (.name // "Imported conversation"),
      createdAt: ((.createdAt // null) | if . == null then (now | floor) elif . > 9999999999 then (. / 1000 | floor) else (. | floor) end),
      messages: [
        .messages[] |
        (.versions // []) as $vers |
        select($vers | length > 0) |
        $vers[.currentlySelected // 0] as $v |
        select($v != null) |
        select($v.role == "user" or $v.role == "assistant") |
        {
          role: $v.role,
          text: (
            if $v.type == "singleStep" then
              ([($v.content // [])[] | select(.type == "text") | .text] | join("\n"))
            elif $v.type == "multiStep" then
              ([($v.steps // [])[] | (.content // [])[] | select(.type == "text") | .text] | join("\n"))
            else
              (if ($v.content // null) != null then
                if ($v.content | type) == "string" then $v.content
                elif ($v.content | type) == "array" then
                  ([($v.content // [])[] | select(.type == "text") | .text] | join("\n"))
                else ""
                end
              else "" end)
            end
          )
        } | select(.text != "")
      ]
    }
  '';

  normalizeOwuiJq = pkgs.writeText "cc-norm-owui.jq" ''
    {
      title: (.title // "Imported conversation"),
      createdAt: ((.timestamp // .created_at // null) | if . == null then (now | floor) elif . > 9999999999 then (. / 1000 | floor) else (. | floor) end),
      messages: [
        .messages[] |
        select(.role == "user" or .role == "assistant") |
        { role, text: .content }
      ]
    }
  '';

  normalizeOwuiWrappedJq = pkgs.writeText "cc-norm-owui-wrapped.jq" ''
    .chat | {
      title: (.title // "Imported conversation"),
      createdAt: ((.timestamp // .created_at // null) | if . == null then (now | floor) elif . > 9999999999 then (. / 1000 | floor) else (. | floor) end),
      messages: [
        .messages[] |
        select(.role == "user" or .role == "assistant") |
        { role, text: .content }
      ]
    }
  '';

  normalizeOpenaiJq = pkgs.writeText "cc-norm-openai.jq" ''
    {
      title: (.title // "Imported conversation"),
      createdAt: ((.createdAt // .created_at // null) | if . == null then (now | floor) elif . > 9999999999 then (. / 1000 | floor) else (. | floor) end),
      messages: [
        .messages[] |
        select(.role == "user" or .role == "assistant") |
        { role, text: (if (.content | type) == "array" then ([.content[] | select(.type=="text") | .text] | join("\n")) else .content end) }
      ]
    }
  '';

  normalizeOpenaiArrayJq = pkgs.writeText "cc-norm-openai-array.jq" ''
    {
      title: "Imported conversation",
      createdAt: (now | floor),
      messages: [
        .[] |
        select(.role == "user" or .role == "assistant") |
        { role, text: (if (.content | type) == "array" then ([.content[] | select(.type=="text") | .text] | join("\n")) else (.content // .text // "") end) }
      ]
    }
  '';

  normalizeCanonicalJq = pkgs.writeText "cc-norm-canonical.jq" ''
    {
      title: (.title // "Imported conversation"),
      createdAt: ((.createdAt // null) | if . == null then (now | floor) else (. | floor) end),
      messages: [ .messages[] | select(.role == "user" or .role == "assistant") | { role, text } ]
    }
  '';

  # ── Markdown Parser (exact-match rule) ──
  # Accepts:  ## User  |  **User**  |  "User"  |  User  |  User: text  |  H:/A: (case-sensitive)
  # Rejects:  prose lines that merely START with "user"/"assistant"
  mdParserAwk = pkgs.writeText "cc-md-parser.awk" ''
    BEGIN { role=""; text=""; n=0; printf "[" }
    function escape(s,  out){out=s;gsub(/\\/,"\\\\",out);gsub(/"/,"\\\"",out);gsub(/\t/,"\\t",out);gsub(/\r/,"",out);gsub(/\n/,"\\n",out);return out}
    function flush(){if(role=="")return;sub(/^[[:space:]]+/,"",text);sub(/[[:space:]]+$/,"",text);if(text=="")return;if(n>0)printf ",";printf "\n{\"role\":\"%s\",\"text\":\"%s\"}",role,escape(text);n++}
    function classify(raw,   d,low,rest){
      d=raw
      sub(/^[[:space:]]+/,"",d); sub(/[[:space:]]+$/,"",d)
      sub(/^#{1,6}[[:space:]]*/,"",d)
      gsub(/\*\*/,"",d); gsub(/__/,"",d)
      gsub(/^["'"'"'`]+/,"",d); gsub(/["'"'"'`]+$/,"",d)
      sub(/^[[:space:]]+/,"",d); sub(/[[:space:]]+$/,"",d)
      low=tolower(d)
      if(low=="user"||low=="human"||low=="you"||low=="me"||low=="edge"){LABEL_ROLE="user";LABEL_REST="";return 1}
      if(low=="assistant"||low=="claude"||low=="chatgpt"||low=="ai"||low=="gemini"||low=="grok"||low=="model"||low=="bot"){LABEL_ROLE="assistant";LABEL_REST="";return 1}
      if(low ~ /^(user|human|you|me|edge)[[:space:]]*:/){LABEL_ROLE="user";rest=d;sub(/^[^:]*:[[:space:]]*/,"",rest);LABEL_REST=rest;return 1}
      if(low ~ /^(assistant|claude|chatgpt|ai|gemini|grok|model|bot)[[:space:]]*:/){LABEL_ROLE="assistant";rest=d;sub(/^[^:]*:[[:space:]]*/,"",rest);LABEL_REST=rest;return 1}
      return 0
    }
    {
      raw=$0
      if(raw ~ /^H:[[:space:]]/){flush();role="user";rest=raw;sub(/^H:[[:space:]]*/,"",rest);text=rest;next}
      if(raw ~ /^A:[[:space:]]/){flush();role="assistant";rest=raw;sub(/^A:[[:space:]]*/,"",rest);text=rest;next}
      if(classify(raw)){flush();role=LABEL_ROLE;text=LABEL_REST;next}
      if(role!=""){text=text "\n" raw}
    }
    END{flush();printf "\n]"}
  '';

  # ── Output Formatters ──
  toLmstudioJq = pkgs.writeText "cc-to-lmstudio.jq" ''
    {
      name: .title,
      pinned: false,
      createdAt: ((.createdAt // (now | floor)) * 1000 | floor),
      preset: "",
      tokenCount: 10000,
      systemPrompt: "",
      messages: [
        .messages | to_entries[] |
        .key as $idx | .value as $m |
        if $m.role == "user" then
          { versions: [{ type: "singleStep", role: "user", content: [{ type: "text", text: $m.text }] }], currentlySelected: 0 }
        else
          {
            versions: [{
              type: "multiStep", role: "assistant",
              steps: [{
                type: "contentBlock",
                stepIdentifier: ("imported-" + ($idx | tostring) + "-" + (now | tostring)),
                content: [{ type: "text", text: $m.text, fromDraftModel: false, tokensCount: 0, isStructural: false }],
                defaultShouldIncludeInContext: true, shouldIncludeInContext: true,
                genInfo: { indexedModelIdentifier: "imported/ai-conversation", identifier: "imported-chat" }
              }],
              senderInfo: { senderName: "imported-ai" }
            }],
            currentlySelected: 0
          }
        end
      ],
      usePerChatPredictionConfig: false, perChatPredictionConfig: { fields: [] },
      clientInput: "", clientInputFiles: [], userFilesSizeBytes: 0,
      notes: [], plugins: [], pluginConfigs: {}, disabledPluginTools: [], looseFiles: []
    }
  '';

  toOwuiChatJq = pkgs.writeText "cc-to-owui-chat.jq" ''
    . as $canon |
    ($canon.createdAt // (now | floor)) as $ts |
    [ $canon.messages | to_entries[] |
      .key as $i | .value as $m |
      {
        id: $msg_ids[$i],
        parentId: (if $i == 0 then null else $msg_ids[$i - 1] end),
        childrenIds: (if $i == ($canon.messages | length - 1) then [] else [$msg_ids[$i + 1]] end),
        role: $m.role, content: $m.text, timestamp: $ts
      } +
      (if $m.role == "user" then { models: [$model] }
       else { model: $model, modelName: $model, modelIdx: 0, done: true } end)
    ] as $linear_msgs |
    {
      id: "", title: $canon.title, models: [$model], params: {},
      history: { messages: ($linear_msgs | map({ (.id): . }) | add // {}), currentId: ($linear_msgs | last | .id // null) },
      messages: $linear_msgs, tags: [], timestamp: ($ts * 1000), files: []
    }
  '';

  toOwuiSqlJq = pkgs.writeText "cc-to-owui-sql.jq" ''
    def sqlstr: "'" + (tostring | gsub("'"; "''''''")) + "'";
    def sqljson: tojson | sqlstr;
    . as $chat |
    "INSERT INTO chat (id, user_id, title, chat, created_at, updated_at, share_id, archived, pinned, meta, folder_id) VALUES (" +
      ($chat_id | sqlstr) + ", " + ($user_id | sqlstr) + ", " + ($chat.title | sqlstr) + ", " +
      ($chat | sqljson) + ", " + ($chat.timestamp / 1000 | floor | tostring) + ", " +
      ($chat.timestamp / 1000 | floor | tostring) + ", NULL, 0, 0, " +
      ({tags: [$import_tag]} | sqljson) + ", NULL);"
  '';

  toMdJq = pkgs.writeText "cc-to-md.jq" ''
    "# " + .title + "\n\n" +
    ([.messages[] | "## " + (if .role == "user" then "User" else "Assistant" end) + "\n\n" + .text + "\n"] | join("\n"))
  '';

  chat-convert = pkgs.writeShellApplication {
    name = "chat-convert";
    runtimeInputs = [ pkgs.jq pkgs.gawk pkgs.util-linux pkgs.coreutils ];
    text = ''
      usage() {
        cat >&2 <<'EOF'
chat-convert — universal chat conversation converter

USAGE
  chat-convert [options] <input-file-or-dir>

OPTIONS
  --to FORMAT     Output: lmstudio, openwebui, json, md   (default: json)
  --title TITLE   Override conversation title
  --user-id UUID  Open WebUI user ID (required for --to openwebui)
  --model NAME    Model name for Open WebUI imports (default: imported-chat)
  --output PATH   Output file or directory (default: stdout for json/md)
  -h, --help      Show this help

INPUT (auto-detected): markdown (## User / ## Assistant / User: / etc),
LM Studio, Open WebUI, OpenAI, canonical, workpent JSON.
EOF
        exit 1
      }
      TO_FORMAT="json"; TITLE=""; USER_ID=""; MODEL="imported-chat"; OUTPUT=""; INPUT=""; IMPORT_TAG="imported"
      while [ $# -gt 0 ]; do
        case "$1" in
          --to) TO_FORMAT="$2"; shift 2 ;;
          --title) TITLE="$2"; shift 2 ;;
          --user-id) USER_ID="$2"; shift 2 ;;
          --model) MODEL="$2"; shift 2 ;;
          --output|-o) OUTPUT="$2"; shift 2 ;;
          -h|--help) usage ;;
          -*) echo "unknown option: $1" >&2; usage ;;
          *) INPUT="$1"; shift ;;
        esac
      done
      [ -z "$INPUT" ] && { echo "error: no input file specified" >&2; usage; }
      if [ "$TO_FORMAT" = "openwebui" ] && [ -z "$USER_ID" ]; then
        echo "error: --user-id required for Open WebUI output" >&2; exit 1
      fi

      DETECT=${detectJq}
      NORM_WORKPENT=${normalizeWorkpentJq}; NORM_LMSTUDIO=${normalizeLmstudioJq}
      NORM_OWUI=${normalizeOwuiJq}; NORM_OWUI_WRAPPED=${normalizeOwuiWrappedJq}
      NORM_OPENAI=${normalizeOpenaiJq}; NORM_OPENAI_ARRAY=${normalizeOpenaiArrayJq}
      NORM_CANONICAL=${normalizeCanonicalJq}
      MD_PARSER=${mdParserAwk}
      TO_LMSTUDIO=${toLmstudioJq}; TO_OWUI_CHAT=${toOwuiChatJq}; TO_OWUI_SQL=${toOwuiSqlJq}; TO_MD=${toMdJq}

      normalize_json() {
        local in_file="$1" fmt
        fmt=$(jq -r -f "$DETECT" "$in_file")
        case "$fmt" in
          workpent)          jq -f "$NORM_WORKPENT" "$in_file" ;;
          lmstudio)          jq -f "$NORM_LMSTUDIO" "$in_file" ;;
          openwebui)         jq -f "$NORM_OWUI" "$in_file" ;;
          openwebui-wrapped) jq -f "$NORM_OWUI_WRAPPED" "$in_file" ;;
          openai)            jq -f "$NORM_OPENAI" "$in_file" ;;
          openai-array)      jq -f "$NORM_OPENAI_ARRAY" "$in_file" ;;
          canonical)         jq -f "$NORM_CANONICAL" "$in_file" ;;
          *) echo "skip: $in_file — unknown JSON shape ($fmt). Run it through scrollscrub Launder first." >&2; return 1 ;;
        esac
      }

      normalize_file() {
        local in_file="$1" override_title="$2" ext canonical
        ext="''${in_file##*.}"; ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
        case "$ext" in
          md|txt|text)
            local title msgs
            if [ -n "$override_title" ]; then title="$override_title"; else title=$(basename "$in_file" ".$ext"); fi
            msgs=$(gawk -f "$MD_PARSER" "$in_file")
            canonical=$(echo "$msgs" | jq --arg title "$title" '{title: $title, createdAt: (now|floor), messages: .}')
            ;;
          json)
            jq empty "$in_file" 2>/dev/null || { echo "skip: $in_file — invalid JSON" >&2; return 1; }
            canonical=$(normalize_json "$in_file") || return 1
            [ -n "$override_title" ] && canonical=$(echo "$canonical" | jq --arg t "$override_title" '.title = $t')
            ;;
          *)
            if head -20 "$in_file" | grep -qiE '^(#{1,6}[[:space:]]+)?(\*\*)?"?(User|Human|Assistant|Claude|You|ChatGPT|Me|Edge|AI|Gemini|Grok|Bot|Model)"?'; then
              local title msgs; title=$(basename "$in_file" ".$ext")
              msgs=$(gawk -f "$MD_PARSER" "$in_file")
              canonical=$(echo "$msgs" | jq --arg title "$title" '{title: $title, createdAt: (now|floor), messages: .}')
            elif jq empty "$in_file" 2>/dev/null; then
              canonical=$(normalize_json "$in_file") || return 1
            else
              echo "skip: $in_file — can't determine format. Try scrollscrub Launder." >&2; return 1
            fi
            ;;
        esac
        if [ -z "$canonical" ] || ! echo "$canonical" | jq empty 2>/dev/null; then
          echo "skip: $in_file — normalization failed" >&2; return 1
        fi
        local mc; mc=$(echo "$canonical" | jq '.messages | length' 2>/dev/null)
        if [ -z "$mc" ] || [ "$mc" -eq 0 ] 2>/dev/null; then
          echo "skip: $in_file — no user/assistant messages found (labels not recognized?)" >&2; return 1
        fi
        echo "$canonical"
      }

      emit_output() {
        local canonical="$1" out_file="$2"
        case "$TO_FORMAT" in
          json) if [ -n "$out_file" ]; then echo "$canonical" | jq '.' > "$out_file"; echo "wrote: $out_file" >&2; else echo "$canonical" | jq '.'; fi ;;
          md)   if [ -n "$out_file" ]; then echo "$canonical" | jq -r -f "$TO_MD" > "$out_file"; echo "wrote: $out_file" >&2; else echo "$canonical" | jq -r -f "$TO_MD"; fi ;;
          lmstudio)
            [ -z "$out_file" ] && { echo "error: --output required for lmstudio" >&2; return 1; }
            echo "$canonical" | jq -f "$TO_LMSTUDIO" > "$out_file"; echo "wrote: $out_file" >&2 ;;
          openwebui)
            local mc chat_id msg_ids_json chat_blob sql i
            mc=$(echo "$canonical" | jq '.messages | length')
            [ "$mc" -eq 0 ] 2>/dev/null && { echo "skip: empty" >&2; return 1; }
            chat_id=$(uuidgen); msg_ids_json="["; i=0
            while [ "$i" -lt "$mc" ]; do [ "$i" -gt 0 ] && msg_ids_json+=","; msg_ids_json+="\"$(uuidgen)\""; i=$((i+1)); done
            msg_ids_json+="]"
            chat_blob=$(echo "$canonical" | jq --arg model "$MODEL" --argjson msg_ids "$msg_ids_json" -f "$TO_OWUI_CHAT")
            sql=$(echo "$chat_blob" | jq -r --arg chat_id "$chat_id" --arg user_id "$USER_ID" --arg import_tag "$IMPORT_TAG" -f "$TO_OWUI_SQL")
            if [ -n "$out_file" ]; then
              { echo "-- chat-convert: $(echo "$canonical" | jq -r '.title')"; echo "$sql"; } >> "$out_file"
              echo "appended: $out_file (chat_id=$chat_id, $mc msgs)" >&2
            else echo "$sql"; fi ;;
          *) echo "error: unknown format '$TO_FORMAT'" >&2; return 1 ;;
        esac
      }

      if [ -d "$INPUT" ]; then
        if [ "$TO_FORMAT" = "openwebui" ] && [ -n "$OUTPUT" ]; then
          { echo "-- chat-convert batch import"; echo "-- Generated: $(date -Iseconds)"; echo "-- User: $USER_ID"; echo "BEGIN TRANSACTION;"; } > "$OUTPUT"
        fi
        count=0
        for f in "$INPUT"/*; do
          [ -f "$f" ] || continue
          canonical=$(normalize_file "$f" "$TITLE") || continue
          case "$TO_FORMAT" in
            lmstudio) out_dir="''${OUTPUT:-.}"; mkdir -p "$out_dir"; base="$(basename "$f" ".''${f##*.}").conversation.json"; emit_output "$canonical" "$out_dir/$base" || continue ;;
            openwebui) emit_output "$canonical" "''${OUTPUT:-}" || continue ;;
            *) if [ -n "$OUTPUT" ]; then mkdir -p "$OUTPUT"; base="$(basename "$f" ".''${f##*.}").$TO_FORMAT"; emit_output "$canonical" "$OUTPUT/$base" || continue; else emit_output "$canonical" "" || continue; fi ;;
          esac
          count=$((count+1))
        done
        if [ "$TO_FORMAT" = "openwebui" ] && [ -n "$OUTPUT" ]; then echo "COMMIT;" >> "$OUTPUT"; fi
        echo "converted $count file(s)" >&2
      else
        canonical=$(normalize_file "$INPUT" "$TITLE") || exit 1
        emit_output "$canonical" "$OUTPUT"
      fi
    '';
  };

  # ── Convenience wrapper: defaults baked in, prints exact apply commands ──
  owui-import = pkgs.writeShellApplication {
    name = "owui-import";
    runtimeInputs = [ chat-convert pkgs.coreutils ];
    text = ''
      USER_ID="7dddfe7a-5192-4104-87f6-4dd7e993e22c"
      DB_PATH="$HOME/archive-of-infinite-fold/tower-data-plain/openwebui/data/webui.db"

      if [ $# -lt 1 ]; then
        echo "usage: owui-import <input.md-or-json-or-dir> [output.sql]" >&2
        echo "       defaults output to /tmp/owui-import-<timestamp>.sql" >&2
        exit 1
      fi
      INPUT="$1"
      OUTPUT="''${2:-/tmp/owui-import-$(date +%s).sql}"

      chat-convert "$INPUT" --to openwebui --user-id "$USER_ID" --output "$OUTPUT"

      echo "" >&2
      echo "to apply:" >&2
      echo "  systemctl stop open-webui" >&2
      echo "  cp \"$DB_PATH\"{,.bak-\$(date +%s)}" >&2
      echo "  sqlite3 \"$DB_PATH\" < \"$OUTPUT\"" >&2
      echo "  systemctl start open-webui" >&2
    '';
  };

  lm-import = pkgs.writeShellApplication {
    name = "lm-import";
    runtimeInputs = [ chat-convert pkgs.coreutils ];
    text = ''
      if [ $# -lt 1 ]; then echo "usage: lm-import <input.md-or-json> [output.conversation.json]" >&2; exit 1; fi
      INPUT="$1"
      OUTPUT="''${2:-/tmp/lm-import-$(date +%s).conversation.json}"
      chat-convert "$INPUT" --to lmstudio --output "$OUTPUT"
      echo "" >&2
      echo "to apply:" >&2
      echo "  mv \"$OUTPUT\" ~/.local/share/LM\\ Studio/conversations/" >&2
    '';
  };
in
{
  environment.systemPackages = [ chat-convert owui-import lm-import ];
}
