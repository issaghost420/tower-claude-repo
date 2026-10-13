{ pkgs, ... }:

let
  # The jq program that detects which source format we're dealing with.
  detectJq = pkgs.writeText "detect.jq" ''
    if (.messages and (.messages | type == "array") and ((.messages[0] // {}) | has("roleLabel"))) then
      "workpent"
    else
      "unknown"
    end
  '';

  # Normalizer for the workpent/chatexport format.
  # Output contract: [ { role: "user"|"assistant", text: "..." }, ... ]
  normalizeWorkpentJq = pkgs.writeText "normalize-workpent.jq" ''
    {
      title: (.title // "Imported conversation"),
      messages: [ .messages[] | select(.role == "user" or .role == "assistant") | { role, text } ]
    }
  '';

  # Takes normalized { title, messages: [{role, text}] } and emits an LM Studio conversation file.
  toLmstudioJq = pkgs.writeText "to-lmstudio.jq" ''
    {
      name: .title,
      pinned: false,
      createdAt: (now * 1000 | floor),
      preset: "",
      tokenCount: 10000,
      systemPrompt: "",
      messages: [
        .messages | to_entries[] |
        .key as $idx | .value as $m |
        if $m.role == "user" then
          {
            versions: [{
              type: "singleStep",
              role: "user",
              content: [{ type: "text", text: $m.text }]
            }],
            currentlySelected: 0
          }
        else
          {
            versions: [{
              type: "multiStep",
              role: "assistant",
              steps: [{
                type: "contentBlock",
                stepIdentifier: ("imported-" + ($idx | tostring) + "-" + (now | tostring)),
                content: [{
                  type: "text",
                  text: $m.text,
                  fromDraftModel: false,
                  tokensCount: 0,
                  isStructural: false
                }],
                defaultShouldIncludeInContext: true,
                shouldIncludeInContext: true,
                genInfo: {
                  indexedModelIdentifier: "imported/ai-conversation",
                  identifier: "imported-chat"
                }
              }],
              senderInfo: { senderName: "imported-ai" }
            }],
            currentlySelected: 0
          }
        end
      ],
      usePerChatPredictionConfig: false,
      perChatPredictionConfig: { fields: [] },
      clientInput: "",
      clientInputFiles: [],
      userFilesSizeBytes: 0,
      notes: [],
      plugins: [],
      pluginConfigs: {},
      disabledPluginTools: [],
      looseFiles: []
    }
  '';

  json-to-lmstudio = pkgs.writeShellApplication {
    name = "json-to-lmstudio";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      if [ $# -lt 1 ]; then
        echo "usage: json-to-lmstudio <input.json> [output.conversation.json]" >&2
        echo "       json-to-lmstudio <input-dir> <output-dir>" >&2
        exit 1
      fi

      DETECT=${detectJq}
      NORM_WORKPENT=${normalizeWorkpentJq}
      TO_LMSTUDIO=${toLmstudioJq}

      convert_one() {
        local in_file="$1"
        local out_file="$2"

        if ! jq empty "$in_file" 2>/dev/null; then
          echo "skip: $in_file is not valid JSON" >&2
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

        jq -f "$normalizer" "$in_file" | jq -f "$TO_LMSTUDIO" > "$out_file"
        echo "converted: $in_file -> $out_file"
      }

      if [ -d "$1" ]; then
        in_dir="$1"
        out_dir="''${2:?output directory required when input is a directory}"
        mkdir -p "$out_dir"
        for f in "$in_dir"/*.json; do
          [ -e "$f" ] || continue
          base=$(basename "$f" .json)
          convert_one "$f" "$out_dir/$base.conversation.json" || true
        done
      else
        in_file="$1"
        out_file="''${2:-''${in_file%.json}.conversation.json}"
        convert_one "$in_file" "$out_file"
      fi
    '';
  };

  lm-import = pkgs.writeShellApplication {
    name = "lm-import";
    runtimeInputs = [ json-to-lmstudio pkgs.coreutils ];
    text = ''
      if [ $# -lt 1 ]; then
        echo "usage: lm-import <input.json-or-dir> [output]" >&2
        echo "       defaults to /tmp/lm-import-<timestamp>/" >&2
        exit 1
      fi

      INPUT="$1"
      OUTPUT="''${2:-/tmp/lm-import-$(date +%s)}"

      json-to-lmstudio "$INPUT" "$OUTPUT"

      echo "" >&2
      echo "to apply:" >&2
      echo "  mkdir -p ~/.local/share/LM\\ Studio/conversations/" >&2
      if [ -f "$OUTPUT" ]; then
        echo "  mv \"$OUTPUT\" ~/.local/share/LM\\ Studio/conversations/" >&2
      else
        echo "  mv \"$OUTPUT\"/*.conversation.json ~/.local/share/LM\\ Studio/conversations/" >&2
      fi
      echo "" >&2
      echo "adjust path above if your LM Studio conversations directory is elsewhere" >&2
    '';
  };
in
{
  environment.systemPackages = [ json-to-lmstudio lm-import ];
}
