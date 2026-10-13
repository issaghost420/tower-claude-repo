{ config, pkgs, lib, ... }:
#let
#  vaultDataDir = "/home/tower/archive-of-infinite-fold/tower-data-plain/openwebui";
#  whisperModels = {
#    base = pkgs.fetchurl {
#      url = "https://openaipublic.azureedge.net/main/whisper/models/ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e/base.pt";
#      hash = "sha256-7ToLaxwO34ea2bEbGvWg5qtduSBfiR9mj4sObGMm404=";
#    };
#    large-v3 = pkgs.fetchurl {
#      url = "https://openaipublic.azureedge.net/main/whisper/models/e5b1a55b89c1367dacf97e3e19bfd829a01529dbfdeefa8caeb59b3f1b81dadb/large-v3.pt";
#      hash = "sha256-5bGlW4nBNn2s+X4+Gb/YKaAVKdv97vqMrrWbPxuB2ts=";
#    };
#    large-v3-turbo = pkgs.fetchurl {
#      url = "https://openaipublic.azureedge.net/main/whisper/models/aff26ae408abcba5fbf8813c21e62f0941638c5f6eebfb145be0c9839262a19a/large-v3-turbo.pt";
#      hash = "sha256-r/Jq5Airy6X7+IE8IeYrCUFjjF9u6/sUW+DJg5JioZo=";
#    };
#  };
#in
{
  services.open-webui = {
    enable = true;
    package = pkgs.open-webui;
    port = 8080;
    host = "0.0.0.0";
    stateDir = "/home/tower/archive-of-infinite-fold/tower-data-plain/openwebui";
    environment = {
      SCARF_NO_ANALYTICS = "true";
      DO_NOT_TRACK = "true";
      ANONYMIZED_TELEMETRY = "false";
      ENABLE_OPENTELEMETRY = "false";
      OPENAI_API_BASE_URL = "http://localhost:1234/v1";
      DEFAULT_USER_THEME = "dark";
      WEBUI_BANNERS_DISMISSED = "true";
#      OFFLINE_MODE = "true";
      OLLAMA_BASE_URL = "http://localhost:1234";
#      RAG_EMBEDDING_ENGINE = "ollama";
      RAG_EMBEDDING_MODEL = "nomic-embed-text:latest";
      RAG_CHUNK_SIZE = "1500";
      RAG_CHUNK_OVERLAP = "150";
      RAG_SYSTEM_CONTEXT = "true";
      ENABLE_RAG_WEB_SEARCH = "true";
      RAG_WEB_SEARCH_ENGINE = "searxng";
      ENABLE_KB_EXEC = "true";
      SEARXNG_QUERY_URL = ''http://localhost:8890/search?q=<query>'';
      RAG_WEB_SEARCH_RESULT_COUNT = "20";
      WEB_SEARCH_RESULT_COUNT = "20";
      WEBUI_HEADER_INJECTION = ''
        <script>
        document.documentElement.classList.add('dark');
        localStorage.setItem('theme', 'dark');
        </script>
      '';
    }; 
    environmentFile = "/home/tower/.secrets/owui-lms.env";
  };

  systemd.services.open-webui.wantedBy = lib.mkForce [];
  systemd.services.open-webui.serviceConfig = {
    User = lib.mkForce "tower";
    Group = lib.mkForce "users";
    DynamicUser = lib.mkForce false;
    ProtectHome = lib.mkForce false;
    PrivateUsers = lib.mkForce false;
    StateDirectory = lib.mkForce "";
    WorkingDirectory = lib.mkForce "/home/tower/archive-of-infinite-fold/tower-data-plain/openwebui";
    EnvironmentFile = "/home/tower/.secrets/openwebui.env";
  };

#  systemd.services.esphome.serviceConfig.BindPaths = [
#    "/home/tower/tools/esphome/config:/var/lib/esphome/config"
#  ];

#  systemd.services.init-towerstack-network = {
#     description = "Create towerstack podman network";
#     after = [ "network-online.target" ];
#     wants = [ "network-online.target" ];
#     wantedBy = [ "multi-user.target" ];
#     before = [
#       "chatterbox.service"
#       "fish-gpu0.service"
#       "fish-gpu1.service"
#     ];
#     serviceConfig = {
#       Type = "oneshot";
#       RemainAfterExit = true;
#     };
#     script = ''
#       ${pkgs.podman}/bin/podman network exists towerstack || \
#         ${pkgs.podman}/bin/podman network create towerstack
#     '';
#  };

  systemd.services.ensure-chatterbox-caches = {
    description = "Ensure Chatterbox persistent cache directories exist";
    after = [ "local-fs.target" ];
    before = [ "chatterbox.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /home/tower/towerstack/chatterbox/torch_compile_cache
      mkdir -p /home/tower/towerstack/chatterbox/triton_cache
      chmod 777 /home/tower/towerstack/chatterbox/torch_compile_cache
      chmod 777 /home/tower/towerstack/chatterbox/triton_cache
      echo "Chatterbox cache directories ready"
    '';
  };

#  #virtualisation.oci-containers.containers.nemo-stt = {
#  #  image = "canary-qwen-stt:latest";
#  #  ports = [ "8091:8093" ];
#  #  volumes = [
#  #    "/home/tower/towerstack/nemo-models:/models"
#  #  ];
#  #  environment = {
#  #    NVIDIA_VISIBLE_DEVICES = "0";
#  #    CUDA_VISIBLE_DEVICES = "0";
#  #    HF_HOME = "/models";
#  #    CANARY_DEVICE = "cuda:0";
#  #    CANARY_PORT = "8093";
#  #  };
#  #  extraOptions = [
#  #    "--device=nvidia.com/gpu=all"
#  #    "--network=towerstack"
#  #    "--shm-size=8g"
#  #    "--memory-reservation=8g"
#  #    "--pull=never"
#  #  ];
#  #};

  virtualisation.oci-containers.containers.chatterbox = {
    image = "chatterbox";
    ports = [ "5021:8000" ];
    volumes = [
      "/home/tower/towerstack/chatterbox/model_cache:/app/model_cache"
      "/home/tower/towerstack/chatterbox/reference_audio:/app/reference_audio"
      "/home/tower/towerstack/chatterbox/outputs:/app/outputs"
      "/home/tower/towerstack/chatterbox/voices:/app/voices"
      "/home/tower/towerstack/chatterbox/logs:/app/logs"
      "/home/tower/towerstack/chatterbox/config.yaml:/app/config.yaml"
      "/home/tower/towerstack/chatterbox/.cache/huggingface:/app/hf_cache"
      "/home/tower/towerstack/chatterbox/torch_compile_cache:/tmp/torchinductor"
      "/home/tower/towerstack/chatterbox/triton_cache:/tmp/triton_cache"
    ];
    environment = {
      NVIDIA_VISIBLE_DEVICES = "0";
      CUDA_VISIBLE_DEVICES = "0";
      NVIDIA_DRIVER_CAPABILITIES = "compute,utility";
      TORCHINDUCTOR_CACHE_DIR = "/tmp/torchinductor";
      TORCH_COMPILE_CACHE_SIZE_LIMIT = "128";
      TRITON_CACHE_DIR = "/tmp/triton_cache";
      CUDA_MODULE_LOADING = "LAZY";
      PYTHONUNBUFFERED = "1";
    };
    extraOptions = [
      "--device=nvidia.com/gpu=0"
      "--network=towerstack"
      "--ulimit=memlock=-1:-1"
      "--shm-size=8g"
      "--security-opt=seccomp=unconfined"
      "--pull=never"
    ];
  };

  systemd.services."podman-chatterbox" = {
    wantedBy = lib.mkForce [ ];
    serviceConfig.Restart = lib.mkForce "no";
  };
  
  virtualisation.oci-containers.containers.fish-gpu0 = {
    image = "localhost/fish-speech-webui";
    ports = [ "7860:7860" ];
    volumes = [
      "/home/tower/cleanroom/fish-speech/checkpoints:/app/checkpoints"
      "/home/tower/cleanroom/fish-speech/references:/app/references"
      "/home/tower/cleanroom/fish-speech/outputs:/app/outputs"
    ];
    environment = {
      COMPILE = "1";
      LIBRARY_PATH = "/usr/local/cuda/lib64/stubs";
    };
    extraOptions = [
      "--device=nvidia.com/gpu=0"
      "--security-opt=unmask:/dev/pts"
      "--restart=no"
    ];
  };

  systemd.services."podman-fish-gpu0" = {
    wantedBy = lib.mkForce [ ];
    serviceConfig.Restart = lib.mkForce "no";
    preStart = ''
      ${pkgs.coreutils}/bin/echo ">>> Starting Fish Speech — Gradio only (no awesome_webui)" | ${pkgs.systemd}/bin/systemd-cat -t fish-speech-webui
    '';
  };

  virtualisation.oci-containers.containers.fish-gpu1 = {
    image = "localhost/fish-speech-server:cuda";
    ports = [ "8060:8080" ];
    volumes = [
      "/home/tower/cleanroom/fish-speech/checkpoints:/app/checkpoints"
      "/home/tower/cleanroom/fish-speech/references:/app/references"
      "/home/tower/cleanroom/fish-speech/outputs:/app/outputs"
    ];
    environment = {
      COMPILE = "1";
      LIBRARY_PATH = "/usr/local/cuda/lib64/stubs";
      LD_LIBRARY_PATH = "/app/.venv/lib/python3.12/site-packages/nvidia/cuda_runtime/lib:/app/.venv/lib/python3.12/site-packages/nvidia/cublas/lib:/app/.venv/lib/python3.12/site-packages/nvidia/cudnn/lib:/app/.venv/lib/python3.12/site-packages/nvidia/cufft/lib:/app/.venv/lib/python3.12/site-packages/nvidia/curand/lib:/app/.venv/lib/python3.12/site-packages/nvidia/cusolver/lib:/app/.venv/lib/python3.12/site-packages/nvidia/cusparse/lib:/app/.venv/lib/python3.12/site-packages/nvidia/nccl/lib:/app/.venv/lib/python3.12/site-packages/nvidia/nvjitlink/lib";
    };
    extraOptions = [
      "--device=nvidia.com/gpu=1"
      "--security-opt=unmask:/dev/pts"
      "--restart=no"
      "--pull=never"
    ];
  };

  systemd.services."podman-fish-gpu1" = {
    wantedBy = lib.mkForce [ ];
    serviceConfig.Restart = lib.mkForce "no";
  };

## MOVED TO /etc/nixos/modules/services/mcpo.nix
#  systemd.services.mcpo = {
#    description = "MCP-to-OpenAPI proxy for Open WebUI";
#    after = [ "network.target" ];
#    wantedBy = [ "multi-user.target" ];
#    serviceConfig = {
#      Type = "simple";
#      ExecStart = "/home/tower/tools/mcp-servers/mcpo-venv/bin/mcpo --port 8001 --config /home/tower/tools/mcp-servers/mcp.json";
#      User = "tower";
#      Restart = "always";
#      RestartSec = 5;
#      Environment = "PATH=${pkgs.nodejs}/bin:${pkgs.coreutils}/bin";
#    };
#  };

  services.tumbler.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.containers.registries.search = [ "docker.io" ];

  virtualisation.oci-containers.containers.ollama = {
    image = "docker.io/ollama/ollama:latest";
    ports = [ "11434:11434" ];
    volumes = [
      "/home/tower/towerstack/ollama:/root/.ollama"
      "/home/tower/archive-of-infinite-fold/tower-data-plain/lm-studio/models:/lm-models:ro"
      "/home/tower/archive-of-infinite-fold/tower-data-plain/lm-studio/models:/home/tower/archive-of-infinite-fold/tower-data-plain/lm-studio/models"
    ];
    environment = {
      LIBRARY_PATH = "/usr/local/cuda/lib64/stubs";
      NVIDIA_VISIBLE_DEVICES = "0,1";
      CUDA_VISIBLE_DEVICES = "0,1";
      NVIDIA_DRIVER_CAPABILITIES = "compute,utility";
      OLLAMA_HOST = "0.0.0.0:11434";
      OLLAMA_KEEP_ALIVE = "24h";
    };
    extraOptions = [
#      "--device=nvidia.com/gpu=1"
      "--network=towerstack"
      "--shm-size=32g"
    ];
  };

  systemd.services."podman-ollama" = {
    wantedBy = lib.mkForce [ ];
    serviceConfig.Restart = lib.mkForce "no";
    preStart = ''
      ${pkgs.coreutils}/bin/echo ">>> Podman Ollama initialized manually" | ${pkgs.systemd}/bin/systemd-cat -t ollama-container
    '';
  };



    # ======================================================#
   ##  >= * ! *  |  * ! *  |  * ! *  |  * ! *  |  * ! * <=  ##
  ### ===#|===|#===#|===|#===#|===|#===#|===|#===#|===|#=== ###
 ##===## /,\=/,\# #/,\=/,\# #/,\=/,\# #/,\=/,\# #/,\=/,\ ##===##
#===============================================================#
    #  OLLAMA - Disabled - embedding model routed thru LMS   #
   ##    Olamma overlays - /etc/nixos/overlays/ollama.nix    ##
  ### Enable ollama.nix in ../..overlays/default.nix to use  ###
 ####         Service not building as of 7-27-26             ####
#####========================================================#####
#================================================================#
  services.ollama = {          ##   ##                   ##   ## 
    enable = true;             ##   ##                   ##   ##
    package = pkgs.ollama-cuda;##   ##                   ##   ##
  };                           ##   ##                   ##   ##
#
  systemd.services.ollama.environment = {
#    OLLAMA_HOST = lib.mkForce "0.0.0.0:11434";  # Override default - listen on all interfaces (accessible from Docker)
    OLLAMA_KEEP_ALIVE = "24h";
#    OLLAMA_GPU_LAYERS = "-1";
    OLLAMA_LLM_LIBRARY = "cuda";
  };

#    };
#  };
}
