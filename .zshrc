export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/towerstack/scripts:$HOME/.lmstudio/bin:$PATH"
export EDITOR="gram"
export AICHAT_ENV_FILE="$HOME/.secrets/lms.env"   # aichat reads LMSTUDIO_API_KEY from here

# ============================================================
# History  (was: histSize = 10000, setOptions)
# ============================================================
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt EXTENDED_HISTORY
setopt NO_CHECK_JOBS
setopt NO_HUP
setopt HIST_IGNORE_SPACE
setopt SHARE_HISTORY

export STARSHIP_CONFIG="$HOME/.config/starship.toml"

# MOTD once per session (was in tower's initContent)
if [[ $SHLVL -eq 1 && -z "$MOTD_SHOWN" ]]; then
    export MOTD_SHOWN=1
    ~/towerstack/scripts/tower-motd.sh
fi

# ============================================================
# Oh My Zsh  (was: ohMyZsh = { ... })
# ============================================================
export ZSH="$HOME/services/shell-configs/.oh-my-zsh"
ZSH_THEME=""            # empty on purpose — prompt is starship's job
plugins=(
 extract
  fzf
  git
  history-substring-search
  man
  python
  sudo
  z
 # must be cloned into custom plugins (see below)
  zsh-syntax-highlighting   # MUST be last in this list
  alias-finder
  copypath
)

# OMZ behavior vars — MUST be set before sourcing oh-my-zsh.sh
HIST_STAMPS="mm/dd/yyyy"
ENABLE_CORRECTION="false"
COMPLETION_WAITING_DOTS="true"
zstyle ':omz:update' mode reminder

# aichat completions — before OMZ, because OMZ runs compinit
fpath=(~/.zsh/completions $fpath)

source "$ZSH/oh-my-zsh.sh"

PROMPT_EOL_MARK=""

# ============================================================
# Aliases  (was: shellAliases)
# ============================================================
# AI terminal assistant (aichat -> LM Studio)
alias ai="aichat"
alias wtf="aichat -e"      # Shell command mode
alias dafuq="aichat -e"    # Shell command mode
alias yo="aichat"          # Conversational mode
alias hf-download="huggingface-cli download"

# AI agent orchestration
alias og="cd ~/towerstack/OGnee"
alias ognee="cd ~/towerstack/OGnee && nix-shell --run 'python3 -m backend.ognee'"

# vLLM cluster
alias vllm-up="~/towerstack/vllm-cluster/start-cluster.sh"
alias vllm-down="~/towerstack/vllm-cluster/stop-cluster.sh"
alias vllm-logs="docker logs -f vllm-head"
alias vllm-status="curl -s http://192.168.50.139:8000/v1/models | jq ."
alias ray-dash='echo "Ray Dashboard: http://192.168.50.140:8265"'

# AI NixOS file access - LM Studio (/sata/etc/*)
alias sata-sync="sudo rsync -rtv --copy-links --exclude='result' /etc/nixos/ /sata/etc/nixos/"

# Audio debugging
alias restart-audio="systemctl --user restart pipewire pipewire-pulse wireplumber"
alias audio-status="pw-top"
alias jack-list="pw-jack jack_lsp -c"

# Bluetooth toggle (KDE Connect freaks out when Razer dongle is unplugged)
alias bt-off="sed -i 's/bluetoothEnabled=.*/bluetoothEnabled=false/' ~/.config/kdeconnect/config && kquitapp6 kdeconnectd 2>/dev/null; sleep 1; kdeconnectd &>/dev/null &disown && echo 'BT discovery off'"
alias bt-on="sed -i 's/bluetoothEnabled=.*/bluetoothEnabled=true/' ~/.config/kdeconnect/config && kquitapp6 kdeconnectd 2>/dev/null; sleep 1; kdeconnectd &>/dev/null &disown && echo 'BT discovery on'"

# Browsers
alias chrome="tmux && sleep 3 && cd ~/towerstack/scripts/ninja-chrome && nix-shell && shleep 2 && ctrl+b && sleep 1 && d"

