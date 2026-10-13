{ config, pkgs, lib, ... }:
{
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = true; # Changed back from false 7-23-26 
    nvidiaSettings = true;

    package = config.boot.kernelPackages.nvidiaPackages.stable_595; # <-- pinned stable, switched to this 9-28-26 to test if gpu falling off the bus issues are as frequent


## THIS DRIVER SERVED ME KIND OF OK, RETIRED 9-28 TO TEST STABLE_595 ## if re-enabling also re-enable ./.overlays/nvidia-610.nix & uncomment it in overlays/default.nix
#    package = let 
#      pkgsKernel = config.boot.kernelPackages;
#    in pkgsKernel.nvidiaPackages.mkDriver {
#      version = "610.43.02";
#      sha256_64bit = "sha256-MDSgVLtM33dS/43CclZMsQVROAS/9TU4lFkBsWyndGM=";
#      openSha256 = "sha256-hP5NVZZ4vGsACHLmUDKq4uckpd/kn1GxCSYnnJfAuBs=";
#      settingsSha256 = "sha256-0YAhufRgjDW+uR+kjaTb154fibpcDw8QowfrucoZsKE=";
#      persistencedSha256 = "sha256-Whgv9X+v2fRhzliOl2LzltY9v1SxDafFfv3IUPqj/hk=";
#    };
#  environment.variables = {
#    KWIN_DRM_DEVICES = "/dev/dri/by-path/pci-0000:01:00.0-card";
#  };
    powerManagement.enable = true;
  };
}
