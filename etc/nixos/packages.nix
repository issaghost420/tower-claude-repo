{ pkgs, zedless, ... }:
{

#  nixpkgs.config.permittedInsecurePackages = [
#    "ladybird-0-unstable-2026-06-05"
#    "glances"
#  ]; 

  environment.systemPackages = with pkgs; [

    # AI tools
    aichat                                           # AI terminal assistant (wtf/dafuq aliases)
    atuin                                            # Magical shell history with sync (Ctrl+R)
#    pkgs.playwright-driver.browsers                  # Enables MCP browser for ai tool calls 

    # Audio
    audacity                                         # Multi-track audio editor
    easyeffects                                      # Audio effects processor with audio tuning tools
#    deepfilternet                                    # AI speech cleaner
    kdePackages.krecorder                            # Simple audio recording tool
    qjackctl                                         # JACK GUI control panel
    obs-studio                                       # Open-source video recording and live streaming software
    obs-studio-plugins.obs-pipewire-audio-capture    # Plugin to capture audio on PipeWire
    pulsemixer                                       # TUI mixer for quick checks
    pkgs.lsp-plugins                                 # High-quality studio plugins (De-esser, EQ)
#    praat                                            # Speech analysis tool
    sox                                              # CLI audio cleaning tool

    # Browsers

  # Brave with extra hardening 
    (pkgs.brave.override {
      commandLineArgs = builtins.concatStringsSep " " [
        "--password-store=basic"                      # Stops credential storing and it's prompts 
        "--disable-reading-from-canvas"               # extra fingerprint resistance
        "--disable-webgl"                             # kills a major fingerprint vector (also kills some sites)
        "--no-pings"                                  # blocks hyperlink auditing/tracking pings
        "--disable-breakpad"                          # disables crash reporting
        "--disable-domain-reliability"                # stops Google reliability telemetry
      ];
    })
#    carbonyl                                         # Chromium based web browser for kitty terminal
    firefox
    ladybird
    librewolf

    # Connectivity
    kdePackages.kdeconnect-kde                       # KDE-based client for mobile device connectivity
    ifuse                                            # Mount iPhone filesystem on linux
    libimobiledevice                                 # iPhone USB access
    localsend                                        # LAN file sharing
    syncthing                                        # Folder sync between different machines

    # Creative tools
    annotator                                        # Markup/Annotation
#    blender                                          # Open-source 3D creation suite
    drawing                                          # Doodle tool
    ksnip                                            # Advanced screenshot tool/img editor (with blur) 
    orca-slicer                                      # 3D printer slicer
    plasticity                                       # 3D Modeling software

    # Dev tools
    argc                                             # Bash CLI framework, runs llm-functions (aichat tools + MCP bridge)
    bubblewrap                                       # Unprivileged chroot environment for security sandboxing
#    diffotool   this <-- not the right thing
    esphome                                          # yaml to binary flashable code compiler
    esphome-device-builder                           # Esphome gui 
    git                                              # git status and such
    jq                                               # json formatter/organizer tool
    nil                                              # Nix language server (Rust, fast af) 
    nixd                                             # NixOS systemd integration for managing services
    nixpkgs-fmt                                      # Automatic formatting tool for nix files
    nodejs_22                                        # Node.js runtime environment
    p7zip                                            # 7zip archiving tool
    ripdrag                                          # Spawns a dragable file use 'ripdrag /path/to/file'
    socat                                            # Networking swiss army knife for multiplexing, tunneling, and proxying
    sqlitebrowser                                    # GUI browser for SQLite databases
    testdisk                                         # drive testing tool
    zed-editor                                       # High-performance text editor inspired by Sublime Text

    # Diagnostics
    pkgs.lsof                                        # Lists open files, network sockets, and finds processes using them.

    # File navigators and cleanup tools
    file                                             # MIME detection
    exiftool                                         # metadata
    hexyl                                            # hex viewer
    kdiff3                                           # Krusader robust diff checker
    krusader                                         # Dual-pane Total Commander paradigm for batch file ops
    jdupes                                           # Duplicate finder faster fork of fdupes
    mediainfo                                        # media info preview
    ncdu                                             # Terminal disk analyzer, SSH-friendly
    ouch                                             # rust-based compress/decompress
    pcmanfm-qt                                       # File explorer 
    qdirstat                                         # Wiztree-alike, treemap + removal tool
    rmlint                                           # Feature rich duplicate finder (dupes, empty dirs, broken symlinks, etc)
#    thunar                                           # File manager with consitent GUI
    unar                                             # universal archive extractor
    unzip                                            # Zip extraction
    yazi                                             # Terminal based file manager with preview images/videos/PDF's 
    zip						     # Compression

    # Gaming
#    vulkan-tools                                     # vulkaninfo, vkcube
#    mangohud                                         # perf overlay: MANGOHUD=1 %command%
#    protontricks                                     # fixes for specific games

    # KDE Plasma 6
    kdePackages.filelight                            # Disk space visualizer
    kdePackages.kio-admin                            # Admin actions in Dolphin
    kdePackages.kio-extras

    # Mouse/input device config (Razer Viper V2 pro)
    #libratbag                                       # Backend library for ratbagd
    #piper                                           # GUI for configuring gaming mice

    # Media tools
#    geeqie                                           # Lightweight image viewer with EXIF support
    mpv                                              # Lightweight media player with support for multiple audio/video codecs
    nomacs                                           # Heavyweight Featured image viewer
    qimgv                                            # Speedy and lightweight image viewer with shortcuts support
    slurp                                            # Wayland region selector
    spotify                                          # For the jamz
    tesseract                                        # OCR engine - extracts text from images
    viu                                              # Fast terminal image viewer (Kitty graphics protocol)
    vlc                                              # Video player
    w3m                                              # Text web browser with inline images

    # Network tools
    curl                                             # HTTP client, llm-functions MCP bridge calls go through it
    dig                                              # DNS and query tool
    iperf3                                           # Network testing tool
    tcpdump                                          # Packet capture and network traffic analyzer 

    # Office tools
    imagemagick                                      # Image manipulation for logos/photos
    parallel                                         # GNU parallel for batch processing
    libreoffice-stable                               # Office suite compatible with Microsoft Office
    pandoc                                           # Convert anything to anything
    pdfarranger
    evince                                           # PDF editor
    texliveSmall                                     # For PDF generation via LaTeX

    # Remote access
    kdePackages.krdp                                 # KDE native RDP server - works with Wayland, no permission dialogs
    moonlight-qt                                     # Remote Desktop hi-res low latency

    # Python 3.14 with all packages bundled 
    (python314.withPackages (ps: with ps; [
#      noisereduce
      openai
      pip
      psutil
      pygame
      pycairo
      pygobject3
      pyjwt
      requests
      tesserocr
      uvicorn
    ]))

    # Recreation
#    wtype                                            # typing speed tests

    # Shell tools
    aria2                                            # Fast downloads use with (ex.) 'aria2c -x 16 -s 16 'https://huggingface.co/...'
    bat                                              # Cat clone with syntax highlighting and git integration
    chafa                                            # Universal terminal image parser
    delta                                            # diff checker (delta file1.txt file2.txt --side-by-side)
    duckdb                                           # Analytical engine that reads SQL, CSV, JSON, Parquet, etc.
    duf                                              # Modern disk analyzer with grouping 
    dust                                             # Shows folder sizes
    fatrace
    fd                                               # Fast and simple command-line utility to locate files by name
    ffmpeg                                           # Command-line tool for video/audio processing
    ffmpegthumbnailer                                # video thumbnails
    fzf                                              # Fuzzy Finder CLI search tool
#    huggingface_hub
    kdotool                                          # Window manager utility
    kitty                                            # GPU accelerated terminal emulator
    litecli                                          # SQLite cli browser w/ auto-complete, syntax highlighting, etc.
    oh-my-zsh                                        # ZSH config manager
    pay-respects                                     # Command corrector - press F to fix last command
    poppler                                          # PDF preview
    pv                                               # Pipe viewer - Progress bar for pipes/long commands
    ripgrep                                          # broad searchtool for file contents
    starship                                         # Cross-shell prompt customizer
    sqlite                                           # SQL something idk
    sqlit-tui                                        # SQlite db ninja with ARROW KEYS! Yazi-like db browser
    sqlite-utils                                     # SQLite cli browser. Boring, bulletproof. 'Should just work'. 
    tldr                                             # Man community cheat sheets (use with tldr <tool>)
    tmux                                             # Terminal multiplexor to manage multiple terminal sessions
#    trashy                                           # Send to trash terminal rm's
    trash-cli
    tree                                             # Tree folder structure view cli tool
    usql                                             # This will read the database. no doubt about it. (use usql postgres:// usql mysql:// ...) 
    kdePackages.yakuake                              # Quake style window manager

   # System tools
    arp-scan                                          # ARP-based LAN scanner for device discovery
    binutils                                          # Pulls in strings and who knows what else
#    cudaPackages.cudatoolkit                          # NVIDIA CUDA toolkit
    efibootmgr                                        # EFI boot manager
    fx                                                # Interactive terminal .json broweser
    glib                                              # Foundational C utility library powering the GNOME desktop environment
    gtk4                                              # TowerMon desktop widget
    gtk4-layer-shell                                  # Wayland layer-shell for dock behavior
    hyprpicker                                        # Color picker tool for various ouput/formats
    libxcb                                            # C library for X11
    qt6.qtwayland                                     # Qt6 Wayland platform plugin, enables native Wayland rendering for Qt6 apps
    usbutils                                          # lsusb and more usb utilities 
    uv                                                # Fast Python package/project manager (uvx runs Python MCP servers)
    visidata                                          # json viewer spreadsheet style
    wireguard-tools                                   # Wireguard VPN manager/configure-r
    wl-clipboard                                      # Wayland clipboard (wl-copy)
    xclip
    xdotool                                           # Automates mouse/keyboard input, window management, etc on X11 servers
    xhost                                             # CLI access/revoke tool to X server for remote clients
    zenity                                            # Create graphical dialog boxes from command-line and shell scripts

    # Text editors
    helix                                             # Advanced keyboard-driven modal text editor built with Rust
    marktext                                          # Modern elegant writing app/markdown editor
    micro                                             # Like nano but with standard keybindings, full mouse support, syntax highlighting, splits/tabs
    typora                                            # minimalist markdown editor
    zettlr                                            # research features such as citation management, versioning, stat tracking
    ### zedless ⬇️ ⬇️ ⬇️                                 # Zed fork - Like Gram but retains local AI configuration settings
    (zedless.packages.x86_64-linux.default.overrideAttrs {
      cargoHash = "sha256-V4rjc1mbOin2pgG02uxXuyta23KvL81AlSed1vkXk2g=";
    })

    # Vitals and system monitoring
    btop                                              # Convoluted and detailed resource monitor
    glances                                           # Detailed but fugly resource monitor
  ];
}