# Crash tracker for MOTD
alias log-crash="/home/tower/towerstack/scripts/log-crash.sh"
alias motd="/home/tower/towerstack/scripts/tower-motd.sh"

# Podman
alias dc="podman compose"
alias dps="podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
alias dlogs="podman logs -f"

# Existing
alias ghost="/home/tower/towerstack/scripts/ghost"
alias h="hist"

# GPU monitoring
alias gpumon="watch -n 1 nvidia-smi"

# Kitty window switcher
alias kitty-gate="kitty-gatekeeper"

# KWin phantom display fix (immutable config file)
alias unlock-screens="sudo chattr -i ~/.config/kwinoutputconfig.json && echo 'Unlocked. You can now arrange monitors.'"
alias lock-screens="sudo chattr +i ~/.config/kwinoutputconfig.json && echo 'Locked. Phantom displays blocked.'"

# Log checking
alias errors="sudo journalctl -p err --since '24 hours ago' --no-pager | head -50"
alias errors-live="sudo journalctl -p err -f"

# MCPO
alias logs-mcpo="sudo journalctl -u mcpo -f"
alias start-mcpo="sudo systemctl start mcpo"
alias start-mcpo-l="sudo systemctl start mcpo && sudo journalctl -u mcpo -f"
alias stop-mcpo="sudo systemctl stop mcpo"  
alias status-mcpo="sudo systemctl status mcpo"
alias restart-mcpo="sudo systemctl restart mcpo"
alias restart-mcpo-l="sudo systemctl restart mcpo && sudo journalctl -u mcpo -f" 

# Navigation
alias br="cat ~/cheatsheets/echo/bash-ready-ls/br.txt && cat ~/cheatsheets/echo/bash-ready-ls/br-cmd.txt | wl-copy"
alias user-logs="cd /data/aoif/data-pile/logs-user"
alias home="cd /etc/nixos/home/tower"

# Plasma
alias save-taskbar="sudo save-panel-layout.sh"

# Speech-to-text (Nemo stt on Titan)
alias stt="cd ~/tools/stt && nix-shell --run './stt'"
alias stt-pick="cd ~/tools/stt && ./stt --pick"
alias stt-mics="cd ~/tools/stt && nix-shell --run './list-mics'"

# Text-to-speech (Chatterbox on Titan)
alias tts="/home/tower/tools/tts/tts.sh"

# Stack management (vLLM beast mode vs daily driver)
alias stack="/home/tower/towerstack/scripts/stack"
alias vllm="/home/tower/towerstack/vllm-cluster/vllm.sh"

# SSH (note: each machine's config pointed at the other — all four kept)
alias tower="ssh dacrib@192.168.50.140"
alias dacrib="ssh dacrib@192.168.50.141"
alias titan="ssh titan@192.168.50.103"
alias merk="ssh merk@192.168.50.199"

# Services
alias start-wg="sudo systemctl start wg-quick-wg0"
alias restart-wg="sudo systemctl restart wg-quick-wg0"
alias status-wg="sudo systemctl status wg-quick-wg0"
alias stop-wg="sudo systemctl stop wg-quick-wg0"
alias fix-pi="ssh -t dacrib@192.168.50.141 '$HOME/scripts/fix-pi'"

