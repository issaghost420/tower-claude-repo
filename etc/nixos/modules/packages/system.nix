{ config, pkgs, lib, ... }:

let
  towerHome = "/home/tower";

  gram = pkgs.stdenv.mkDerivation rec {
    pname = "gram";
    version = "3.2.0";
    src = pkgs.fetchurl {
      url = "https://codeberg.org/GramEditor/gram/releases/download/${version}/gram-linux-x86_64-${version}.tar.gz";
	  hash = "sha256-/Y75IW0qqb5JqGZ8BI8xd1oUnc8gfOISO7/M/Txo9a8=";
    };
    nativeBuildInputs = with pkgs; [ autoPatchelfHook makeWrapper ];
    buildInputs = with pkgs; [
      alsa-lib fontconfig freetype libGL libX11 libXcursor
      libXext libXi libXrandr libxkbcommon vulkan-loader
      wayland zlib stdenv.cc.cc.lib
    ];

    # The tarball dumps everything into a gram.app/ folder
    sourceRoot = "gram.app";

    installPhase = ''
      runHook preInstall

      # Preserve the whole bundle so relative paths don't break
      mkdir -p $out/lib
      cp -r . $out/lib/gram

      # Wrap the launcher binary
      mkdir -p $out/bin
      makeWrapper $out/lib/gram/bin/gram $out/bin/gram \
        --prefix LD_LIBRARY_PATH : "${pkgs.lib.makeLibraryPath [ pkgs.vulkan-loader pkgs.wayland pkgs.libxkbcommon pkgs.libGL ]}"

      # Desktop entry
      if [ -f share/applications/gram.desktop ]; then
        mkdir -p $out/share/applications
        cp share/applications/gram.desktop $out/share/applications/
        substituteInPlace $out/share/applications/gram.desktop \
          --replace-fail "Exec=gram" "Exec=$out/bin/gram" || true
      fi

      # Icons
      if [ -d share/icons ]; then
        mkdir -p $out/share/icons
        cp -r share/icons/* $out/share/icons/
      fi

      runHook postInstall
    '';
  };

in
{
  # ==========================================
  # 11a. SYSTEM PACKAGES (require root/system integration)
  # ==========================================
  environment.systemPackages = with pkgs; [

    # --- System integration required ---
    gocryptfs                                         # Encryption tool/Vault handler
    sbctl                                             # Secure Boot control tool for managing keys and policies
    ethtool                                           # Ethernet config/monitoring CLI tool
    pciutils                                          # PCI device config tool set
    usbutils                                          # lsusb and more usb utilities
    nvme-cli                                          # NVMe drive management and SMART data
    smartmontools                                     # SMART disk health monitoring (smartctl)
    tesseract                                         # OCR 

    # --- Audio system tools ---
    jack2                                             # JACK tools (jack_lsp, jack_connect, etc.)
    pulsemixer                                        # TUI mixer for quick checks
    qjackctl                                          # JACK GUI control panel

    # --- Container tooling ---
#    docker-compose                                    # Docker-compose tools, works with Podman

    # --- Hardware control ---
    openrgb                                           # RGB control

    # --- Network filesystem ---
    sshfs                                             # For mounting windows files from tower

    # --- Base utilities scripts expect ---
    git                                               # Version control tool for codebases
    wget                                              # CLI package downloader
    unzip                                             # ZIP extractor
    p7zip                                             # 7zip archiving tool

    # --- Monitoring ---
    btop                                              # Convoluted and detailed resource monitor
    htop                                              # Another hideous resource monitor

    # --- Gram editor (custom derivation) ---
    gram

    # LM Studio with CUDA environment variables
    (symlinkJoin {
      name = "lm-studio-wrapped";
      paths = [ lmstudio ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        for bin in lm-studio lms; do
            if [ -f "$out/bin/$bin" ]; then
              wrapProgram "$out/bin/$bin" \
              --set GGML_CUDA_FORCE_CUBLAS "1" \
              --set GGML_CUDA_NO_PINNED "1" \
              --set LLAMA_TENSOR_SPLIT "0.5,0.5" \
              --set CUDA_VISIBLE_DEVICES "0,1" \
              --set NVIDIA_VISIBLE_DEVICES "all" \
              --set NVIDIA_DRIVER_CAPABILITIES "compute,utility,graphics" \
              --set __NV_PRIME_RENDER_OFFLOAD "1" \
              --set __GLX_VENDOR_LIBRARY_NAME "nvidia" \
              --set VK_ICD_FILENAMES "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json" \
              --set VK_DRIVER_FILES "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json" \
              --prefix LD_LIBRARY_PATH : "/run/opengl-driver/lib"
          fi
        done
      '';
    })
  ];

  # UDEV packages
  services.udev.packages = [
    pkgs.openrgb
  ];

  # ==========================================
  # NIX-LD (dynamic linker for non-Nix binaries)
  # ==========================================
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    icu
    openssl
    stdenv.cc.cc
    zlib
    glib
    libGL
  ];

#  systemd.services.tts-cleanup = {
#    description = "Clean up old TTS output files";
#    serviceConfig = {
#      Type = "oneshot";
#      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.findutils}/bin/find /home/tower/towerstack/tts-gateway/outputs -type f -mmin +60 -delete 2>/dev/null || true'";
#      User = "tower";
#    };
#  };

  # ==========================================
  # 11b. TTS OUTPUT FILE CLEANUP
  # ==========================================
  # Auto-delete TTS output files older than 1 hour (every hour)
  # All TTS services write to /home/tower/towerstack/tts-gateway/outputs/
#  systemd.timers.tts-cleanup = {
#    description = "Run TTS cleanup every hour";
#    wantedBy = [ "timers.target" ];
#    timerConfig = {
#      OnBootSec = "10min";  # First run 10 minutes after boot
#      OnUnitActiveSec = "1h";  # Then every hour
#      Unit = "tts-cleanup.service";
#    };
#  };
}
