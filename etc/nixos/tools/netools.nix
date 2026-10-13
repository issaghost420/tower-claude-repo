{ config, lib, pkgs, ... }:

let
  cfg = config.services.homelab.network-tools;

  # SmokePing config generator. SmokePing has its own DSL; we build the Targets
  # file programmatically from the Nix list so you edit Nix, not the DSL.
  smokepingTargetsFile = pkgs.writeText "smokeping-targets" ''
    *** Targets ***

    probe = FPing

    menu = Top
    title = Network Latency Grapher
    remark = Homelab network monitoring

    + Homelab
    menu = Homelab
    title = Homelab hosts

    ${lib.concatMapStringsSep "\n" (t: ''
    ++ ${t.name}
    menu = ${t.name}
    title = ${t.name} (${t.host})
    host = ${t.host}
    '') cfg.smokepingTargets}
  '';

  smokepingConfig = pkgs.writeText "smokeping-config" ''
    *** General ***
    owner    = Homelab
    contact  = admin@localhost
    mailhost = localhost
    sendmail = /usr/sbin/sendmail
    imgcache = /var/lib/smokeping/imgcache
    imgurl   = imgcache
    datadir  = /var/lib/smokeping/data
    piddir   = /var/run/smokeping
    cgiurl   = http://localhost:8081/smokeping/smokeping.cgi
    smokemail = /etc/smokeping/smokemail
    tmail     = /etc/smokeping/tmail
    syslogfacility = local0

    *** Alerts ***
    to = admin@localhost
    from = smokeping@localhost

    *** Database ***
    step     = 60
    pings    = 20
    # 1 day of 1-minute averages, 10 days of 5-minute, 30 days of 30-minute,
    # 1 year of 2-hour averages. Enough resolution to catch intermittent stalls,
    # enough history to see weekly/monthly patterns.
    AVERAGE  0.5   1  1440
    AVERAGE  0.5  12  2880
    AVERAGE  0.5 288  1440
    AVERAGE  0.5 1440 720

    *** Presentation ***
    template = /etc/smokeping/basepage.html
    charset = utf-8

    + charts
    menu = Charts
    title = The most interesting destinations

    ++ stddev
    sorter = StdDev(entries=>4)
    title = Top Standard Deviation
    menu = Std Deviation
    format = Standard Deviation %f

    ++ max
    sorter = Max(entries=>5)
    title = Top Max Roundtrip Time
    menu = by Max
    format = Max Roundtrip Time %f seconds

    ++ loss
    sorter = Loss(entries=>5)
    title = Top Packet Loss
    menu = Loss
    format = Packets Lost %f

    ++ median
    sorter = Median(entries=>5)
    title = Top Median Roundtrip Time
    menu = by Median
    format = Median RTT %f seconds

    *** Probes ***
    + FPing
    binary = /usr/sbin/fping

    ${builtins.readFile smokepingTargetsFile}
  '';

  # mtr wrapper — writes timestamped report to log dir. Simple and grep-able.
  mtrScript = pkgs.writeShellScript "network-tools-mtr" ''
    set -eu
    logdir="${cfg.mtrLogDir}"
    mkdir -p "$logdir"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for target in ${lib.escapeShellArgs cfg.mtrTargets}; do
      # Slug the target for the filename (dots -> underscores)
      slug=$(echo "$target" | tr './: ' '___')
      out="$logdir/mtr-$slug.log"
      {
        echo "=== $ts ==="
        ${pkgs.mtr}/bin/mtr --report --report-cycles=10 --no-dns "$target" \
          2>&1 || echo "mtr failed for $target"
        echo ""
      } >> "$out"
    done
    # Rotate: keep last 30 days per target
    find "$logdir" -name 'mtr-*.log' -type f -mtime +30 -delete || true
  '';