# System
alias disp="sudo cp ~/display-config.json ~/.config/kwinoutputconfig.json && qdbus org.kde.KWin /KWin org.kde.KWin.reconfigure"
alias dry-run="sudo nixos-rebuild dry-activate --flake /etc/nixos#\$(hostname)"
alias ir="input-remapper-control --command start --device 'Keychron Keychron Ultra-Link 8K' --preset 'try-3'"
alias irr="input-remapper-control --command start --device 'Keychron Keychron Ultra-Link 8K' --preset 'mouse-buttons'"
alias ir-wired="input-remapper-control --command start --device 'Keychron Keychron M6 8K' --preset 'wired-keychron-mouse'"
alias nix-prune="sudo ~/towerstack/scripts/nix-prune-v1_1.sh"
alias reboot="echo '💾 Remember to backup vault: ~/towerstack/scripts/vault-backup.sh' && cd ~/towerstack/scripts && ./lock.sh && ./lock-data-pile.sh && sudo reboot"
alias restart-plasma="pkill plasmashell; sleep 1; plasmashell &"
alias shutdown="echo '💾 Remember to backup vault: ~/towerstack/scripts/vault-backup.sh' && cd ~/towerstack/scripts && ./lock.sh && ./lock-data-pile.sh && sudo shutdown now"

# Immich
alias start-immich="sudo systemctl start podman-immich-{valkey,postgres,server,ml}"
alias stop-immich="sudo systemctl stop podman-immich-{valkey,postgres,server,ml}"
alias status-immich-server="sudo systemctl status podman-immich-server"
alias status-immich="sudo systemctl status podman-immich-{valkey,postgres,server,ml}"
alias restart-immich-ml="sudo systemctl stop podman-immich-ml && sudo systemctl start podman-immich-ml"
alias restart-immich-valkey="sudo systemctl stop podman-immich-valkey && sudo systemctl start podman-immich-valkey"
alias restart-immich-db="sudo systemctl stop podman-immich-postgres && sudo systemctl start podman-immich-postgres"
alias restart-immich-server="sudo systemctl stop podman-immich-server && sudo systemctl start podman-immich-server"
alias restart-immich="sudo systemctl stop podman-immich-{valkey,postgres,server,ml} && sudo systemctl start podman-immich-{valkey,postgres,server,ml}"
alias logs-immich-valkey="sudo journalctl -u podman-immich-valkey -f"
alias logs-immich-server="sudo journalctl -u podman-immich-server -f"
alias logs-immich-postgres="sudo journalctl -u podman-immich-postgres -f"
alias logs-immich-ml="sudo journalctl -u podman-immich-ml -f"

# Fish (GPU services)
alias stop-fish="sudo systemctl stop podman-fish-gpu0.service podman-fish-gpu1.service"
alias start-fish-0="sudo systemctl start podman-fish-gpu0.service"
alias start-fish-0-l="sudo systemctl start podman-fish-gpu0.service && sudo journalctl -u fish-gpu0 -f"
alias stop-fish-0="sudo systemctl stop podman-fish-gpu0.service"
alias status-fish-0="sudo systemctl status podman-fish-gpu0.service"
alias logs-fish-0="sudo journalctl -u podman-fish-gpu0.service -f"
alias restart-fish-0="sudo systemctl stop podman-fish-gpu0.service && sudo systemctl start podman-fish-gpu0.service"
alias start-fish-1="sudo systemctl start podman-fish-gpu1.service"
alias start-fish-1-l="sudo systemctl start podman-fish-gpu1.service && sudo journalctl -u podman-fish-gpu1.service -f"
alias stop-fish-1="sudo systemctl stop podman-fish-gpu1.service"
alias status-fish-1="sudo systemctl status podman-fish-gpu1.service"
alias logs-fish-1="sudo journalctl -u podman-fish-gpu1.service -f"
alias restart-fish-1="sudo systemctl stop podman-fish-gpu1.service && sudo systemctl start podman-fish-gpu1.service"

# Open WebUI
alias start-owui="sudo systemctl start open-webui"
alias start-owui-l="sudo systemctl start open-webui && sudo journalctl -u open-webui -f"
alias stop-owui="sudo systemctl stop open-webui"
alias status-owui="sudo systemctl status open-webui"
alias restart-owui="sudo systemctl stop open-webui && sudo systemctl start open-webui"
alias logs-owui="sudo journalctl -u open-webui -f"

