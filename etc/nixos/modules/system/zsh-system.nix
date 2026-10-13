{ config, pkgs, lib, ... }:
{
  programs.zsh.enable = true;
  programs.zsh.autosuggestions.enable = true;
  programs.zsh.syntaxHighlighting.enable = true;

  programs.zsh.loginShellInit = ''
    # Only show MOTD for interactive login shells (not scp, rsync, etc)
    [[ -o interactive ]] && /home/tower/towerstack/scripts/tower-motd.sh
  '';

  environment.sessionVariables = {
    LIBINPUT_POINTER_SCROLL_FACTOR = "3.0";
  };

  # NixOS generation management aliases (system-wide)

  environment.shellAliases = {

    #=======================================================#
    # AI                                                      #
    #============================================================#
    ai          = "aichat                  ";                       # <--
    wtf         = "aichat -e               ";  # Shell command  mode   # <--
    dafuq       = "aichat -e               ";  # Shell command  mode      # <--
    yo          = "aichat                  ";  # Conversational mode         # <--
    hf-download = "huggingface-cli download";                                   # <--
    og          = "cd ~/towerstack/OGnee   ";                                      # <--
    ognee       = "cd ~/towerstack/OGnee && nix-shell --run 'python3 -m backend.ognee'"; # <-- 
                                                                                              # 
    # AI NixOS file access - LM Studio (/sata/etc/*)                                              #
    sata-sync = "sudo rsync -rtv --copy-links --exclude='result' /etc/nixos/ /sata/etc/nixos/";       #  <--
                                                                                                          #  
    #===================================================================                                      #  
    # Chatterbox                                                                                                  #  
    #===================================================================                                               #   
    start-chatterbox     = "sudo systemctl start podman-chatterbox.service                                                     ";
    start-chatterbox-l   = "sudo systemctl start podman-chatterbox.service && sudo journalctl -u podman-chatterbox.service -f  ";
    stop-chatterbox      = "sudo systemctl stop podman-chatterbox.service                                                      ";
    status-chatterbox    = "sudo systemctl status podman-chatterbox.service                                                    ";
    restart-chatterbox   = "sudo systemctl restart podman-chatterbox.service                                                   ";
    restart-chatterbox-l = "sudo systemctl restart podman-chatterbox.service && sudo journalctl -u podman-chatterbox.service -f";
    logs-chatterbox      = "sudo journalctl -u podman-chatterbox.service | tail -n 40                                          ";
    logs-live-chatterbox = "sudo journalctl -u podman-chatterbox.service -f                                                    ";        
                                                                                                                                ##        
                                                                                                                                ##        
    #=======================================================================================                                    ##         
    # Fish speech                                                                                                               ##  
    #=======================================================================================                                    ##    
    stop-fish              = "sudo systemctl stop podman-fish-gpu0.service podman-fish-gpu1.service                             ";
    start-fish-0           = "sudo systemctl start podman-fish-gpu0.service                                                     ";
    start-fish-0-l         = "sudo systemctl start podman-fish-gpu0.service && sudo journalctl -u fish-gpu0 -f                  ";
    stop-fish-0            = "sudo systemctl stop podman-fish-gpu0.service                                                      ";
    status-fish-0          = "sudo systemctl status podman-fish-gpu0.service                                                    ";
    logs-fish-0            = "sudo journalctl -u podman-fish-gpu0.service -f                                                    ";
    restart-fish-0         = "sudo systemctl restart podman-fish-gpu0.service                                                   ";
    restart-fish-0-l       = "sudo systemctl restart podman-fish-gpu0.service && sudo journalctl -u podman-fish-gpu0.service -f ";
    start-fish-1           = "sudo systemctl start podman-fish-gpu1.service                                                     ";
    start-fish-1-l         = "sudo systemctl start podman-fish-gpu1.service && sudo journalctl -u podman-fish-gpu1.service -f   ";
    stop-fish-1            = "sudo systemctl stop podman-fish-gpu1.service                                                      ";
    status-fish-1          = "sudo systemctl status podman-fish-gpu1.service                                                    ";
    logs-fish-1            = "sudo journalctl -u podman-fish-gpu1.service -f                                                    ";
    restart-fish-1         = "sudo systemctl stop podman-fish-gpu1.service && sudo systemctl start podman-fish-gpu1.service     ";
    restart-fish-1-l       = "sudo systemctl restart podman-fish-gpu1.service && sudo journalctl -u podman-fish-gpu1.service -f ";    
                                                                                              ##                                #                                                                                                                                                                               
    #=========================================================================================##                          #
    # Immich                                                                                  ##                  #
    #=========================================================================================##          #
    start-immich           = "sudo systemctl start podman-immich-{valkey,postgres,server,ml}  ";   # <--
    stop-immich            = "sudo systemctl stop podman-immich-{valkey,postgres,server,ml}   ";
    # Immich status                                                                           ##
    status-immich          = "sudo systemctl status podman-immich-{valkey,postgres,server,ml} ";
    status-immich-server   = "sudo systemctl status podman-immich-server                      ";
    status-immich-ml       = "sudo systemctl status podman-immich-ml                          ";
    status-immich-valkey   = "sudo systemctl status podman-immich-                            ";
    status-immich-postgres = "sudo systemctl status podman-immich-postgres                    ";
    # Immich restarts                                                                         ##
    restart-immich         = "sudo systemctl restart podman-immich-{valkey,postgres,server,ml}";
    restart-immich-ml      = "sudo systemctl restart podman-immich-ml                         ";
    restart-immich-valkey  = "sudo systemctl restart podman-immich-valkey                     ";
    restart-immich-db      = "sudo systemctl restart podman-immich-postgres                   ";
    restart-immich-server  = "sudo systemctl restart podman-immich-server                     ";
    # Immich logs                                                                             ##
    logs-immich-valkey     = "sudo journalctl -u podman-immich-valkey -f                      ";
    logs-immich-server     = "sudo journalctl -u podman-immich-server -f                      ";
    logs-immich-postgres   = "sudo journalctl -u podman-immich-postgres -f                    ";
    logs-immich-ml         = "sudo journalctl -u podman-immich-ml -f                          ";
                                                                                              ##
    #===========================================================                              ##
    # Audio debugging                                                                         ##
    #===========================================================                              ##
    audio-status            = "pw-top                                                         "; 
    jack-list               = "pw-jack jack_lsp -c                                            ";
    restart-audio           = "systemctl --user restart pipewire pipewire-pulse wireplumber   ";
                                                                                              ## 
    #===========================================================                              ##     
    # Bluetooth toggle                                                                        ##
    #===========================================================                              ##
    bt-off = "sed -i 's/bluetoothEnabled=.*/bluetoothEnabled=false/' ~/.config/kdeconnect/config && kquitapp6 kdeconnectd 2>/dev/null; sleep 1; kdeconnectd &>/dev/null &disown && echo 'BT discovery off'";
    bt-on  = "sed -i 's/bluetoothEnabled=.*/bluetoothEnabled=true/' ~/.config/kdeconnect/config && kquitapp6 kdeconnectd 2>/dev/null; sleep 1; kdeconnectd &>/dev/null &disown && echo 'BT discovery on'  ";
                                                                         ##                                              #           
    #===========================================================         ##                                              #           
    # Browsers                                                           ##                                              #           
    #===========================================================         ##                                              #           
    chrome = "tmux && sleep 3 && cd ~/towerstack/scripts/ninja-chrome && nix-shell && shleep 2 && ctrl+b && sleep 1 && d";           
                                                                         ##                                             #     
                                                                         ##                                          #
    #===========================================================         ##                                   #                       
    # Config editing                                                     ##                            #
    #===========================================================         ##                     #
                                                                         ##             #
    # NixOS          /etc/nixos/                                         ##     #
    # nixx           = definded as function in ~/.zshrc                  ##
    flake            = "micro /etc/nixos/flake.nix                       ";    
    hardware-config  = "micro /etc/nixos/hardware-configuration.nix      ";   
    hardware         = "micro /etc/nixos/hosts/hardware.nix              "; 
    pkgs             = "micro /etc/nixos/packages.nix                    ";   
    shelll           = "micro /etc/nixos/shell.nix                       ";  
                                                                         ##
                                                                         ##
    # Hosts          /etc/nixos/hosts/                                   ##
    hosts            = "cd /etc/nixos/hosts                              "; 
    booot            = "micro /etc/nixos/hosts/boot.nix                  ";
    hosts-default    = "micro /etc/nixos/hosts/default.nix               ";
    filesystems      = "micro /etc/nixos/hosts/filesystems.nix           ";
    networking       = "micro /etc/nixos/hosts/networking.nix            ";
    users            = "micro /etc/nixos/hosts/users.nix                 ";
                                                                         ##
    # Modules -      /etc/nixos/modules/packages/                        ##
    packages         = "cd /etc/nixos/modules/packages                   ";
    development      = "micro /etc/nixos/modules/packages/development.nix";
    system-config    = "micro /etc/nixos/modules/packages/system.nix     ";
                                                                         ##
    # Overlays       /etc/nixos/overlays/                                ##
    overlays         = "cd /etc/nixos/overlays                           ";
    overlays-default = "micro /etc/nixos/overlays/default.nix            ";  
    gramm            = "micro /etc/nixos/overlays/gram.nix               ";  
    ladybirdd        = "micro /etc/nixos/overlays/ladybird.nix           ";  
    lmss             = "micro /etc/nixos/overlays/lmstudio.nix           ";  
    nvidia           = "micro /etc/nixos/overlays/nvidia-595-stable.nix  ";  
    olammaa          = "micro /etc/nixos/overlays/ollama.nix             ";  
    owui             = "micro /etc/nixos/overlays/owui.nix               ";  
    pyy312           = "micro /etc/nixos/overlays/python312-doc-fix.nix  ";
    pyy314           = "micro /etc/nixos/overlays/python314-doc-fix.nix  ";  
                                                                         ##
    # Services       /etc/nixos/modules/services/                        ##
    services        = "cd /etc/nixos/modules/services                    ";                    
    ai-stack        = "micro /etc/nixos/modules/services/ai-stack        ";
    caddy           = "micro /etc/nixos/modules/services/caddy.nix       ";       
    duckdns         = "micro /etc/nixos/modules/services/duckdns.nix     ";
    gitea           = "micro /etc/nixos/modules/services/gitea.nix       ";
    immich          = "micro /etc/nixos/modules/services/immich.nix      "; 
    mcpo            = "micro /etc/nixos/modules/services/mcpo.nix        ";
    openclaw        = "micro /etc/nixos/modules/services/openclaw.nix    ";
    searxng         = "micro /etc/nixos/modules/services/searxng.nix     ";
    sshh            = "micro /etc/nixos/modules/services/ssh.nix         ";
                                                                         ##
    # System         /etc/nixos/modules/system/                          ##
    system          = "/etc/nixos/modules/system                         ";
    audioo          = "micro /etc/nixos/modules/system/audio.nix         ";   
    desktop         = "micro /etc/nixos/modules/system/desktop.nix       ";   
    gaming          = "micro /etc/nixos/modules/system/gaming.nix        ";   
    journald        = "micro /etc/nixos/modules/system/journald.nix      ";   
    monitoring      = "micro /etc/nixos/modules/system/monitoring.nix    ";                       
    nhh             = "micro /etc/nixos/modules/system/nh.nix            ";   
    power           = "micro /etc/nixos/modules/system/power.nix         ";   
    printing        = "micro /etc/nixos/modules/system/printing.nix      ";   
    security        = "micro /etc/nixos/modules/system/security.nix      ";   
    udev            = "micro /etc/nixos/modules/system/udev.nix          ";   
    wheress         = "micro /etc/nixos/modules/system/wheres.nix        ";   
    zsh-system      = "micro /etc/nixos/modules/system/zsh-system.nix    ";   
                                                                         ##
    #===========================================================         ##
    # Crash tracker for MOTD                                             ##
    #===========================================================         ##
    log-crash       = "/home/tower/towerstack/scripts/log-crash.sh       ";
    motd            = "/home/tower/towerstack/scripts/tower-motd.sh      ";
                                                                         ##     
    # Podman                                                             ##            
    dps             = "sudo podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'";      # <--
    dlogs           = "sudo podman logs -f                                                ";              # <--
                                                                                          ##                     #
    # Existing                                                                            ##                             #
    ghost           = "/home/tower/towerstack/scripts/ghost                               ";                                    # <--
                                                                                          ##                                            #
  # GPU monitoring                                                                        ##                                                     #
    gpumon          = "watch -n 1 nvidia-smi                                              ";                                                             # <--
##    towermon        = "cd ~/towerstack/system-monitor && nix-shell -p                    \
##                       'python3.withPackages (ps: with ps; [psutil rich])'               \
##                        --run 'python3 towermon_terminal.py'                            ";
#    towermon-widget = "~/towerstack/system-monitor/run-widget.sh                         ";                                                                             # <--  
#    towermon-status = "systemctl status towermon                                         ";                                                                        # <--
                                                                                          ##                                                                    #
  # Kitty window switcher                                                                 ##                                                               #
    kitty-gate = "kitty-gatekeeper                                                        ";                    
                                                                                          ##                                                 
  # KWin phantom display fix (immutable config file)                                      ##
    unlock-screens = "sudo chattr -i ~/.config/kwinoutputconfig.json &&                    \
                      echo 'Unlocked. You can now arrange monitors.'                      "; 
    lock-screens   = "sudo chattr +i ~/.config/kwinoutputconfig.json &&                    \
                      echo 'Locked. Phantom displays blocked.'                            ";
                                                                                          ##
    #===========================================================                          ##
    # Database                                                                            ##
    #===========================================================                          ##
    backup-db = "cat /home/tower/cheatsheets/echo/backup-db/backup-db.txt &&               \
                 cat /home/tower/cheatsheets/echo/backup-db/backup-db-cmd.txt | wl-copy   ";
                                                                                          ##
    #===========================================================                          ##
    # Diagnose/Identify                                                                   ## 
    #===========================================================                          ##
    app-name = "qdbus org.kde.KWin /KWin queryWindowInfo | grep -i class                  "; # Then click window
    fix-pi   = "ssh -t dacrib@192.168.50.141 '$HOME/scripts/fix-pi'                       ";
                                                                                          ## 
    #===========================================================                          ##  
    # Log checking                                                                        ## 
    #===========================================================                          ##  
    errors         = "sudo journalctl -p err --since '24 hours ago' --no-pager | head -50 ";  
    errors-live    = "sudo journalctl -p err -f                                           "; 
                                                                                          ## 
    #===========================================================                          ##
    # MCPO                                                                                ##
    #===========================================================                          ##
    logs-mcpo      = "sudo journalctl -u     mcpo -f                                      ";
    start-mcpo     = "sudo systemctl start   mcpo                                         ";
    start-mcpo-l   = "sudo systemctl start   mcpo && sudo journalctl -u mcpo -f           ";
    stop-mcpo      = "sudo systemctl stop    mcpo                                         ";
    status-mcpo    = "sudo systemctl status  mcpo                                         ";
    restart-mcpo   = "sudo systemctl restart mcpo                                         ";
    restart-mcpo-l = "sudo systemctl restart mcpo && sudo journalctl -u mcpo -f           ";
                                                                                          ##
    #===========================================================                          ##
    # Navigation                                                                          ##
    #===========================================================                          ##
    br             = "cat ~/cheatsheets/echo/bash-ready-ls/br.txt &&                       \
                      cat ~/cheatsheets/echo/bash-ready-ls/br-cmd.txt | wl-copy           ";
    brmd           = ''ls -lt --time-style=long-iso | awk "/md$/ {print $NF " '\\"'}"    '';
    lstot          = ''ls -la | tail -n +2 | grep '^-' | awk '{print}END{print "---\n"     \
                       NR " files (does not include directories)"}'                      '';
    lstotd         = ''ls -lA | tail -n +2 | awk '{print} END{print "---\n" NR " items (includes directories)"}' '';
    lst            = "ls -1 | wc -l                                                       ";
    user-logs      = "cd /data/aoif/data-pile/logs-user                                   ";
    home           = "cd /etc/nixos/home/tower                                            ";
                                                                                          ##
    #===========================================================                          ##
    # Open-WebUI                                                                          ##
    #===========================================================                          ##
    logs-owui      = "sudo journalctl -u open-webui -f                                    ";
    start-owui     = "sudo systemctl start open-webui                                     ";
    start-owui-l   = "sudo systemctl start open-webui && sudo journalctl -u open-webui -f ";
    stop-owui      = "sudo systemctl stop open-webui                                      ";
    status-owui    = "sudo systemctl status open-webui                                    ";
    restart-owui   = "sudo systemctl restart open-webui                                   ";
    restart-owui-l = "sudo systemctl restart open-webui && sudo journalctl -u open-webui -f";
                                                                                          #
    #===========================================================                     #
    # Plasma                                                                   #
    #===========================================================         #
    save-taskbar   = "sudo save-panel-layout.sh                       ";
                                                                      ##
    #============================================================     ##
    # Speech-to-text (Nemo stt on Titan)                              ##
    #============================================================     ##
    stt            = "cd ~/tools/stt && nix-shell --run './stt'       ";
    stt-pick       = "cd ~/tools/stt && ./stt --pick                  ";
    stt-mics       = "cd ~/tools/stt && nix-shell --run './list-mics' ";
                                                                      ##
    # Stack management (vLLM beast mode vs daily driver)              ##
    stack = "/home/tower/towerstack/scripts/stack                     ";
    vllm  = "/home/tower/towerstack/vllm-cluster/vllm.sh              ";
                                                                      ##
    #===================================                              ##
    # SSH                                                             ##
    #===================================                              ##
    dacrib = "ssh dacrib@192.168.50.141                               ";
    titan  = "ssh titan@192.168.50.103                                ";
    merk   = "ssh merk@192.168.50.199                                 ";
                                                                      ##
    #======================================                           ##
    # TTS                                                             ##
    #======================================                           ##
    tts = "/home/tower/tools/tts/tts.sh                               ";
                                                                      ##
    #================================================                 ##
    # Wireguard                                                       ##
    #================================================                 ##
    start-wg   = "sudo systemctl start wg-quick-wg0                   ";         # <--
    restart-wg = "sudo systemctl restart wg-quick-wg0                 ";                   # <--
    status-wg  = "sudo systemctl status wg-quick-wg0                  ";                             # <--
    stop-wg    = "sudo systemctl stop wg-quick-wg0                    ";                                      # <--
    #                                                                 ##                                                #
    #=================================================================##                                                        #
    # System                                                          ##                                                                #
    #=================================================================##==================================================================
    disp           = "sudo cp ~/display-config.json ~/.config/kwinoutputconfig.json && qdbus org.kde.KWin /KWin org.kde.KWin.reconfigure";
    dry-run        = "sudo nixos-rebuild dry-activate --flake /etc/nixos#$(hostname)                                                    ";
    ir             = "input-remapper-control --command start --device 'Keychron Keychron Ultra-Link 8K' --preset 'try-3'                ";
    irr            = "input-remapper-control --command start --device 'Keychron Keychron Ultra-Link 8K' --preset 'mouse-buttons'        ";
    ir-wired       = "input-remapper-control --command start --device 'Keychron Keychron M6 8K' --preset 'wired-keychron-mouse'         ";
    nix-prune      = "sudo ~/towerstack/scripts/nix-prune-v1_1.sh                                                                       ";
    restart-plasma = "pkill plasmashell; sleep 1; plasmashell &                                       					";
    tmon           = "~/towerstack/scripts/towermon-kiosk.sh &disown                                                                    ";
    nix-yeet       = "sudo nix-env --delete-generations -p /nix/var/nix/profiles/system                                                 ";
    reboot   = "echo '💾 Remember to backup vault: ~/towerstack/scripts/vault-backup.sh' && cd ~/towerstack/scripts && ./lock.sh && ./lock-data-pile.sh && sudo reboot      ";
    shutdown = "echo '💾 Remember to backup vault: ~/towerstack/scripts/vault-backup.sh' && cd ~/towerstack/scripts && ./lock.sh && ./lock-data-pile.sh && sudo shutdown now";
                                                                                            ##                                                                            
    # Vault controls                                                                        ##
    unlock-data = "~/towerstack/scripts/unlock-data-pile.sh                                 ";
    lock-data = "~/towerstack/scripts/lock-data-pile.sh                                     ";
                                                                                            ##
    #=====================================================                                #  
    # vLLM cluster                                                                    #   
    #======================================================                       # 
    vllm-up     = "~/towerstack/vllm-cluster/start-cluster.sh                  ";
    vllm-down   = "~/towerstack/vllm-cluster/stop-cluster.sh                   ";
    vllm-logs   = "docker logs -f vllm-head                                    ";
    vllm-status = "curl -s http://192.168.50.139:8000/v1/models | jq .         ";
    ray-dash    = "echo 'Ray Dashboard: http://192.168.50.140:8265'            ";

    dl = ''
      if [ "$1" = "-h" ] || [ "$1" = "--help" ] || [ -z "$1" ]; then
        echo "dl - aria2c multi-connection downloader"
        echo ""
        echo "Usage: dl <url> [destination-dir]"
        echo ""
        echo "Default destination:"
        echo "  ~/archive-of-infinite-fold/tower-data-plain/lm-studio/models/"
        echo ""
        echo "Examples:"
        echo "  dl https://huggingface.co/some/model/resolve/main/weights.safetensors"
        echo "  dl https://huggingface.co/some/model/resolve/main/weights.safetensors /tmp/"
        return 0
      fi
      dest="''${2:-$HOME/archive-of-infinite-fold/tower-data-plain/lm-studio/models/}"
      echo ""
      echo "Downloading to: $dest"
      echo "To change destination: ctrl+c then: dl \"$1\" /your/path/"
      echo ""
      aria2c -x 16 -s 16 -d "$dest" "$1"
    '';

    which-nix = ''
      echo "=== Current Running ===" && \
      current=$(readlink /run/current-system | grep -oP 'nixos-system-[^/]+') && \
      echo "$current" && \
      echo "" && \
      echo "=== Boot Default ===" && \
      default=$(readlink /nix/var/nix/profiles/system) && \
      echo "$default" && \
      echo "" && \
      echo "=== Last 10 Generations ===" && \
      ls -lt --time-style="+%Y-%m-%d %H:%M" /nix/var/nix/profiles/system-*-link | head -10 | awk '{print $6, $7, $8}'
    '';

    nix-status = ''
      current=$(readlink /run/current-system) && \
      default=$(readlink -f /nix/var/nix/profiles/system) && \
      if [ "$current" = "$default" ]; then \
        echo "✓ Running generation matches boot default"; \
      else \
        echo "⚠ MISMATCH: Running differs from boot default"; \
        echo "  Running: $current"; \
        echo "  Default: $default"; \
      fi
    '';

    nix-lock = ''
      sudo /nix/var/nix/profiles/system/bin/switch-to-configuration boot && \
      echo "Boot default now locked to current running generation"
    '';

    hogs = ''
      echo "=== TOP MEMORY HOGS ===" && \
      ps aux --sort=-%mem | head -10 && \
      echo "" && \
      echo "=== TOP CPU HOGS ===" && \
      ps aux --sort=-%cpu | head -10
    '';
  };
}
