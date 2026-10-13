{ pkgs, lib, ... }:

let
  nemoEngine = pkgs.writeShellApplication {
    name = "nemo";
    runtimeInputs = with pkgs; [
      curl ffmpeg jq file coreutils gnugrep gawk less wl-clipboard
    ];
    excludeShellChecks = [ "SC2016" "SC2317" ];
    text = ''
      # nemo — transcribe audio/video files with an OpenAI-compatible STT
      # server (NeMo on Titan by default).
      #
      # Transcript goes to stdout. Status and errors go to stderr, so it
      # composes like a good Unix tool:
      #
      #   nemo memo.m4a > memo.txt
      #   nemo memo.m4a -w memo.txt -c        # save AND clipboard
      #   nemo clip.mp4 | glow -              # video works too
      #   nemo memo.m4a --host dacrib         # point at another box
      #
      # Video inputs are auto-detected (ffprobe, with a file-mime fallback)
      # and the audio track is extracted to a temp mp3 before upload.
      # Use --keep-audio to keep the extracted track next to the video.

      NEMO_VERSION="0.1.0"

      die() { printf 'nemo: %s\n' "$*" >&2; exit 1; }

      # ---------------------------------------------------------------------------
      # Help
      # ---------------------------------------------------------------------------
      nemo_help() {
          cat <<'EOF'
      nemo — transcribe audio/video files to text via NeMo STT.

      USAGE
        nemo [OPTIONS] FILE

      ARGUMENTS
        FILE                  Audio or video file to transcribe. Video files
                              are auto-detected; audio is extracted with
                              ffmpeg to a temp file (see --keep-audio).

      OPTIONS
        -p, --pager           Open the transcript in $PAGER (default: less)
                              instead of printing to stdout.
        -w, --write PATH      Also write the transcript to PATH (refuses to
                              overwrite an existing file).
        -c, --copy            Also copy the transcript to the clipboard (wl-copy).
            --json            Print the raw JSON response instead of the text.
            --keep-audio      When input is video, keep the extracted audio as
                              FILE-with-.audio.mp3-suffix next to the input.
            --language CODE   Send a language hint to the server.
            --model NAME      Model to request (default: canary-qwen-2.5b;
                              env $NEMO_MODEL).
            --host HOST       STT host (default: titan; env $NEMO_HOST).
            --port PORT       STT port (default: 8091; env $NEMO_PORT).
            --url URL         Full endpoint URL override:
                              http://HOST:PORT/v1/audio/transcriptions
            --ping            Check server health and exit.
        -h, --help            This message.
        -V, --version         Version.

      OUTPUT CONTRACT
        stdout  transcript text only (machine-friendly)
        stderr  human status chatter and errors

      EXAMPLES
        nemo memo.m4a                     print transcript
        nemo memo.m4a -p                  read it in less
        nemo memo.m4a -w memo.txt         save it
        nemo memo.m4a -c                  clipboard it
        nemo meeting.mp4                  video: extract, upload, print
        nemo meeting.mp4 --keep-audio     ...and keep meeting.audio.mp3
        nemo memo.m4a --host dacrib       use another box's STT server
        nemo --ping                       is Titan up?

      EXIT CODES
        0 ok · 1 transcription failed · 2 usage error · 3 server unreachable
      EOF
      }

      # ---------------------------------------------------------------------------
      # Defaults (env-overridable)
      # ---------------------------------------------------------------------------
      file=""
      pager_flag=false
      write_path=""
      copy_flag=false
      json_flag=false
      keep_audio=false
      ping_flag=false
      model="''${NEMO_MODEL:-canary-qwen-2.5b}"
      host="''${NEMO_HOST:-titan}"
      port="''${NEMO_PORT:-8091}"
      url_override=""
      language=""
      tmpdir=""

      # ---------------------------------------------------------------------------
      # Argument parsing
      # ---------------------------------------------------------------------------
      while [[ $# -gt 0 ]]; do
          case "$1" in
              -p|--pager)       pager_flag=true; shift ;;
              -w|--write)
                  [[ -z "''${2:-}" || "''${2:-}" == -* ]] && die "--write needs a path"
                  write_path=$2; shift 2 ;;
              -c|--copy)        copy_flag=true; shift ;;
              --json)           json_flag=true; shift ;;
              --keep-audio)     keep_audio=true; shift ;;
              --ping)           ping_flag=true; shift ;;
              --model)
                  [[ -z "''${2:-}" ]] && die "--model needs a name"
                  model=$2; shift 2 ;;
              --host)
                  [[ -z "''${2:-}" ]] && die "--host needs a hostname"
                  host=$2; shift 2 ;;
              --port)
                  [[ -z "''${2:-}" ]] && die "--port needs a number"
                  port=$2; shift 2 ;;
              --url)
                  [[ -z "''${2:-}" ]] && die "--url needs a URL"
                  url_override=$2; shift 2 ;;
              --language)
                  [[ -z "''${2:-}" ]] && die "--language needs a code"
                  language=$2; shift 2 ;;
              -h|--help)        nemo_help; exit 0 ;;
              -V|--version)     echo "nemo $NEMO_VERSION"; exit 0 ;;
              --)               shift; break ;;
              -*)               die "unknown option '$1' (try --help)" ;;
              *)
                  [[ -n "$file" ]] && die "only one input file allowed"
                  file=$1; shift ;;
          esac
      done
      if [[ -z "$file" && $# -gt 0 ]]; then
          file=$1; shift
      fi
      [[ $# -gt 0 ]] && die "only one input file allowed"

      # ---------------------------------------------------------------------------
      # --ping: health check and out
      # ---------------------------------------------------------------------------
      base="''${url_override:-http://$host:$port}"
      base="''${base%/v1/audio/transcriptions}"
      if [[ "$ping_flag" == true ]]; then
          if curl -fsS --max-time 5 "$base/health" >/dev/null 2>&1; then
              echo "nemo: $base is up (model=$model)"
              exit 0
          fi
          die "$base is not reachable (is the STT container up?)"
      fi

      # ---------------------------------------------------------------------------
      # Validate input
      # ---------------------------------------------------------------------------
      if [[ -z "$file" ]]; then
          nemo_help >&2
          die "no input file"
      fi
      [[ -e "$file" ]] || die "no such file: $file"
      [[ -r "$file" ]] || die "not readable: $file"

      # ---------------------------------------------------------------------------
      # Audio vs video detection: ffprobe first, file(1) mime as fallback
      # ---------------------------------------------------------------------------
      kind="audio"
      vstream=$(ffprobe -v error -select_streams v:0 \
          -show_entries stream=codec_type -of csv=p=0 "$file" 2>/dev/null || true)
      if [[ "$vstream" == "video" ]]; then
          kind="video"
      else
          mime=$(file -b --mime-type "$file" 2>/dev/null || echo "")
          if [[ "$mime" == video/* ]]; then
              kind="video"
          fi
      fi

      # ---------------------------------------------------------------------------
      # Extract audio track for video inputs
      # ---------------------------------------------------------------------------
      upload=$file
      if [[ "$kind" == "video" ]]; then
          if [[ "$keep_audio" == true ]]; then
              upload="''${file%.*}.audio.mp3"
              [[ -e "$upload" ]] && die "refusing to overwrite existing $upload"
              echo "nemo: extracting audio → $upload" >&2
              if ! ffmpeg -hide_banner -loglevel error -i "$file" \
                      -vn -acodec libmp3lame -q:a 2 "$upload"; then
                  die "ffmpeg failed to extract audio from $file"
              fi
          else
              tmpdir=$(mktemp -d /tmp/nemo.XXXXXX)
              upload="$tmpdir/audio.mp3"
              echo "nemo: extracting audio (temp)..." >&2
              if ! ffmpeg -hide_banner -loglevel error -y -i "$file" \
                      -vn -acodec libmp3lame -q:a 2 "$upload"; then
                  rm -rf "$tmpdir"
                  die "ffmpeg failed to extract audio from $file"
              fi
          fi
      fi
      trap 'if [[ -n "$tmpdir" ]]; then rm -rf "$tmpdir"; fi' EXIT

      # ---------------------------------------------------------------------------
      # Transcribe
      # ---------------------------------------------------------------------------
      endpoint="''${url_override:-http://$host:$port/v1/audio/transcriptions}"
      echo "nemo: transcribing $(basename "$file") via $host (model=$model)..." >&2

      curl_args=(-sS --fail-with-body --max-time 900 -X POST "$endpoint"
                 -F "file=@$upload" -F "model=$model")
      if [[ -n "$language" ]]; then
          curl_args+=(-F "language=$language")
      fi

      if ! resp=$(curl "''${curl_args[@]}"); then
          printf 'nemo: request failed. server said:\n%s\n' "$resp" >&2
          exit 1
      fi

      if [[ "$json_flag" == true ]]; then
          printf '%s\n' "$resp"
          exit 0
      fi

      transcript=$(jq -r 'if type == "object" then (.text // "") else "" end' \
          <<<"$resp" 2>/dev/null || true)
      if [[ -z "$transcript" ]]; then
          printf 'nemo: no transcript text in response:\n%s\n' "$resp" >&2
          exit 1
      fi

      # ---------------------------------------------------------------------------
      # Outputs: --write, --copy, then --pager or stdout
      # ---------------------------------------------------------------------------
      if [[ -n "$write_path" ]]; then
          [[ -e "$write_path" ]] && die "refusing to overwrite existing $write_path"
          if ! printf '%s\n' "$transcript" > "$write_path"; then
              die "could not write $write_path"
          fi
          echo "nemo: wrote $write_path" >&2
      fi

      if [[ "$copy_flag" == true ]]; then
          if printf '%s' "$transcript" | wl-copy 2>/dev/null; then
              echo "nemo: copied to clipboard" >&2
          else
              echo "nemo: wl-copy failed (no wayland clipboard?)" >&2
          fi
      fi

      if [[ "$pager_flag" == true ]]; then
          printf '%s\n' "$transcript" | "''${PAGER:-less}"
      else
          printf '%s\n' "$transcript"
      fi

    '';
  };

  nemoCompletion = pkgs.writeTextFile {
    name = "nemo-zsh-completion";
    destination = "/share/zsh/site-functions/_nemo";
    text = ''
      #compdef nemo

      _nemo() {
          _arguments -s -S \
              '(-p --pager)'{-p,--pager}'[open transcript in pager]' \
              '(-w --write)'{-w,--write}'[also write transcript to file]:output file:_files' \
              '(-c --copy)'{-c,--copy}'[also copy transcript to clipboard]' \
              '--json[print raw JSON response instead of text]' \
              '--keep-audio[keep extracted audio next to video input]' \
              '--language[language hint]:language code:' \
              '--model[model name]:model:(canary-qwen-2.5b)' \
              '--host[STT host]:host:(titan dacrib)' \
              '--port[STT port]:port:' \
              '--url[full endpoint URL]:url:' \
              '--ping[check server health and exit]' \
              '(-h --help)'{-h,--help}'[show help]' \
              '(-V --version)'{-V,--version}'[show version]' \
              '*:media file:_files'
      }

      _nemo "$@"

    '';
  };
in
{
  environment.systemPackages = [
    nemoEngine
    nemoCompletion
  ];
}
