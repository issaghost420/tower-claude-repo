{ config, pkgs, ... }:
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;

    histSize = 10000;

    setOptions = [
      "NO_CHECK_JOBS"
      "NO_HUP"
      "HIST_IGNORE_SPACE"
      "SHARE_HISTORY"
    ];

    ohMyZsh = {
      enable = true;
      theme = "";
      plugins = [
        "command-not-found" "extract" "fzf" "git"
        "history-substring-search" "man" "python" "sudo" "z"
      ];
    };

    shellAliases = {
      # AI terminal assistant (aichat -> LM Studio)
      ai = "aichat";
      wtf = "aichat -e";
      dafuq = "aichat -e";
      yo = "aichat";
      hf-download = "huggingface-cli download";

      # Config editing
      nix-config = "sudo micro /etc/nixos/configuration.nix";
      nix-config-open = "sublime /etc/nixos/configuration.nix";
      dcyml = "micro ~/ninjastack/docker-compose.yml";
      pkgs = "grep -in -A 200 'environment.systemPackages' /etc/nixos/configuration.nix";

      ghost = "/home/dacrib/scripts/ghost";
      h = "hist";

      # GPU monitoring
      gpumon = "watch -n 1 nvidia-smi";
#      towermon = "cd ~/ninjastack/system-monitor && nix-shell -p 'python3.withPackages (ps: with ps; [psutil rich])' --run 'python3 towermon_terminal.py'";
#      towermon-widget = "~/ninjastack/system-monitor/run-widget.sh";
#      towermon-status = "systemctl status towermon";

      kitty-gate = "kitty-gatekeeper";

      # Speech-to-text (Nemo stt on Titan)
      stt      = "cd ~/tools/stt && nix-shell --run './stt'";
      stt-pick = "cd ~/tools/stt && ./stt --pick";
      stt-mics = "cd ~/tools/stt && nix-shell --run './list-mics'";

      # Text-to-speech (Chatterbox on Titan)
      tts = "/home/tower/tools/tts/tts.sh";

      # Services
      restart-wg = "sudo systemctl restart wg-quick-wg0";
      start-wg   = "sudo systemctl start wg-quick-wg0";
      status-wg  = "sudo systemctl status wg-quick-wg0";
      stop-wg    = "sudo systemctl stop wg-quick-wg0";

      # SSH
      tower  = "ssh dacrib@192.168.50.140";
      titan  = "ssh titan@192.168.50.197";
      merk   = "ssh merk@192.168.50.199";
    };

    interactiveShellInit = ''
      PROMPT_EOL_MARK=""
      HIST_STAMPS="mm/dd/yyyy"
      ENABLE_CORRECTION="true"
      COMPLETION_WAITING_DOTS="true"
      export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/towerstack/scripts:$HOME/.lmstudio/bin:$PATH"
      export EDITOR="gram"
      bindkey '^K' kill-whole-line
      autoload -Uz compinit && compinit
      zstyle ':omz:update' mode reminder

      # ===============================================
      # aichat integration
      # ===============================================
      fpath=(~/.zsh/completions $fpath)

      _aichat_zsh() {
        if [[ -n "$BUFFER" ]]; then
          local _old=$BUFFER
          BUFFER+="⏳"
          zle -I && zle redisplay
          BUFFER=$(aichat -e "$_old")
          zle end-of-line
        fi
      }
      zle -N _aichat_zsh
      bindkey '\ee' _aichat_zsh

      halp() {
        local context="Current directory: $PWD
Recent commands:
$(fc -ln -20)

Question: $*"
        echo "$context" | aichat 2>/dev/null | sed '/<think>/,/<\/think>/d; /<think>/,$d'
      }

      halpdo() {
        local context="Current directory: $PWD
Recent commands:
$(fc -ln -10)

Task: $*"
        echo "$context" | aichat -e 2>/dev/null | sed '/<think>/,/<\/think>/d; /<think>/,$d'
      }

      setopt NO_CHECK_JOBS
      setopt NO_HUP
      setopt HIST_IGNORE_SPACE
      PROMPT_EOL_MARK=""
      HIST_STAMPS="mm/dd/yyyy"
      ENABLE_CORRECTION="true"
      COMPLETION_WAITING_DOTS="true"
      export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/towerstack/scripts:$HOME/.lmstudio/bin:$PATH"
      export EDITOR="gram"
      bindkey '^K' kill-whole-line
      autoload -Uz compinit && compinit
      zstyle ':omz:update' mode reminder

      nix-switch() {
        local gen
        gen=$(readlink /nix/var/nix/profiles/system | sed 's/system-\([0-9]*\)-link/\1/')
        local stamp="$(date +%Y-%m-%d-%H%M%S)"
        local backup="$HOME/configuration-nix-backups/gen''${gen}-''${stamp}"
        mkdir -p "$HOME/configuration-nix-backups"
        sudo cp -r /etc/nixos "$backup"
        echo "📁 Backed up to: $backup"
        echo ""
        echo "=== Changes ==="
        (cd /etc/nixos && sudo git diff --color)
        echo ""
        read "?Press Enter to commit & rebuild (Ctrl+C to abort)..."
        (cd /etc/nixos && sudo git add -A && sudo git commit -m "gen''${gen} - $(date +%Y-%m-%d\ %H:%M:%S)")
        nh os switch
      }


      # ===============================================
      # Image Conversion
      # ===============================================

      # HEIC to PNG - parallel batch conversion (uses all cores)
      heic2png() {
        # Use 80% of available threads for parallelism, let ImageMagick use multiple threads per file too
        local jobs=$(( $(nproc) * 4 / 5 ))
        [[ $jobs -lt 1 ]] && jobs=1

        if [[ $# -gt 0 ]]; then
          printf '%s\n' "$@" | parallel -j"$jobs" 'magick {} -quality 100 -define png:compression-level=9 {.}.png'
        else
          ls *.HEIC 2>/dev/null | parallel -j"$jobs" 'magick {} -quality 100 -define png:compression-level=9 {.}.png'
        fi
      }

      # Send file to Titan: send-titan <file> [remote-path]
      send-titan() {
        rsync -avP "$1" titan@192.168.50.197:"''${2:-.}"
      }

      # Get file from Titan: from-titan <remote-path> [local-path]
      from-titan() {
        rsync -avP titan@192.168.50.197:"$1" "''${2:-.}"
      }

      # Fuzzy find files
      ff() {
        find "''${1:-.}" 2>/dev/null | fzf
      }

      hist() {
          # Get the number from argument (if any) and default to 25
          local limit=200
          if [[ -n "$1" ]]; then
              # Remove leading + or - and take absolute value
              limit=''${1#[-+]}
              # If it's not a number, fallback to 50
              [[ "$limit" =~ ^[0-9]+$ ]] || limit=50
          fi

          local now=$EPOCHSECONDS i=0
          while read -r line; do
              ((i++))
              [[ $line == \#* || -z $line ]] && continue
              if [[ $line =~ '^: ([0-9]+):[0-9]+;(.*)$' ]]; then
                  local ts=$match[1] cmd=$match[2]
                  local diff=$((now - ts))
                  local rel
                  if   (( diff < 60 ));    then rel="''${diff}sec"
                  elif (( diff < 3600 ));  then rel="$((diff/60))min"
                  elif (( diff < 86400 )); then rel="$((diff/3600))hr"
                  else                           rel="$((diff/86400))d"
                  fi
                  printf "%-5s %-6s %s\n" "$i" "$rel" "$cmd"
              fi
          done < ~/.zsh_history | tail -n "$limit"
      }

      # Fuzzy find and cd into any directory
      cdf() {
        local dir
        dir=$(fd --type d --hidden --exclude .git 2>/dev/null | fzf --preview 'ls -la {}' --height 40%) && cd "$dir"
      }

      # Alternative if fd isn't available
      cdff() {
        local dir
        dir=$(find ''${1:-.} -type d 2>/dev/null | fzf --preview 'ls -la {}' --height 40%) && cd "$dir"
      }

      # Clean attribute finder for system packages
      nix-find() {
        nix search nixpkgs "$1" 2>/dev/null | grep '^\*' | sed -E 's/^\* [^.]+\.[^.]+\.//' | awk '{print $1}'
      }

      # ================================================
      # Navigation - Appendable path shortcuts
      # ================================================
      ns    () { cd /home/dacrib/ninjastack/"$@"; }
      pi    () { cd /home/dacrib/ninjastack/etc-pihole/"$@"; }
      nixx  () { cd /etc/nixos/"$@"; }

      # The following aliases can be used in combo with other like-kinded aliases
      # examples - # micro $(nx modules/services/caddy.nix) # micro $(nx home/tower/shell.nix) # grep -r "caddy" $(nx modules/) # etc...
      nx    () { echo /etc/nixos/"$@"; }

      # ================================================================
      # wheres — navigate/view/print/copy with previews & content search
      # ================================================================
      wheres() {
        local target
        local mode="navigate"
        local show_preview=true
        local search_root="."
        local exact_match=false
        local search_tool="fd" # 'fd', 'rg', or 'rg-filtered'

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --view)
              mode="view"
              shift
              ;;
            --nav|--cd)
              mode="navigate"
              shift
              ;;
            --print|-p)
              mode="print"
              shift
              ;;
            --copy|-y)
              mode="copy"
              shift
              ;;
            --contents|-c)
              search_tool="rg"
              shift
              ;;
            --contents-filtered|-f)
              search_tool="rg-filtered"
              shift
              ;;
            --root)
              if [[ -z "$2" || "$2" == -* ]]; then
                echo "Error: --root requires a directory path"
                return 1
              fi
              search_root="$2"
              shift 2
              ;;
            --no-preview)
              show_preview=false
              shift
              ;;
            --exact|-e)
              exact_match=true
              shift
              ;;
            --help|-h)
              echo "wheres — fuzzy find files/dirs or contents, then view/navigate/print/copy"
              echo ""
              echo "Usage: wheres [OPTIONS] [pattern/keyword]"
              echo ""
              echo "Options:"
              echo "  --view                 Show file contents (bat/head) or directory listing"
              echo "  --nav, --cd            Navigate (cd) to the selected item (default)"
              echo "  --print, -p            Print the selected path(s) to stdout"
              echo "  --copy, -y             Copy selected path(s) to the clipboard"
              echo "  --contents, -c         Search file contents using ripgrep (rg)"
              echo "  --contents-filtered, -f Search contents but truncate long lines (good for minified files)"
              echo "  --root DIR             Start search from DIR instead of current directory"
              echo "  --no-preview           Turn off the right-hand preview pane"
              echo "  --exact, -e            Treat the pattern as an exact match"
              echo "  --help, -h             Show this message"
              echo ""
              echo "Inside fzf:"
              echo "  Tab                    Toggle item selection (multi-select)"
              echo "  Ctrl+Y                 Exit fzf and immediately copy selection(s)"
              echo "  Enter                  Confirm selection(s)"
              echo ""
              echo "Examples:"
              echo "  wheres                 # fuzzy find files"
              echo "  wheres -c 'Version'    # search contents for 'Version'"
              echo "  wheres --root /etc -f 'boot' # search truncated contents in /etc"
              return 0
              ;;
            -*)
              echo "Unknown option: $1"
              echo "Use --help for usage information"
              return 1
              ;;
            *)
              break
              ;;
          esac
        done

        if [[ ! -d "$search_root" ]]; then
          echo "Error: Root directory '$search_root' does not exist"
          return 1
        fi

        # Base fzf command array 
        local fzf_cmd=(
          fzf
          --height 80%
          --border
          --multi
          --ansi
          --expect=ctrl-y
          --prompt "wheres ($search_root) > "
        )

        # If using rg, fzf needs to know fields are delimited by colons
        if [[ "$search_tool" != "fd" ]]; then
          fzf_cmd+=( --delimiter ':' )
        fi

        # Configure preview logic
        if [[ "$show_preview" == true ]]; then
          # For fd, {} is the whole path. For rg, {1} is the filename (due to delimiter).
          local target_var="{}"
          if [[ "$search_tool" != "fd" ]]; then
            target_var="{1}"
          fi

          fzf_cmd+=(
            --preview "[[ -d $target_var ]] && ls -la $target_var || if [[ \$(file --mime-type -b $target_var) == image/* ]]; then chafa $target_var 2>/dev/null || kitty +kitten icat $target_var 2>/dev/null || echo '[Image]'; else bat --style=plain --color=always --line-range :100 $target_var 2>/dev/null || head -100 $target_var; fi"
            --preview-window 'right:50%:wrap'
          )
        fi

        local search_pattern="''${1:-.}"
        if [[ "$exact_match" == true && "$search_pattern" != "." ]]; then
          search_pattern="^''${search_pattern}$"
        fi

        # Stream search tools directly into fzf
        local fzf_output
        if [[ "$search_tool" == "fd" ]]; then
          if ! fzf_output=$(fd -uu "$search_pattern" "$search_root" 2>/dev/null | "''${fzf_cmd[@]}"); then
            return 1
          fi
        elif [[ "$search_tool" == "rg" ]]; then
          if ! fzf_output=$(rg --color=always --line-number "$search_pattern" "$search_root" 2>/dev/null | "''${fzf_cmd[@]}"); then
            return 1
          fi
        elif [[ "$search_tool" == "rg-filtered" ]]; then
          if ! fzf_output=$(rg --color=always --line-number --max-columns 100 --max-columns-preview "$search_pattern" "$search_root" 2>/dev/null | "''${fzf_cmd[@]}"); then
            return 1
          fi
        fi

        # First line = key pressed to exit, remaining lines = selected paths
        local key
        key=$(echo "$fzf_output" | head -n 1)

        # Safely parse the selected paths into an array (Replaces the bugged (@f) mapfile logic)
        local -a targets=()
        while IFS= read -r line; do
          [[ -n "$line" ]] || continue
          
          # Clean rg's output (strip :line:content) or keep fd's output intact
          if [[ "$search_tool" != "fd" ]]; then
            targets+=("''${line%%:*}")
          else
            targets+=("$line")
          fi
        done <<< "$(echo "$fzf_output" | tail -n +2)"

        # Check if anything was selected
        if [[ "''${#targets[@]}" -eq 0 ]]; then
          echo "No selection made"
          return 1
        fi

        # Ctrl-Y inside fzf hijacks mode to copy
        if [[ "$key" == "ctrl-y" ]]; then
          mode="copy"
        fi

        # Smart override: >1 selection auto-switches to print (unless copying)
        if [[ "''${#targets[@]}" -gt 1 && "$mode" != "copy" ]]; then
          mode="print"
        fi

        # Act based on mode
        case "$mode" in
          print)
            for t in "''${targets[@]}"; do
              echo "$t"
            done
            ;;
          copy)
            printf "%s\n" "''${targets[@]}" | wl-copy 2>/dev/null || printf "%s\n" "''${targets[@]}" | xclip -selection clipboard 2>/dev/null
            for t in "''${targets[@]}"; do
              echo "$t"
            done
            ;;
          view)
            local target="''${targets[1]}"
            if [[ -d "$target" ]]; then
              ls -la "$target"
            else
              if command -v bat &> /dev/null; then
                bat --style=plain --color=always --line-range :100 "$target"
              else
                head -100 "$target"
              fi
            fi
            ;;
          navigate)
            local target="''${targets[1]}"
            if [[ -d "$target" ]]; then
              cd "$target" || return
              echo "Changed to: $PWD"
            else
              cd "$(dirname "$target")" || return
              echo "Changed to: $PWD (parent of $(basename "$target"))"
            fi
            ;;
        esac
      }

      perm() {
        stat -c "%a %n" "$@"
      }

      tdp() {
        /home/tower/archive-of-infinite-fold/tower-data-plain/
      }

      # Diff two NixOS generations: nix-diff 237 239 (or nix-diff 237 for current vs that gen)
      nix-diff() {
        local gen1="/nix/var/nix/profiles/system-$1-link"
        local gen2="''${2:+/nix/var/nix/profiles/system-$2-link}"
        gen2="''${gen2:-/run/current-system}"
        if [[ ! -e "$gen1" ]]; then
          echo "Generation $1 not found"; return 1
        fi
        echo "=== Comparing $(basename $gen1) vs $(basename $gen2) ==="
        echo ""
        echo "--- Kernel Params ---"
        diff --color=always -u <(cat "$gen1/kernel-params" 2>/dev/null | tr ' ' '\n' | sort) \
                               <(cat "$gen2/kernel-params" 2>/dev/null | tr ' ' '\n' | sort) | grep -E '^[-+]' | grep -v '^[-+]{3}'
        echo ""
        echo "--- Kernel Version ---"
        diff --color=always -u <(ls -la "$gen1/kernel" 2>/dev/null) <(ls -la "$gen2/kernel" 2>/dev/null) | grep -E '^[-+]' | grep -v '^[-+]{3}'
        echo ""
        echo "--- initrd Changes ---"
        diff --color=always -u <(ls -la "$gen1/initrd" 2>/dev/null) <(ls -la "$gen2/initrd" 2>/dev/null) | grep -E '^[-+]' | grep -v '^[-+]{3}'
        echo ""
        echo "--- System Packages (first 20 diffs) ---"
        diff --color=always -u <(ls "$gen1/sw/bin" 2>/dev/null | head -100) <(ls "$gen2/sw/bin" 2>/dev/null | head -100) | grep -E '^[-+]' | grep -v '^[-+]{3}' | head -20
      }
    '';
  };

#  programs.starship.enable = true;
  programs.atuin.enable = true;
}