in {
  options.services.homelab.network-tools = {
    enable = lib.mkEnableOption "homelab network observability stack";

    # ─── Netdata ─────────────────────────────────────────────────────────
    netdata.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Netdata (real-time system + network monitoring).";
    };

    netdata.port = lib.mkOption {
      type = lib.types.port;
      default = 19999;
      description = "Netdata HTTP port.";
    };

    # ─── SmokePing ───────────────────────────────────────────────────────
    smokeping.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SmokePing (latency + jitter history).";
    };

    smokeping.port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "SmokePing web UI port (host side).";
    };

    smokepingTargets = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Short name for this target (used in the UI).";
          };
          host = lib.mkOption {
            type = lib.types.str;
            description = "Hostname or IP to ping.";
          };
        };
      });
      default = [
        { name = "cloudflare"; host = "1.1.1.1"; }
        { name = "google-dns"; host = "8.8.8.8"; }
      ];
      description = "Targets SmokePing will graph. Override to include your own hosts.";
    };

    # ─── ntopng ──────────────────────────────────────────────────────────
    ntopng.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable ntopng (deep packet analysis / flow visibility).";
    };

    ntopng.port = lib.mkOption {
      type = lib.types.port;
      default = 3333;
      description = "ntopng web UI port.";
    };

    ntopngInterface = lib.mkOption {
      type = lib.types.str;
      default = "eth0";
      example = "eno1";
      description = ''
        Physical interface for ntopng to sniff. This MUST be a real interface
        on the host — passing 'any' or a virtual interface won't give useful
        data. Container runs with host networking to see raw traffic.
      '';
    };

    # ─── mtr timer ───────────────────────────────────────────────────────
    mtr.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run mtr against a set of targets on a timer, log to disk.";
    };

    mtr.interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/5";
      description = "systemd OnCalendar spec. Default: every 5 minutes.";
    };

    mtrTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
      description = "Hostnames or IPs to trace on each mtr run.";
    };

    mtrLogDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/log/network-tools/mtr";
      description = "Where to write mtr reports.";
    };

    # ─── CLI tools ───────────────────────────────────────────────────────
    installCliTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install interactive/on-demand network tools system-wide:
        dnstop, dnsperf, mtr, tcpdump, iftop, nethogs, bandwhich, dig, host.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [

    # ─── Netdata (native NixOS service, NOT a container) ─────────────────
    #
    # Deliberately native. Containerized Netdata loses per-process network
    # stats, most of the systemd integration, and half its collectors.
    # The value of Netdata is the depth of access — don't gut it.
    (lib.mkIf cfg.netdata.enable {
      services.netdata = {
        enable = true;
        config = {
          global = {
            "anonymous statistics" = "no";
            "default port" = toString cfg.netdata.port;
            # Retain 1 week of per-second data; adjust if disk is tight.
            "memory mode" = "dbengine";
            "page cache size" = "32";
            "dbengine multihost disk space" = "1024";
          };
          web = {
            "bind to" = "0.0.0.0:${toString cfg.netdata.port}";
          };
        };
        # Enable the collectors that actually matter for network debugging.
        # Unbound and Pi-hole modules auto-detect if those services are running.
        configDir = {
          "go.d/unbound.conf" = pkgs.writeText "unbound.conf" ''
            jobs:
              - name: local
                address: 127.0.0.1:8953
                cumulative_stats: no
          '';
        };
      };

      networking.firewall.allowedTCPPorts = [ cfg.netdata.port ];
    })

    # ─── Podman as the container backend ─────────────────────────────────
    (lib.mkIf (cfg.smokeping.enable || cfg.ntopng.enable) {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;   # so oci-containers can find `docker` shim
        defaultNetwork.settings.dns_enabled = true;
      };
      virtualisation.oci-containers.backend = "podman";
    })

    # ─── SmokePing (podman) ──────────────────────────────────────────────
    (lib.mkIf cfg.smokeping.enable {
      # Data + config dirs. Both persist across container restarts.
      systemd.tmpfiles.rules = [
        "d /var/lib/smokeping 0755 root root -"
        "d /var/lib/smokeping/data 0755 root root -"
        "d /var/lib/smokeping/imgcache 0755 root root -"
        "d /etc/smokeping 0755 root root -"
      ];

      # Materialize the config on disk so the container can mount it.
      environment.etc."smokeping/config".source = smokepingConfig;

      virtualisation.oci-containers.containers.smokeping = {
        # linuxserver.io image — well-maintained, sane defaults, handles the
        # SmokePing + fastcgi + lighttpd wiring internally so we don't have
        # to reinvent it. Pinned by digest below is safer; using tag for
        # readability here.
        image = "lscr.io/linuxserver/smokeping:latest";
        autoStart = true;
        ports = [ "${toString cfg.smokeping.port}:80" ];
        volumes = [
          "/etc/smokeping:/config/site-confs:ro"
          "/var/lib/smokeping/data:/data"
          "/var/lib/smokeping/imgcache:/config/imgcache"
        ];
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
        };
        extraOptions = [
          # SmokePing needs to send ICMP; give the container the raw socket cap.
          "--cap-add=NET_RAW"
        ];
      };

      networking.firewall.allowedTCPPorts = [ cfg.smokeping.port ];
    })

    # ─── ntopng (podman) ─────────────────────────────────────────────────
    (lib.mkIf cfg.ntopng.enable {
      systemd.tmpfiles.rules = [
        "d /var/lib/ntopng 0755 root root -"
      ];

      virtualisation.oci-containers.containers.ntopng = {
        image = "docker.io/ntop/ntopng:latest";
        autoStart = true;
        # Host networking — ntopng needs to see the actual interface traffic,
        # not the container's veth pair. Port is exposed via the host stack.
        extraOptions = [
          "--network=host"
          "--cap-add=NET_ADMIN"
          "--cap-add=NET_RAW"
        ];
        volumes = [
          "/var/lib/ntopng:/var/lib/ntopng"
        ];
        cmd = [
          "-i" cfg.ntopngInterface
          "-d" "/var/lib/ntopng"
          "-w" (toString cfg.ntopng.port)
        ];
      };

      networking.firewall.allowedTCPPorts = [ cfg.ntopng.port ];
    })

    # ─── mtr timer ───────────────────────────────────────────────────────
    (lib.mkIf cfg.mtr.enable {
      systemd.tmpfiles.rules = [
        "d ${cfg.mtrLogDir} 0755 root root -"
      ];

      systemd.services.network-tools-mtr = {
        description = "mtr path monitoring — write reports to disk";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${mtrScript}";
          # mtr needs raw sockets. Grant just enough capability, no full root.
          AmbientCapabilities = [ "CAP_NET_RAW" ];
          CapabilityBoundingSet = [ "CAP_NET_RAW" ];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ cfg.mtrLogDir ];
        };
      };

      systemd.timers.network-tools-mtr = {
        description = "Run mtr path monitoring on a schedule";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.mtr.interval;
          Persistent = true;
          # Randomize slightly so timer doesn't fire at exactly the same
          # instant every time — avoids beating in phase with other cron.
          RandomizedDelaySec = "30s";
        };
      };
    })

    # ─── Interactive CLI tools ───────────────────────────────────────────
    (lib.mkIf cfg.installCliTools {
      environment.systemPackages = with pkgs; [
        mtr              # ad-hoc traceroute+ping
        dnstop           # real-time DNS query analyzer
        dnsperf          # DNS benchmarking / load testing
        tcpdump          # packet capture
        iftop            # per-connection bandwidth
        nethogs          # per-process bandwidth
        bandwhich        # per-process bandwidth (nicer TUI)
        dig              # (part of dnsutils / bind)
        ldns             # drill — dig alternative
        bind.dnsutils    # dig, host, nslookup
        iperf3           # bandwidth testing between hosts
        ethtool          # NIC diagnostics — check for CRC errors, speed neg
        conntrack-tools  # inspect connection tracking table (NAT debug)
      ];
    })
  ]);
}