# Chatterbox
alias start-chatterbox="sudo systemctl start podman-chatterbox.service"
alias start-chatterbox-l="sudo systemctl start podman-chatterbox.service && sudo journalctl -u podman-chatterbox.service -f"
alias stop-chatterbox="sudo systemctl stop podman-chatterbox.service"
alias status-chatterbox="sudo systemctl status podman-chatterbox.service"
alias restart-chatterbox="sudo systemctl stop podman-chatterbox.service && sudo systemctl start podman-chatterbox.service"
alias logs-chatterbox="sudo journalctl -u podman-chatterbox.service | tail -n 40"
alias logs-live-chatterbox="sudo journalctl -u podman-chatterbox.service -f"

# Vault controls
alias unlock-data="~/towerstack/scripts/unlock-data-pile.sh"
alias lock-data="~/towerstack/scripts/lock-data-pile.sh"

# ============================================================
# ZLE / keybindings  (after OMZ so they aren't overwritten)
# ============================================================
bindkey '^K' kill-whole-line

# aichat: Alt+E expands buffer into a shell command
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

# ============================================================
# Functions  (was: interactiveShellInit, escapes resolved)
# ============================================================

# MSI RGB control
rgb() { python3 ~/towerstack/scripts/msi-rgb.py "$@"; }

# Unlock vault and start stack, then return to original directory
dcu() {
  local prev="$PWD"
  echo '💾 Remember to backup vault: ~/towerstack/scripts/vault-backup.sh'
  cd ~/towerstack/scripts && ./unlock.sh
  cd "$prev"
}

# Stop stack and lock vault, then return to original directory
dcd() {
  local prev="$PWD"
  cd ~/towerstack/scripts && ./lock.sh
  echo '💾 Remember to backup vault: ~/towerstack/scripts/vault-backup.sh'
  cd "$prev"
}

# Start the llm-functions MCP bridge if it's down (it doesn't survive reboots)
_mcp_bridge_up() {
  curl -fsS --max-time 2 http://localhost:8808/health >/dev/null 2>&1 && return 0
  [[ -d ~/tools/llm-functions ]] || return 1
  echo "⏳ starting MCP bridge..." >&2
  ~/tools/mcp-servers/aichat-mcp-start.sh >/dev/null 2>&1
}

# halp: aichat + web search + read-only file tools (role: ~/.config/aichat/roles/halp.md)
halp() {
  local context="Current directory: $PWD
Recent commands:
$(fc -ln -20)

Question: $*"
  _mcp_bridge_up || echo "⚠️  MCP bridge not running, no tools this time" >&2
  echo "$context" | LLM_MCP_SKIP_CONFIRM='web_search_searxng_web_search|web_search_web_url_read|local_files_read_file|local_files_read_multiple_files|local_files_list_directory|local_files_directory_tree|local_files_search_files|local_files_get_file_info|local_files_list_allowed_directories' \
    aichat -r halp 2>/dev/null | sed '/<think>/,/<\/think>/d; /<think>/,$d'
}

halpdo() {
  local context="Current directory: $PWD
Recent commands:
$(fc -ln -10)

Task: $*"
  echo "$context" | aichat -e 2>/dev/null | sed '/<think>/,/<\/think>/d; /<think>/,$d'
}

