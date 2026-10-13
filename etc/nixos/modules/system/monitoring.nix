{ config, pkgs, lib, ... }:
{
  # EarlyOOM - userspace OOM killer (acts BEFORE kernel OOM which often freezes)
  # This is the last resort after ram-watchdog has tried graceful LLM unloading
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;   # Kill when <5% free (~3GB on 64GB system)
    freeSwapThreshold = 10;
    enableNotifications = true;
    extraArgs = [
      # Kill browsers and non-critical apps first
      "--prefer" "^(firefox|chrome|chromium|librewolf|brave|electron|code|node|python)"
      # Protect system-critical processes
      "--avoid" "^(pipewire|wireplumber|kwin|plasmashell|sddm|systemd|sshd|Xwayland|caddy|podman)$"
    ];
  };

  # Native TowerMon System Monitor Service
#  systemd.services.towermon = {
#    description = "TowerStack System Monitor";
#    after = [ "network.target" ];
#    wantedBy = [ "multi-user.target" ];
#    serviceConfig = {
#      Type = "simple";
#      User = "tower";
#      Group = "users";
#      WorkingDirectory = "/home/tower/towerstack/system-monitor";
#      ExecStart = "${pkgs.python3.withPackages (ps: with ps; [ fastapi uvicorn websockets psutil ])}/bin/python app.py";
#      Restart = "always";
#      RestartSec = 5;
#      # nvidia-smi access for GPU metrics
#      Environment = "PATH=/run/current-system/sw/bin";
#    };
#  };    

  # RAM Watchdog - Tiered OOM protection with LLM model unloading
  # Monitors RAM and takes escalating actions:
  # - 55GB: "7GB remaining!" notification
  # - 57GB: Critical alert + rapid towermon flash
  # - 59GB: Unload LM Studio/vLLM models
  # - 59GB: earlyoom takes over (kills browsers/python)
  systemd.services.ram-watchdog = {
    description = "RAM Watchdog - Tiered OOM Protection";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "tower";
      Group = "users";
      ExecStart = "${pkgs.python3}/bin/python3 /home/tower/towerstack/scripts/ram-watchdog.py";
      Restart = "always";
      RestartSec = 10;
      # Access to containers for LLM control, notify-send for desktop notifications
      Environment = [
        "PATH=/run/current-system/sw/bin"
        "DISPLAY=:0"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
      ];
    };
  };
}
