{ config, pkgs, lib, ... }:
{
  # ==========================================
  # 10. USER CONFIGURATION
  # ==========================================

  users.users.tower = {
    isNormalUser = true;
    home = "/home/tower";
    extraGroups = [ "audio" "input" "podman" "libvirtd" "networkmanager" "video" "wheel" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIADpYk4CVtLdxxuwBQsIztej8k5VlXH/LQYbTBvwggap titan@titan"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICwa8dRFXdX+OALlHHBy5R2gM5WDfxmM0LxQLkLly4LQ dacrib@dacrib"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOrz4BDz7rEuYbcPmcVpR0USTF9i0lbXWeO0QnDJD3L2 root@dacrib"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFky0330JaFSCvIxCtJxLPFoB32Tu+Pms9rhR7KuI9cs root@titan"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIdWJsbPC07TIpZkecQ8f0vNyUSKL0QPSHGJxKXuj/u9 merk@LAPTOP" #-JG3H3KQ4
    ];
  };

  security.sudo.extraRules = [
    {
      users = [ "tower" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
