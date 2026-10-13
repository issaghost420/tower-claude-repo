# =============================================================================
# IMMICH — Self-Hosted Photo Management
# NixOS OCI Containers (Podman) with CUDA GPU Acceleration
# Start manually: sudo systemctl start podman-immich-{valkey,postgres,server,ml}
# =============================================================================
#
# Architecture:
#   immich-server       → Web UI + API (port 2283)
#   immich-ml           → CLIP embeddings, face recognition, OCR (GPU-accelerated)
#   immich-postgres     → PostgreSQL + VectorChord for vector search
#   immich-valkey       → Redis-compatible cache
#
# All containers communicate via the 'immich' Podman network.
# ML container gets GPU access via CDI (nvidia.com/gpu=all).
#
# Usage:
#   4. Rebuild: sudo nixos-rebuild switch
#   5. Access: http://192.168.50.140:2283
#   6. Point external libraries at /home/tower/immich/external (read-only)
#      in Admin → External Libraries after first login
#
# To import Apple Photos export:
#   Copy your Apple Photos export to /home/tower/immich/external/apple-photos/
#   Then in Immich Admin UI → External Libraries → Add path: /external/apple-photos
#   Immich will index without copying — originals stay in place.
#
# =============================================================================

{ config, lib, pkgs, ... }:

let
  uploadDir    = "/home/tower/archive-of-infinite-fold/tower-data-plain/immich/library";
  postgresDir  = "/home/tower/.local/immich/postgres";
  modelCache   = "/home/tower/.local/immich/model-cache";
  externalLibs = "/home/tower/archive-of-infinite-fold/tower-data-plain/immich/external";   # Apple Photos export goes here

  dbUser       = "postgres";
  dbName       = "immich";
  timezone     = "America/Los_Angeles";

  # Pin to a release tag or use "release" for latest stable
  immichVersion = "v3.0.0-rc.2";
in
{
  # ===========================================================================
  # Podman Network — all Immich containers talk over this
  # ===========================================================================
  systemd.services.immich-network = {
    description = "Create Immich Podman Network";
    after = [ "podman.service" ];
    before = [
      "podman-immich-server.service"
      "podman-immich-ml.service"
      "podman-immich-postgres.service"
      "podman-immich-valkey.service"
    ];
    wantedBy = [ ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.podman}/bin/podman network create immich --ignore";
      ExecStop  = "${pkgs.podman}/bin/podman network rm immich --force";
    };
  };

  # ===========================================================================
  # Valkey (Redis-compatible cache)
  # ===========================================================================
  virtualisation.oci-containers.containers.immich-valkey = {
    image = "docker.io/valkey/valkey:8-bookworm";
    extraOptions = [
      "--network=immich"
      "--health-cmd=valkey-cli ping || exit 1"
      "--health-interval=10s"
      "--health-timeout=5s"
      "--health-retries=5"
    ];
  };

  # ===========================================================================
  # PostgreSQL + VectorChord (vector search for CLIP embeddings + faces)
  # ===========================================================================
  virtualisation.oci-containers.containers.immich-postgres = {
    image = "ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0";
    volumes = [
      "${postgresDir}:/var/lib/postgresql/data"
    ];
    environment = {
      POSTGRES_USER         = dbUser;
      POSTGRES_DB           = dbName;
      POSTGRES_INITDB_ARGS  = "--data-checksums";
    };
    environmentFiles = [ "/home/tower/.secrets/immich.env" ];
    extraOptions = [
      "--network=immich"
      "--health-cmd=pg_isready -d ${dbName} -U ${dbUser} || exit 1"
      "--health-interval=10s"
      "--health-timeout=5s"
      "--health-retries=5"
    ];
  };

  # ===========================================================================
  # Immich Server — Web UI, API, background workers
  # ===========================================================================
  virtualisation.oci-containers.containers.immich-server = {
    image = "ghcr.io/immich-app/immich-server:${immichVersion}";
    ports = [ "2283:2283" ];
    volumes = [
      "${uploadDir}:/data"
      "${externalLibs}:/external:ro"
      "/home/tower/archive-of-infinite-fold/tower-data-plain/ic-photos-zips:/external/icloud-zips:ro"
      "/home/tower/archive-of-infinite-fold/tower-data-plain/immich-photos/comf:/external/immich-photos/comf:ro"
      "/data/aoif/data-pile/pictures:/external/spinner-pics:ro"
#      "/home/tower/Pictures:/external/active:ro"
      "/etc/localtime:/etc/localtime:ro"
    ];
    environment = {
      DB_PORT          = "5432";
      DB_HOSTNAME      = "immich-postgres";
      DB_USERNAME      = dbUser;
      DB_DATABASE_NAME = dbName;
      REDIS_HOSTNAME = "immich-valkey";
      REDIS_PORT     = "6379";
      IMMICH_MACHINE_LEARNING_URL = "http://immich-ml:3003";  # Can also be set in Admin UI → Settings
      IMMICH_HOST = "0.0.0.0";
      TZ = timezone;
    };
    environmentFiles = [ "/home/tower/.secrets/immich.env" ];
    dependsOn = [ "immich-valkey" "immich-postgres" ];
    extraOptions = [
      "--network=immich"
    ];
  };

  # ===========================================================================
  # Immich Machine Learning — CLIP, face recognition, OCR
  # ===========================================================================
  virtualisation.oci-containers.containers.immich-ml = {
    image = "ghcr.io/immich-app/immich-machine-learning:${immichVersion}-cuda";
    volumes = [
      "${modelCache}:/cache"
    ];
    environment = {
      IMMICH_HOST = "0.0.0.0";
      MACHINE_LEARNING_WORKERS         = "1";                 # Each worker duplicates models in VRAM, so don't crank this
      MACHINE_LEARNING_WORKER_TIMEOUT  = "120";
      MACHINE_LEARNING_REQUEST_THREADS = "64";                 # Request threads — start here, tune up if GPU is underutilized
    };
    extraOptions = [
      "--network=immich"
      "--device=nvidia.com/gpu=1"
      "--security-opt=unmask:/dev/pts"
    ];
  };

  # ===========================================================================
  # Service ordering — ensure network exists before any container starts
  # ===========================================================================
  systemd.services."podman-immich-server".after      = [ "immich-network.service" ];
  systemd.services."podman-immich-server".requires   = [ "immich-network.service" ];
  systemd.services."podman-immich-ml".after          = [ "immich-network.service" ];
  systemd.services."podman-immich-ml".requires       = [ "immich-network.service" ];
  systemd.services."podman-immich-postgres".after    = [ "immich-network.service" ];
  systemd.services."podman-immich-postgres".requires = [ "immich-network.service" ];
  systemd.services."podman-immich-valkey".after      = [ "immich-network.service" ];
  systemd.services."podman-immich-valkey".requires   = [ "immich-network.service" ];
  systemd.services."podman-immich-server".wantedBy   = lib.mkForce [ ];
  systemd.services."podman-immich-ml".wantedBy       = lib.mkForce [ ];
  systemd.services."podman-immich-postgres".wantedBy = lib.mkForce [ ];
  systemd.services."podman-immich-valkey".wantedBy   = lib.mkForce [ ];
}