nix-switch () {
	local skip_diff=0
	[[ "$1" == "-y" || "$1" == "--skip" ]] && skip_diff=1

	if (( ! skip_diff )); then
		echo "=== Changes ==="
		( cd /etc/nixos && sudo git status --short && sudo git diff --color | less -R )
		read -t 0.1 -n 10000 discard 2>/dev/null
		echo ""
		read "?Press Enter to build (Ctrl+C to abort)..."
	fi

	# Stage so the flake can see new files (not a commit)
	( cd /etc/nixos && sudo git add -A )

	nh os switch
	local build_status=$?
	if (( build_status != 0 )); then
		echo ""
		echo "❌ Build failed (exit $build_status). No backup, no commit, no push."
		return $build_status
	fi

	local gen stamp backup msg
	gen=$(readlink /nix/var/nix/profiles/system | sed -n 's/.*system-\([0-9]*\)-link/\1/p')
	[[ -z "$gen" ]] && gen=0
	stamp="$(date +%Y-%m-%d-%H%M%S)"
	backup="$HOME/configuration-nix-backups/gen${gen}-${stamp}"
	msg="gen${gen} - $(date '+%Y-%m-%d %H:%M:%S')"
	mkdir -p "$HOME/configuration-nix-backups"
	sudo rsync -a --copy-links --exclude='.git' --exclude='.gitignore' /etc/nixos/ "$backup/"
	sudo chown -R tower:users "$backup"
	sudo chmod -R u=rwX,g=rX,o= "$backup"

	echo ""
	echo "✅ Build succeeded."
	echo "📁 Backed up to: $backup"
	( cd /etc/nixos && sudo git commit -q -m "$msg" ) && echo "📝 Committed as gen${gen}"
	echo ""
	echo "🔄 Pushing all repos to Gitea..."
	~/towerstack/scripts/gitall.sh "$msg"
}

# HEIC to PNG - parallel batch conversion (uses all cores)
heic2png() {
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
  rsync -avP "$1" titan@192.168.50.103:"${2:-.}"
}

# Get file from Titan: from-titan <remote-path> [local-path]
from-titan() {
  rsync -avP titan@192.168.50.103:"$1" "${2:-.}"
}

# Fuzzy find files
ff() {
  find "${1:-.}" 2>/dev/null | fzf
}

hist() {
    local limit=200
    if [[ -n "$1" ]]; then
        limit=${1#[-+]}
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
            if   (( diff < 60 ));    then rel="${diff}sec"
            elif (( diff < 3600 ));  then rel="$((diff/60))min"
            elif (( diff < 86400 )); then rel="$((diff/3600))hr"
            else                          rel="$((diff/86400))d"
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
  dir=$(find ${1:-.} -type d 2>/dev/null | fzf --preview 'ls -la {}' --height 40%) && cd "$dir"
}

# Clean attribute finder for system packages
nix-find() {
  nix search nixpkgs "$1" 2>/dev/null | grep '^\*' | sed -E 's/^\* [^.]+\.[^.]+\.//' | awk '{print $1}'
}

rm() {
    local skip=false
    local rm_flags=()
    local args=()
    for arg in "$@"; do
        case "$arg" in
            --no-trash|--skip-trash|-s)
                skip=true
                ;;
            -*)
                rm_flags+=("$arg")
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done

    if $skip; then
        command rm "${rm_flags[@]}" "${args[@]}"
    else
        trash-put "${args[@]}" 2>/dev/null || {
            echo "trash-put failed (cross-volume?), fall back to rm? [y/N]"
            read -q && command rm "${rm_flags[@]}" "${args[@]}"
            echo
        }
    fi
}

# Navigation - appendable path shortcuts
aoif  () { cd /home/tower/archive-of-infinite-fold/tower-data-plain/"$@"; }
dp    () { cd /data/aoif/data-pile/"$@"; }
aoiff () { echo /home/tower/archive-of-infinite-fold/tower-data-plain/"$@"; }
dpp   () { echo /data/aoif/data-pile/"$@"; }
nixx  () { cd /etc/nixos/"$@"; }
nx    () { echo /etc/nixos/"$@"; }

gitt() { git add -A && git commit -m "${1:-update}" && git push; }

perm() {
  for arg in "$@"; do
    if [[ -d "$arg" ]]; then
      sudo find "$arg" -maxdepth 1 ! -path "$arg" -exec stat -c '%a %A %U %n' {} +
    else
      sudo stat -c '%a %A %U %n' "$arg"
    fi
  done
}

