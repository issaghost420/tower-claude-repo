# Consumers:
#   - You, in a browser           -> https://dojos.duckdns.org/sear/ or :8888
#   - Open WebUI RAG web search   -> :8890 (proxy, for pagination)
#   - web-search MCP server       -> :8888
#   - deepresearch                -> :8888 (does its own pagination)
#
# GROUND TRUTH after any change:
#   curl -s http://localhost:8888/config | jq '[.engines[] | select(.enabled) | .name]'
# That is what the process loaded. This file is only an input to that.

{ config, lib, pkgs, ... }:

let
  searxPort = 8888;
  proxyPort = 8890;

  proxyPython = pkgs.python3.withPackages (ps: with ps; [ aiohttp ]);
  proxyScript = "/home/tower/towerstack/searxng/searxng-proxy/proxy.py";
in
{
  # COUPLED TO configureUwsgi BELOW. With configureUwsgi = true, environmentFile does
  # NOT reach the uWSGI vassal (nixpkgs issue #292652) — SearXNG then falls back
  # to the default key and refuses to start. If you ever flip to uwsgi you must
  # also move the secret inline to settings.server.secret_key and accept it
  # being in the world-readable store. These two settings are one decision.
#  services.searx.environmentFile = "/home/tower/.secrets/searxng.env";

  ############################################################################
  ## SearXNG
  ############################################################################
  services.searx = {
    enable = true;

    # Keep false. See the coupling note above before changing. <--not relevant with inline secret
    configureUwsgi = true;

    uwsgiConfig = {
      http = ":${toString searxPort}";
      workers = 4;
      threads = 4;
    };

    settings = {
      use_default_settings = true;

      general = {
        instance_name = "TowerStack Search";
        debug = false;
        privacypolicy_url = false;
        donation_url = false;
        contact_url = false;
      };

      ##########################################################################
      ## Search
      ##########################################################################
      search = {
        safe_search = 0;
        autocomplete = "duckduckgo";
        default_lang = "en";

        # json is REQUIRED. Every non-browser consumer breaks without it.
        # If a format=json request ever returns HTML, check this first.
        formats = [ "json" "html" ];
      };

      ##########################################################################
      ## Server
      ##########################################################################
      server = {
        port = searxPort;
        bind_address = "0.0.0.0";
        # Off deliberately. deepresearch fires 4-5 concurrent queries per round
        # and a tripped limiter returns 403s indistinguishable from engine
        # failures. Safe because this is LAN/mesh-bound. If the duckdns route is
        # genuinely public, rate-limit at Caddy — not here — or you throttle
        # yourself to protect against strangers.
        limiter = false;

        image_proxy = true;
        http_protocol_version = "1.1";
        base_url = "https://dojos.duckdns.org/sear/";
        method = "GET";
        secret_key = "be970ec5e9edd683605a53997c97a09844aff200c2f96e7a7201fdd6f3ea06d1";
      };

      ##########################################################################
      ## UI — this section is for YOU, not for the models
      ##########################################################################
      ui = {
        static_use_hash = true;
        default_theme = "simple";
        theme_args.simple_style = "dark";
        results_on_new_tab = false;
        infinite_scroll = true;
        search_on_category_select = true;
        query_in_title = true;
      };

      # Tabs you actually use, in the order you want them.
      categories_as_tabs = {
        general = { };
        images = { };
        videos = { };
        news = { };
        it = { };
        science = { };
      };

      ##########################################################################
      ## Plugins
      ##########################################################################
      enabled_plugins = [
        "Hash plugin"
        "Search on category select"
        "Self Information"
        "Tracker URL remover"
        "Unit converter plugin"
        "Basic Calculator"
      ];

      ##########################################################################
      ## Outgoing
      ##########################################################################
      # Sized for concurrent API consumers, not one human browsing.
      outgoing = {
        request_timeout = 5.0;
        max_request_timeout = 30.0;
        useragent_suffix = "";
        pool_connections = 100;
        pool_maxsize = 25;
        enable_http2 = true;
      };

      ##########################################################################
      ## Engines
      ##########################################################################
      engines = [
        ## --- Majors ----------------------------------------------------------
        { name = "google";      engine = "google";      shortcut = "g";   disabled = false; }
        { name = "bing";        engine = "bing";        shortcut = "b";   disabled = false; }
        { name = "brave";       engine = "brave";       shortcut = "br";  disabled = false; }
        { name = "startpage";   engine = "startpage";   shortcut = "sp";  disabled = false; }
        { name = "mojeek";      engine = "mojeek";      shortcut = "mj";  disabled = false; }
        { name = "yahoo";       engine = "yahoo";       shortcut = "yh";  disabled = false; }
        # Flaky from datacenter IPs — CAPTCHAs / access denied. Kept as
        # fallbacks; don't let either be load-bearing in a research profile.
        { name = "duckduckgo";  engine = "duckduckgo";  shortcut = "ddg"; disabled = false; }
        { name = "qwant";       engine = "qwant";       shortcut = "qw";  disabled = false; }
        { name = "yandex";      engine = "yandex";      shortcut = "yx";  disabled = false; }
        { name = "presearch";   engine = "presearch";   shortcut = "ps";  disabled = false; }

        ## --- Independent indexes ----------------------------------------------
        # The valuable ones. They crawl independently, so cross-engine agreement
        # against these is real signal rather than four mirrors of Google.
        { name = "mwmbl";       engine = "mwmbl";       shortcut = "mw";  disabled = false; }
        { name = "yep";         engine = "yep";         shortcut = "ye";  disabled = false; }

        ## --- Reference ---------------------------------------------------------
        { name = "wikipedia";   engine = "wikipedia";   shortcut = "w";   disabled = false; }
        { name = "wikidata";    engine = "wikidata";    shortcut = "wd";  disabled = false; }

        ## --- Academic ----------------------------------------------------------
        { name = "arxiv";            engine = "arxiv";            shortcut = "arx"; disabled = false; }
        { name = "google scholar";   engine = "google_scholar";   shortcut = "gs";  disabled = false; }
        { name = "pubmed";           engine = "pubmed";           shortcut = "pm";  disabled = false; }
        { name = "semantic scholar"; engine = "semantic_scholar"; shortcut = "se";  disabled = false; }

        ## --- News / social -----------------------------------------------------
        { name = "google news"; engine = "google_news"; shortcut = "gn"; disabled = false; }
        { name = "reddit";      engine = "reddit";      shortcut = "r";  disabled = false; }

        ## --- Code / Q&A ---------------------------------------------------------
        { name = "github";      engine = "github";      shortcut = "gh"; disabled = false; }
        # api_site is MANDATORY for the stackexchange adapter — omitting it is
        # what breaks the engine. Three names, one adapter:
        {
          name = "stackoverflow"; engine = "stackexchange"; shortcut = "st";
          api_site = "stackoverflow"; categories = [ "it" "q&a" ]; disabled = false;
        }
        {
          name = "askubuntu"; engine = "stackexchange"; shortcut = "ubuntu";
          api_site = "askubuntu"; categories = [ "it" "q&a" ]; disabled = false;
        }
        {
          name = "superuser"; engine = "stackexchange"; shortcut = "su";
          api_site = "superuser"; categories = [ "it" "q&a" ]; disabled = false;
        }
      ];
    };
  };

  ############################################################################
  ## Deep-search pagination proxy
  ############################################################################
  # Runs on mcpo
  systemd.services.searxng-proxy = {
    description = "SearXNG deep-search pagination proxy";
    after = [ "network.target" "searx.service" ];
    wants = [ "searx.service" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      SEARXNG_URL = "http://localhost:${toString searxPort}";
      MAX_PAGES = "5";
      PROXY_PORT = toString proxyPort;
      REQUEST_TIMEOUT = "30";
    };

    serviceConfig = {
      Type = "simple";
      ExecStart = "${proxyPython}/bin/python3 ${proxyScript}";
      Restart = "always";
      RestartSec = 15;
      User = "tower";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  ############################################################################
  ## Firewall
  ############################################################################
  # bind_address is 0.0.0.0 so Titan and Dacrib reach it over the mesh.
  # Scope the opening to wg0 rather than opening it globally.
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ searxPort proxyPort ];
}
