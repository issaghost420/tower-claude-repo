{ pkgs, ... }:

{
  systemd.services.duckdns = {
    description = "DuckDNS dynamic DNS updater";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = "/home/tower/.secrets/duckdns.env";
    };

    script = ''
      RESPONSE=$(${pkgs.curl}/bin/curl -sS \
        "https://www.duckdns.org/update?domains=dojos,zdojo&token=$DUCKDNS_TOKEN&ip=")
      echo "DuckDNS response: $RESPONSE"
      [ "$RESPONSE" = "OK" ] || exit 1
    '';
  };

  systemd.timers.duckdns = {
    description = "Run DuckDNS updater every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Unit = "duckdns.service";
    };
  };
}
