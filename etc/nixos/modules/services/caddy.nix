{ config, pkgs, lib, ... }:
let
  tempAllowIPs = [
   # Drop temp IPs here, rebuild, remove when done
  ];
  permanentIPs = [
    "192.168.50.0/24"  # LAN
    "10.66.66.0/29"    # WireGuard (.0-.7)
  ];
  allAllowedIPs = permanentIPs ++ tempAllowIPs;
  ipList = builtins.concatStringsSep " " allAllowedIPs;
in
{
  services.caddy = {
    enable = true;
    package = pkgs.caddy.withPlugins {
      plugins = [
        "github.com/caddy-dns/duckdns@v0.5.0"
      ];
      hash = "sha256-1nx8y8vrE3MubRMqviM5mYqCK3d0SLkXI0Ts8eWBmdc=";
    }; 

    #===========================================================
    # BIG BOX HEMP - INVENTORY/CUSTOMER PORTAL/BILLING
    #===========================================================
    virtualHosts."bbhemp.duckdns.org" = {
      extraConfig = ''
        tls {
          dns duckdns 3f516c21-ae6b-443a-a1a3-546ab92edea1
        }
        handle /websocket {
          reverse_proxy 192.168.50.141:8072
        }

        handle {
          reverse_proxy 192.168.50.141:8069 {
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
          }
        }
      '';
    };
    # ==========================================================
    # STACK ACCESS (DuckDNS + HTTPS) - HATCAT SPECIFIC
    # ==========================================================
    virtualHosts."sstack.duckdns.org" = {
      extraConfig = ''
        tls {
          dns duckdns 3f516c21-ae6b-443a-a1a3-546ab92edea1
        }
      # --- IP whitelist (same as your main domain) ---
         @denied not remote_ip ${ipList}
         handle @denied { 
           respond "Access Denied" 403
         }
      # --- Hatcat Redirect ---
        @hatcat_exact path /hatcat
        redir @hatcat_exact /hatcat/ permanent
      # --- Hatcat Proxy ---
        handle /hatcat/* {
          uri strip_prefix /hatcat
          reverse_proxy localhost:4200
        }
      '';
    };

    # ==========================================================
    # EXTERNAL ACCESS (DuckDNS + HTTPS)
    # ==========================================================
    virtualHosts."dojos.duckdns.org" = {
      extraConfig = ''
        tls {
          dns duckdns 3f516c21-ae6b-443a-a1a3-546ab92edea1
        }

        # --- IP whitelist (must be before all handlers) ---
        @denied not remote_ip ${ipList}
        handle @denied { #remove all the #'s if re-enabling 
          respond "Access Denied" 403
        }

        #=================================../
        # --- Trailing slash redirects ---( D:== 
        #=================================..\

        @sysmonitor_exact path /sysmonitor
        redir @sysmonitor_exact /sysmonitor/ permanent
        @chatterbox_exact path /chatterbox
        redir @chatterbox_exact /chatterbox/ permanent
        @comfy_exact path /comfy
        redir @comfy_exact /comfy/ permanent
        @diff_exact path /diff
        redir @diff_exact /diff/ permanent
        @git_exact path /git
        redir @git_exact /git/ permanent
        @hatcat_exact path /hatcat
        redir @hatcat_exact /hatcat/ permanent
#        @immich_exact path /immich
#        redir @immich_exact /immich/ permanent
        @lms_exact path /lms
        redir @lms_exact /lms/ permanent
        @mcp_exact path /mcp
        redir @mcp_exact /mcp/ permanent
        @mon_exact path /mon
        redir @mon_exact /mon/ permanent
        @chat_exact path /chat
        redir @chat_exact /chat/ permanent
        @tmon_exact path /titan-mon
        redir @tmon_exact /titan-mon/ permanent
        @sear_exact path /sear
        redir @sear_exact /sear/ permanent

        # Pi-hole / HA redirects
        @pi_exact path /pi
        redir @pi_exact /pi/ permanent
        @pihole_exact path /pihole
        redir @pihole_exact /pihole/ permanent
        @ha_exact path /ha
        redir @ha_exact /ha/ permanent
        @home_exact path /home
        redir @home_exact /home/ permanent

        #D;================d=====-\,
        #  >- API endpoints|>- < (-:|B
        #D;================d=====-/`
        # LM Studio API (add your Bearer token here)
        handle /lmstudio/* {
          uri strip_prefix /lmstudio
          reverse_proxy localhost:1234
        }

        # Unified /v1 API (STT to NeMo on Titan, rest to LM Studio)
        handle /v1/audio/transcriptions {
          header Access-Control-Allow-Origin "*"
          header Access-Control-Allow-Methods "POST, OPTIONS"
          header Access-Control-Allow-Headers "Content-Type"
          @options method OPTIONS
          respond @options 204
          reverse_proxy titan:8765
        }
        handle /v1/* {
          reverse_proxy localhost:1234
        }

        ##########################
        # --- Titan services --- #
        ##########################

        handle /titan-mon/* {
          uri strip_prefix /titan-mon
          reverse_proxy titan:8095
        }
        handle_path /nemo/* {
          reverse_proxy titan:8765
        }
        handle /chatterbox/* {
          uri strip_prefix /chatterbox
          reverse_proxy titan:5021
        }
        handle /comfy/* {
          uri strip_prefix /comfy
          reverse_proxy titan:8188 {
            flush_interval -1
          }
        }

        #========================@ _*c\
        # --- Tower services ---( |> = }
        #========================@ -*c/

        handle /sysmonitor/* {
          uri strip_prefix /sysmonitor
          reverse_proxy localhost:8095
        }
        handle /git/* {
          uri strip_prefix /git
          reverse_proxy localhost:3000
        }
        handle /chat/* {
          uri strip_prefix /chat
          reverse_proxy localhost:8080
        }
 #       handle /hatcat/* {
 #         uri strip_prefix /hatcat
 #         reverse_proxy localhost:4200
 #       }
        handle_path /immich* {
          uri strip_prefix /immich
          redir * https://immich.dojos.duckdns.org{uri} permanent
        }
        handle /lms/* {
          uri strip_prefix /lms
          reverse_proxy localhost:1234 {
            header_up Authorization "Bearer sk-lm-zyVeeF4e:3rfTIMbM3Vn2I8Dswk0a"
          }
        }
        handle /mcp/* {
          uri strip_prefix /mcp
          reverse_proxy localhost:8001
        }
        handle /mon/* {
          uri strip_prefix /mon
          reverse_proxy localhost:8095
        }
        handle /sear/* {
          reverse_proxy localhost:8888
        }

        #======================================\
        # Dacrib services - redir to LAN (wg) |*|
        #======================================/

        handle /pi/* {
          redir * http://pi.tower.lan permanent
        }
        handle /pihole/* {
          redir * http://pi.tower.lan permanent
        }
        handle /ha/* {
          redir * http://ha.tower.lan permanent
        }
        handle /home/* {
          redir * http://ha.tower.lan permanent
        }

        # --- Open WebUI catch-all (MUST BE LAST) ---
        @websockets {
          header Connection *Upgrade*
          header Upgrade websocket
          path /ws/socket.io/*
        }
        handle @websockets {
          reverse_proxy localhost:8080
        }
        handle_path /socket.io/* {
          reverse_proxy localhost:8080
        }
        handle /* {
          reverse_proxy localhost:8080
        }
      '';
    };

    virtualHosts."immich.dojos.duckdns.org" = {
      extraConfig = ''
        tls {
          dns duckdns 3f516c21-ae6b-443a-a1a3-546ab92edea1
        }
        @denied not remote_ip ${ipList}
        handle @denied {
          respond "Access Denied" 403
        }
        reverse_proxy localhost:2283
      '';
    };

    # =======================================,=======I__|\ ,
    # LAN ACCESS (.tower.lan subdomains) =>--||- ( <()*8)*|
    # =======================================`=======I--|/ `
    # Tower
    virtualHosts."http://chat.tower.lan".extraConfig            = "reverse_proxy localhost:8080";
    virtualHosts."http://immich.tower.lan".extraConfig          = "reverse_proxy localhost:2283";
    virtualHosts."http://mon.tower.lan".extraConfig             = "reverse_proxy localhost:8095";
    virtualHosts."http://lms.tower.lan".extraConfig             = "reverse_proxy localhost:1234";
    virtualHosts."http://git.tower.lan".extraConfig             = "reverse_proxy localhost:3000";
    virtualHosts."http://diff.tower.lan".extraConfig            = "reverse_proxy localhost:7100";
    virtualHosts."http://sear.tower.lan".extraConfig            = "reverse_proxy localhost:8888";
    virtualHosts."http://mcp.tower.lan".extraConfig             = "reverse_proxy localhost:8001";

    # Titan
    virtualHosts."http://tmon.tower.lan".extraConfig      = "reverse_proxy titan:8095";
    virtualHosts."http://nemo.tower.lan".extraConfig      = "reverse_proxy titan:8765";
    virtualHosts."http://chatter.tower.lan".extraConfig   = "reverse_proxy titan:5021";
    virtualHosts."http://comfy.tower.lan".extraConfig     = ''
      reverse_proxy titan:8188 {
        flush_interval -1
      }
    '';

    # Dacrib
    virtualHosts."http://ha.tower.lan".extraConfig        = "reverse_proxy 192.168.50.141:8123";
    virtualHosts."http://pihole.tower.lan".extraConfig    = ''
      redir / /admin/ permanent
      reverse_proxy 192.168.50.141:80
    '';
    virtualHosts."http://pi.tower.lan".extraConfig        = ''
      redir / /admin/ permanent
      reverse_proxy 192.168.50.141:80
    '';
  };  
}
