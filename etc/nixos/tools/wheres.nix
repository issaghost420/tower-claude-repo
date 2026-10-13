# wheres.nix — the whole tool, one file. Import it and rebuild:
#   imports = [ ./wheres.nix ];
#
# Three pieces, none of which you ever touch by hand:
#   1. the engine     — a real executable in PATH, so starship and
#                       zsh-syntax-highlighting colour it as a command
#   2. the completion — installed into $fpath automatically
#   3. the cd wrapper — auto-loaded into every interactive zsh, because a
#                       subprocess physically cannot cd its parent shell
#
# There is nothing to source. `wheres` behaves the same from an interactive
# shell, a script, or inside $( ).

{ pkgs, lib, ... }:

let
  wheresEngine = pkgs.writeShellApplication {
    name = "wheres";
    runtimeInputs = with pkgs; [
      fzf fd ripgrep bat chafa file coreutils wl-clipboard micro
    ];
    excludeShellChecks = [ "SC2016" "SC2004" "SC2086" "SC2317" ];
    text = ''
      # wheres — a hyperfocused file finder/retriever.
      # Filename search and content search in one window, switchable live.
      # Prints selected paths to stdout so it composes: micro "$(wheres)"

      set -o pipefail

      WHERES_VERSION="2.1"

      # ---------------------------------------------------------------------------
      # Internal: preview renderer. Called by fzf as `wheres --_preview <item>`.
      # Handles both plain paths and rg-style "path:line:text" hits.
      # Every branch is errexit-safe: writeShellApplication runs us under set -e,
      # and a preview that returns nonzero renders as an empty pane.
      # ---------------------------------------------------------------------------
      _wheres_preview() {
          local item="''${1:-}" path lineno mime
          [[ -z "$item" ]] && { echo "[nothing selected]"; return 0; }

          if [[ "$item" =~ ^(.+):([0-9]+):.*$ ]] && [[ -f "''${BASH_REMATCH[1]}" ]]; then
              path="''${BASH_REMATCH[1]}"
              lineno="''${BASH_REMATCH[2]}"
          else
              path="$item"
              lineno=""
          fi

          if [[ -d "$path" ]]; then
              command ls -la --color=always "$path" 2>/dev/null || command ls -la "$path" || true
              return 0
          fi

          if [[ ! -e "$path" ]]; then
              echo "[no such path: $path]"
              return 0
          fi

          if [[ ! -r "$path" ]]; then
              echo "[not readable: $path]"
              command ls -la "$path" 2>/dev/null || true
              return 0
          fi

          mime=$(file --mime-type -b "$path" 2>/dev/null || echo "application/octet-stream")

          case "$mime" in
              image/*)
                  # Text-only rendering. fzf's preview pane is a text region it
                  # redraws at will; any terminal graphics protocol drawn here
                  # outlives the redraw and burns into the scrollback.
                  chafa -f symbols \
                        --view-size="''${FZF_PREVIEW_COLUMNS:-80}x''${FZF_PREVIEW_LINES:-40}" \
                        "$path" 2>/dev/null || echo "[image: $path]"
                  ;;
              inode/*|application/x-executable|application/x-sharedlib|application/x-pie-executable)
                  file -b "$path" || true
                  echo
                  command ls -la "$path" || true
                  ;;
              application/octet-stream|application/zip|application/gzip|application/x-tar|video/*|audio/*)
                  file -b "$path" || true
                  echo
                  command ls -lah "$path" || true
                  ;;
              *)
                  if [[ -n "$lineno" ]]; then
                      bat --style=numbers --color=always --highlight-line "$lineno" \
                          --line-range "$(( lineno > 10 ? lineno - 10 : 1 )):$(( lineno + 60 ))" \
                          "$path" 2>/dev/null || head -200 "$path" 2>/dev/null || true
                  else
                      bat --style=numbers --color=always --line-range :200 "$path" 2>/dev/null \
                          || head -200 "$path" 2>/dev/null || true
                  fi
                  ;;
          esac
          return 0
      }

      if [[ "''${1:-}" == "--_preview" ]]; then
          _wheres_preview "''${2:-}"
          exit 0
      fi

      # ---------------------------------------------------------------------------
      # Help
      # ---------------------------------------------------------------------------
      _wheres_help() {
          cat <<'EOF'
      wheres — find files by name or by content, then take them somewhere.

      USAGE
        wheres [OPTIONS] [query]

      OPTIONS
        -c, --contents        Start in content mode (ripgrep). Default is filename mode.
        -r, --root DIR        Search under DIR instead of the current directory.
        -d, --dirs            Match directories only.
        -e, --editor          Open the selection in the editor on Enter.
        -0, --print0          Separate printed paths with NUL (for xargs -0).
            --abs             Print absolute paths instead of as-found.
            --no-preview      Start with the preview pane hidden.
        -h, --help            This message.
        -V, --version         Version.

      KEYS (inside the finder)
        Tab / Shift-Tab       Select / deselect (multi-select)
        Ctrl-A                Select all matches
        Ctrl-\                Deselect all
        Enter                 Print selected path(s) to stdout
        Alt-Enter             Open selection(s) in the editor
        Ctrl-O                Same as Alt-Enter
        Ctrl-D                cd to the containing directory
        Ctrl-Y                Copy path(s) to the clipboard
        Ctrl-F                Switch to FILENAME mode, keeping your query
        Ctrl-G                Switch to CONTENT mode, keeping your query
        Ctrl-P                Toggle the preview pane
        Ctrl-U / Ctrl-E       Scroll the preview pane
        Esc / Ctrl-C          Cancel, cleanly, printing nothing

      EDITOR
        $WHERES_EDITOR if set, else $EDITOR, else micro.

      MODES
        FILENAME   fd lists everything once; fzf fuzzy-filters it as you type.
                   Instant, no re-running, good for "I know roughly what it's called".
        CONTENT    ripgrep re-runs on every keystroke; fzf does not filter.
                   Query is a regex. Long lines are truncated so minified JSON and
                   .jsonl never blow up the pane.

      COMPOSING
        micro "$(wheres)"                   open one file
        wheres -0 | xargs -0 rg TODO        feed many files onward
        wheres -c "Xid 79"                  jump straight to a content hit
        cp "$(wheres -r ~/Pictures)" .      one-off retrieval
      EOF
      }

      # ---------------------------------------------------------------------------
      # Argument parsing
      # ---------------------------------------------------------------------------
      mode="name"
      search_root="."
      dirs_only=false
      open_editor=false
      print0=false
      abs_paths=false
      show_preview=true

      while [[ $# -gt 0 ]]; do
          case "$1" in
              -c|--contents)  mode="content"; shift ;;
              -r|--root)
                  if [[ -z "''${2:-}" || "''${2:-}" == -* ]]; then
                      echo "wheres: --root needs a directory" >&2; exit 2
                  fi
                  search_root="''${2/#\~/$HOME}"; shift 2 ;;
              -d|--dirs)      dirs_only=true; shift ;;
              -e|--editor)    open_editor=true; shift ;;
              -0|--print0)    print0=true; shift ;;
              --abs)          abs_paths=true; shift ;;
              --no-preview)   show_preview=false; shift ;;
              -h|--help)      _wheres_help; exit 0 ;;
              -V|--version)   echo "wheres $WHERES_VERSION"; exit 0 ;;
              --)             shift; break ;;
              -*)             echo "wheres: unknown option '$1' (try --help)" >&2; exit 2 ;;
              *)              break ;;
          esac
      done

      if [[ ! -d "$search_root" ]]; then
          echo "wheres: no such directory: $search_root" >&2
          exit 2
      fi

      query="''${*:-}"

      for tool in fzf fd rg; do
          if ! command -v "$tool" >/dev/null 2>&1; then
              echo "wheres: '$tool' not found in PATH" >&2; exit 3
          fi
      done

      # ---------------------------------------------------------------------------
      # Search command construction
      # ---------------------------------------------------------------------------
      root_q=$(printf '%q' "$search_root")

      # Absolute path to ourselves, so the fzf preview subprocess can re-invoke us
      # no matter what the cwd is or how we were called.
      self=$(command -v wheres 2>/dev/null || true)
      [[ -z "$self" ]] && self="''${BASH_SOURCE[0]}"
      self=$(printf '%q' "$self")

      fd_flags="-uu --color=always"
      if [[ "$dirs_only" == true ]]; then
          fd_flags="$fd_flags --type d"
      fi
      fd_cmd="fd $fd_flags . $root_q"

      rg_cmd="rg --line-number --no-heading --color=always --smart-case \
      --max-columns=200 --max-columns-preview --hidden --glob '!.git' \
      -- {q} $root_q </dev/null || true"

      # ---------------------------------------------------------------------------
      # fzf invocation
      # ---------------------------------------------------------------------------
      fzf_args=(
          --ansi
          --multi
          --height '90%'
          --border
          --info inline
          --layout reverse
          --marker '▏'
          --pointer '▸'
          --delimiter ':'
          --expect 'ctrl-d,ctrl-y,ctrl-o,alt-enter'
          --header 'Tab select · ⏎ print · M-⏎ edit · ^F name · ^G text · ^Y copy · ^D cd · ^P preview'
          --bind 'tab:toggle+down'
          --bind 'shift-tab:toggle+up'
          --bind 'ctrl-a:select-all'
          --bind 'ctrl-\:deselect-all'
          --bind 'ctrl-p:toggle-preview'
          --bind 'ctrl-u:preview-half-page-up'
          --bind 'ctrl-e:preview-half-page-down'
          --bind "ctrl-f:unbind(change)+enable-search+change-prompt(name❯ )+reload($fd_cmd)+first"
          --bind "ctrl-g:rebind(change)+disable-search+change-prompt(text❯ )+reload($rg_cmd)+first"
      )

      if [[ "$show_preview" == true ]]; then
          fzf_args+=(
              --preview "$self --_preview {}"
              --preview-window 'right,55%,wrap,border-left'
          )
      else
          fzf_args+=(
              --preview "$self --_preview {}"
              --preview-window 'hidden,right,55%,wrap'
          )
      fi

      fzf_ret=0
      if [[ "$mode" == "content" ]]; then
          fzf_args+=(
              --disabled
              --prompt 'text❯ '
              --query "$query"
              --bind "start:reload($rg_cmd)"
              --bind "change:reload($rg_cmd)"
              --preview-window 'right,55%,wrap,border-left,+{2}+3/2'
          )
          raw=$(: | fzf "''${fzf_args[@]}") || fzf_ret=$?
      else
          fzf_args+=(
              --prompt 'name❯ '
              --query "$query"
              --bind "start:unbind(change)"
          )
          # fd exits nonzero on permission errors (scanning / hits /proc, /root...).
          # Process substitution keeps that out of the pipeline so fzf owns the status.
          raw=$(fzf "''${fzf_args[@]}" < <(eval "$fd_cmd" 2>/dev/null)) || fzf_ret=$?
      fi

      # 130 = Ctrl-C / Esc. Exit silently, print nothing, leave no trace.
      if [[ $fzf_ret -ne 0 ]]; then
          exit "$fzf_ret"
      fi
      if [[ -z "''${raw:-}" ]]; then
          exit 1
      fi

      # ---------------------------------------------------------------------------
      # Result parsing: line 1 is the --expect key (blank for plain Enter)
      # ---------------------------------------------------------------------------
      key=$(printf '%s\n' "$raw" | head -1)
      selections=$(printf '%s\n' "$raw" | tail -n +2)
      if [[ -z "$selections" ]]; then
          exit 1
      fi

      paths=()
      lines=()
      while IFS= read -r item; do
          [[ -z "$item" ]] && continue
          if [[ "$item" =~ ^(.+):([0-9]+):.*$ ]] && [[ -e "''${BASH_REMATCH[1]}" ]]; then
              paths+=("''${BASH_REMATCH[1]}")
              lines+=("''${BASH_REMATCH[2]}")
          else
              paths+=("$item")
              lines+=("")
          fi
      done <<< "$selections"

      if [[ ''${#paths[@]} -eq 0 ]]; then
          exit 1
      fi

      if [[ "$abs_paths" == true ]]; then
          for i in "''${!paths[@]}"; do
              paths[i]=$(readlink -f "''${paths[i]}" 2>/dev/null || printf '%s' "''${paths[i]}")
          done
      fi

      wrapped="''${WHERES_WRAPPED:-}"

      emit_paths() {
          if [[ "$print0" == true ]]; then
              printf '%s\0' "''${paths[@]}"
          else
              printf '%s\n' "''${paths[@]}"
          fi
      }

      # Ctrl-D: the wrapper does the actual cd. Unwrapped we just print the directory,
      # because emitting an internal marker to a human's terminal is a bug, not a mode.
      do_cd() {
          local first="''${paths[0]}"
          [[ -d "$first" ]] || first=$(dirname "$first")
          if [[ -n "$wrapped" ]]; then
              printf '__WHERES_CD__\t%s\n' "$first"
          else
              printf '%s\n' "$first"
          fi
      }

      copy_paths() {
          local joined
          joined=$(printf '%s\n' "''${paths[@]}")
          if   command -v wl-copy >/dev/null 2>&1; then printf '%s' "$joined" | wl-copy
          elif command -v xclip   >/dev/null 2>&1; then printf '%s' "$joined" | xclip -selection clipboard
          elif command -v pbcopy  >/dev/null 2>&1; then printf '%s' "$joined" | pbcopy
          else echo "wheres: no clipboard tool (wl-copy/xclip)" >&2; return 0
          fi
          echo "copied ''${#paths[@]} path(s)" >&2
          return 0
      }

      open_in_editor() {
          local ed="''${WHERES_EDITOR:-''${EDITOR:-micro}}"
          # Under the wrapper our stdout is inside $( ), which would swallow the
          # editor's TUI. Hand the job back to the wrapper instead of running it here.
          if [[ -n "$wrapped" ]]; then
              printf '__WHERES_EDIT__\t%s\n' "''${lines[0]}"
              printf '%s\n' "''${paths[@]}"
              return 0
          fi
          if [[ ''${#paths[@]} -eq 1 && -n "''${lines[0]}" ]] \
             && [[ "$ed" =~ (vim|nvim|nano|hx|helix|kak|micro) ]]; then
              "$ed" "+''${lines[0]}" "''${paths[0]}"
          else
              "$ed" "''${paths[@]}"
          fi
      }

      case "$key" in
          ctrl-d)              do_cd ;;
          ctrl-y)              copy_paths; emit_paths ;;
          ctrl-o|alt-enter)    open_in_editor ;;
          *)
              if [[ "$open_editor" == true ]]; then
                  open_in_editor
              else
                  emit_paths
              fi
              ;;
      esac

    '';
  };

  wheresCompletion = pkgs.writeTextFile {
    name = "wheres-zsh-completion";
    destination = "/share/zsh/site-functions/_wheres";
    text = ''
      #compdef wheres

      _wheres() {
          _arguments -s -S \
              '(-c --contents)'{-c,--contents}'[start in content mode (ripgrep)]' \
              '(-r --root)'{-r,--root}'[search under DIR instead of cwd]:directory:_files -/' \
              '(-d --dirs)'{-d,--dirs}'[match directories only]' \
              '(-e --editor)'{-e,--editor}'[open selection in editor on Enter]' \
              '(-0 --print0)'{-0,--print0}'[NUL-separate printed paths]' \
              '--abs[print absolute paths]' \
              '--no-preview[start with preview hidden]' \
              '(-h --help)'{-h,--help}'[show help]' \
              '(-V --version)'{-V,--version}'[show version]' \
              '*:query:'
      }

      _wheres "$@"

    '';
  };
in
{
  environment.systemPackages = [
    wheresEngine
    wheresCompletion
    pkgs.fzf pkgs.fd pkgs.ripgrep pkgs.bat pkgs.chafa pkgs.wl-clipboard pkgs.micro
  ];

  # Auto-loaded. The only reason a shell function exists at all.
  programs.zsh.interactiveShellInit = lib.mkAfter ''
    wheres() {
        emulate -L zsh
        local out ret first lineno ed
        local -a files

        out=$(WHERES_WRAPPED=1 command wheres "$@")
        ret=$?

        # Ctrl-C / Esc / no match: stay silent, change nothing.
        [[ $ret -ne 0 || -z "$out" ]] && return $ret

        first="''${out%%$'\n'*}"

        case "$first" in
            __WHERES_CD__*)
                local dir="''${first#*$'\t'}"
                if [[ -d "$dir" ]]; then
                    cd -- "$dir" && print -r -- "→ $PWD"
                else
                    print -ru2 -- "wheres: not a directory: $dir"
                    return 1
                fi
                ;;
            __WHERES_EDIT__*)
                lineno="''${first#*$'\t'}"
                files=("''${(@f)''${out#*$'\n'}}")
                ed="''${WHERES_EDITOR:-''${EDITOR:-micro}}"
                if [[ ''${#files} -eq 1 && -n "$lineno" && "$ed" == (*vim*|*nano*|*hx*|*helix*|*kak*|*micro*) ]]; then
                    "$ed" "+$lineno" "$files[1]"
                else
                    "$ed" "''${files[@]}"
                fi
                ;;
            *)
                print -r -- "$out"
                ;;
        esac
    }

  '';
}
