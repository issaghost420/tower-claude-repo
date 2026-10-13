{ config, pkgs, lib, ... }:
{
  services.gitea = {
    enable = true;
    database.type = "sqlite3";
    lfs.enable = true;
    settings = {
      server = {
        ROOT_URL = "https://dojos.duckdns.org/git/";
        HTTP_PORT = 3000;
        DOMAIN = "dojos.duckdns.org";
        START_SSH_SERVER = true;
        SSH_PORT = 2222;
      };
      service = {
        DISABLE_REGISTRATION = true;
      };
    };
  };
}
