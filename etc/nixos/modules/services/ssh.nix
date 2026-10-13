{ config, pkgs, lib, ... }:
{
  # ==========================================
  # 8. SSH SERVER
  # ==========================================
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };
}
