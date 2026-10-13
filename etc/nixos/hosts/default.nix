{ config, pkgs, lib, ... }:
{
  imports = [
    ./boot.nix
    ./hardware.nix
    ./filesystems.nix
    ./networking.nix
    ./users.nix
    ../packages.nix
    ../starship.nix
#    ../../modules/system/hyprland.nix
#    ../../modules/system/hyprland-plugins.nix
    ../modules/system/audio.nix
    ../modules/system/desktop.nix
#    ../modules/system/gaming.nix
    ../modules/system/monitoring.nix
    ../modules/system/nh.nix
    ../modules/system/power.nix
    ../modules/system/printing.nix
    ../modules/system/security.nix
    ../modules/system/udev.nix
    ../modules/system/zsh-system.nix
    ../modules/services/ai-stack.nix
    ../modules/services/caddy.nix
    ../modules/services/duckdns.nix
    ../modules/services/esphome.nix
    ../modules/services/gitea.nix
    ../modules/services/immich.nix
    ../modules/services/mcpo.nix
    ../modules/services/searxng.nix
    ../modules/services/ssh.nix
    ../modules/packages/development.nix
    ../modules/packages/system.nix
    ../overlays
    ../tools/chat-convert/chat-convert.nix
    ../tools/chat-convert/json-to-lmstudio-grok.nix
    ../tools/chat-convert/json-to-openwebui-grok.nix
    ../tools/hazyhud.nix
#    ../tools/netools.nix
    ../tools/pi.nix
    ../tools/stt.nix
    ../tools/wheres.nix
    ../hardware-configuration.nix
  ];


#services.homelab.network-tools = {
#  enable = true;
#  smokepingTargets = [
#    { name = "gateway"; host = "192.168.50.1"; }
#    { name = "cloudflare"; host = "1.1.1.1"; }
#    # ... etc
#  ];


#  ntopngInterface = "eno2";  # or whatever your actual uplink is
#};
#  virtualisation.containers.registries.search = [ "docker.io" "quay.io" ];




  programs.pi-cli.enable = true;
  
time.timeZone = "America/Los_Angeles";
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.permittedInsecurePackages = [
    "openssl-1.1.1w"
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "24.11";
}
