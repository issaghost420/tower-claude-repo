{ configs, pkgs, lib, ... }:
{
  systemd.services.esphome = {
    description = "ESPHome Device Builder";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.esphome-device-builder}/bin/esphome-device-builder --host 0.0.0.0 --port 6052 /home/tower/tools/esphome/config";
      Restart = "on-failure";
      User = "tower";
      Group = "users";
    };
  };
}