treee() {
  command tree -I 'udev' -I 'sys' -I 'data-pile-cipher' -I 'dev' -I 'yazi-1000' -I 'V9oqsqNrkTxMqorpwHQ3jK0ZZ9jYNOMwzNDqllEO7ZnVPZ3KVwWzVQ8biSSntM9G' -I '*microsoft*' -I 'cpu' -I 'gmi*' -I 'ext4' -I 'hypervisor' -I 'module' -I 'mm' -I 'store*' -I 'Modelfile*' -I 'lm-studio*' -I 'library*' -I 'working-directories*' -I 'workspace*' -I '*directory' -I 'sillytavern' -I 'cache-data*' -I 'uploads*' -I 'Cache*' -I 'default-user*' -I '_Data*' -I 'blob*' -I 'conversations*' -I '*log' -I '*ts' -I 'kscreen*' -I 'external-tools*' -I 'sfpbeiqs.default*' -I 'session_*' -I 'klipper' -I '*metadata.json' -I '*m4a' -I 'scalable' -I '*mp4*' -I 'tower-data-cipher*' -I 'file-*' -I 'log*' -I '*wav' -I 'icons' -I 'chatgpt-data-dump*' -I 'qmk_firmware' -I 'extensions' -I 'C-scrollstack' -I 'css' -I 'font' -I 'AI stuff' -I 'plugins' -I 'Takeout' -I 'shell-snapshots' -I 'Gemini Apps' -I '-home-tower-towerstack' -I 'debug*' -I 'image-*' -I '*agent*' -I 'paste-cache' -I 'image-cache' -I '??????????????.json*' -I '????-????????????.*'  -I 'speech' -I '???????????????????????????.*' -I '*.jpg' -I '*jpeg' -I 'comfy*' -I '__pycache__' -I '*venv*' -I 'dist' -I 'node_modules' -I '.esphome' -I 'phoronix*' -I 'ComfyUI' -I 'converations' -I 'christmas*' -I '*.png' -I '*apple*' -I 'icloud*' -I 'icloud' -I 'binary*' -I '?????????????????????????' -I '*????????-????-????-????' -I '????????-????-????-????-????????????' -I '????????-????-????-????-????????????' --ignore-case  "$@"
}


# Diff two NixOS generations: nix-diff 237 239 (or nix-diff 237 for current vs that gen)
nix-diff() {
  local gen1="/nix/var/nix/profiles/system-$1-link"
  local gen2="${2:+/nix/var/nix/profiles/system-$2-link}"
  gen2="${gen2:-/run/current-system}"
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

bash-ready() {
    local help_flag=false
    local args=()

    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                help_flag=true
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done

    if [[ "$help_flag" == true ]]; then
        echo "Usage: bash-ready [OPTIONS] [PATTERN]"
        return 0
    fi

    local pattern="${args[0]:-.*}"

    # Skip first line (ls total), use -v to safely pass regex, print with quotes
    ls --color=never -lt --time-style=long-iso | awk 'NR>1' | awk -v p="$pattern" '$NF ~ p {print $NF "\"" }'
}

bash-ready-ls() {
    local help_flag=false
    local filter_pattern=""
    local args=()

    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                help_flag=true
                ;;
            *)
                args+=("$arg")
                ;;
        esac
    done

    if [[ "$help_flag" == true ]]; then
        echo "Usage: bash-ready-ls [OPTIONS] [PATTERN]"
        return 0
    fi

    if [[ ${#args[@]} -eq 0 ]]; then
        filter_pattern=".*"
    else
        filter_pattern="${args[0]}"
    fi

    # Skip first line (ls total), use -v to safely pass regex, print with quotes
    ls --color=never -lt --time-style=long-iso | awk 'NR>1' | awk -v p="$filter_pattern" '$NF ~ p {print $NF " \\\" }'
}


# ============================================================
# Prompt & history search  (was: programs.starship / programs.atuin)
# ============================================================
eval "$(starship init zsh)"
eval "$(atuin init zsh)"

# Plasmoid: plasmallm
alias logs-pllm="journalctl -n 30 --since '1 hour ago' | grep plasmallm"
alias restart-pllm-l="pkill plasmashell; sleep 1; plasmashell & journalctl -f | grep plasmallm"
