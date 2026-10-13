{ config, pkgs, lib, ... }:
{
  networking.hostName = "tower";
  networking.hosts = {
    "192.168.50.103" = [ "titan" ];
    "192.168.50.141" = [ "dacrib" ];
    "192.168.50.140" = [ "tower" ];
  }; 
  networking.networkmanager.enable = true;
  networking.interfaces.eno2.ipv4.addresses = [{
    address = "192.168.50.140";
    prefixLength = 24;
  }];
  boot.kernel.sysctl = {
    "net.ipv6.conf.all.disable_ipv6" = 1;
    "net.ipv6.conf.default.disable_ipv6" = 1;
  };
  networking.enableIPv6       =   false;
  networking.defaultGateway   =   "192.168.50.1";
  networking.nameservers      = [ "192.168.50.141" ];
  networking.resolvconf.extraOptions = [ "no-aaaa" ];
  # Make RAPL energy counter readable for towermon CPU power monitoring
  systemd.tmpfiles.rules = [
    "z /sys/class/powercap/intel-rapl:0/energy_uj 0444 root root -"
  ];

  # Firewall - includes Sunshine, Syncthing, LocalSend, KDE Connect
  networking.firewall.allowedTCPPorts = [
    22      # SSH
    80      # HTTP
    443     # HTTPS
    1234    # LM Studio API
    2222    # Git SSH (Gitea)
    2283    # Immich
    3000    # Reseverved for Gitea
    3232    # Esphome OTA
    3389    # KDE Remote Desktop
#   4040    # OpenClaw
    4200    # Hat^.,.^Cat server
    5021    # chatterbox
    5201    # iperf3
    6000    # Laybird dev tools
    6052    # Esphome
    7100    # Diff checker 
#   7860    # TextGen WebUI
#   8000    # SillyTavern direct
    8001    # mcpo
    8060    # Fish-speech
    8080    # OpenWeb UI
    8188    # Comfy UI GPU 1
    8189    # Comfy UI GPU 0
#   8443    # SillyTavern HTTPS (via Caddy)
    8888    # Searxng
    11434   # Ollama API (for RAG embeddings)
#   21115   # RustDesk NAT type test
#   21116   # RustDesk ID/rendezvous
#   21117   # RustDesk relay
#   21118   # RustDesk web client
#   21119   # RustDesk WebSocket
    22000   # Syncthing
#   47984   # Sunshine HTTPS Web UI
#   47989   # Sunshine RTSP
#   47990   # Sunshine Control
    53317   # LocalSend
  ];

  networking.firewall.allowedUDPPorts = [
#    53      # DNS - TEMP
    3389    # KDE Remote Desktop
    5201    # iperf3
    6000    # ladybird dev tools #test, rm if still don't work 
#    8000    # ST
    21027   # Syncthing discovery
#    21116   # RustDesk
#    21119   # RustDesk
    22000   # Syncthing
    47998   # Sunshine Video
    47999   # Sunshine Control
    48000   # Sunshine Audio
    48002   # Sunshine Mic
    48010   # Sunshine HDR
    51820   # WireGuard
    53317   # LocalSend
  ];
  networking.firewall.extraCommands = ''
    iptables -A OUTPUT -d 83.142.209.194 -j DROP
  ''; 
  # KDE Connect ports
  networking.firewall.allowedTCPPortRanges = [ { from = 1714; to = 1764; } ];
  networking.firewall.allowedUDPPortRanges = [ { from = 1714; to = 1764; } ];

  # ==========================================
  # 5a. WIREGUARD VPN
  # ==========================================
  networking.wg-quick.interfaces.wg0 = {
    configFile = "/home/tower/towerstack/wireguard/wg0.conf";
    autostart = true;
  };

  # Mullvad exit tunnel (Ghost Mode)
#  networking.wg-quick.interfaces.wg-mullvad = {
#    configFile = "/home/tower/towerstack/wireguard/mullvad/wg-mullvad.conf";
#    autostart = false;  # Disabled - Mullvad not currently installed
#  };
}

  # Network stack tuning for USB gigabit + 5GbE | Disabled 7-29-26 to troubleshoot slow>
#  boot.kernel.sysctl = {
    # TCP buffer auto-tuning: min/default/max (bytes)
#    "net.ipv4.tcp_rmem" = "4096 262144 16777216";       # RX: 4K/256K/16M
#    "net.ipv4.tcp_wmem" = "4096 262144 16777216";       # TX: 4K/256K/16M
#    "net.core.rmem_max" = 16777216;                     # 16M max socket RX buffer
#    "net.core.wmem_max" = 16777216;                     # 16M max socket TX buffer
#    "net.core.rmem_default" = 262144;                   # 256K default RX
#    "net.core.wmem_default" = 262144;                   # 256K default TX
#    "net.core.netdev_max_backlog" = 5000;               # Burst packet queue (USB deli>
#    "net.ipv4.tcp_fastopen" = 3;                        # TFO client + server
#    "net.core.default_qdisc" = "fq";                    # Fair queuing (pairs with BBR)
#    "net.ipv4.tcp_congestion_control" = "bbr";          # BBR congestion control (bett>
#  };
