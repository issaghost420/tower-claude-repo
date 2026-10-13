{ config, pkgs, lib, ... }:

{
  # ==========================================
  # 12. JOURNAL & NIX HOUSEKEEPING
  # ==========================================
  # Limit journal size to prevent runaway log spam from eating disk
  services.journald.extraConfig = ''
    SystemMaxUse=10G
    SystemMaxFileSize=100M
  '';
}
