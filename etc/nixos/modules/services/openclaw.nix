{ config, pkgs, lib, ... }: 
{
  services.openclaw = {
    enable = true;
    domain = "192.168.50.140";
    gatewayPort = 4040; 
    modelProvider = "lm-studio"; 
    toolAllowlist = [ "browser" "shell" "agent-memory" "read" "local-files" "git" "read-multiple" "write" "edit" "web-search" "deep-research" ];
  };
  systemd.services.openclaw = {
    serviceConfig = {
      EnvironmentFile = "/home/tower/.secrets/lms-export.env";  # Not likely I'll use this, but the token do exist 🤷‍♀️
    };
    environment = {
      CLAWHUB_DISABLE_TELEMETRY = "1";
      OPENCLAW_TELEMETRY_DISABLED = "1";
	  OPENCLAW_NO_AUTO_UPDATE  = "1";
    };
  };
  systemd.services.openclaw-gateway.serviceConfig.RestrictAddressFamilies = lib.mkForce [
    "AF_INET"
    "AF_INET6"
    "AF_UNIX"
    "AF_NETLINK"
  ];  
}
