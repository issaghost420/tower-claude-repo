{ config, pkgs, lib, ... }:

let
  towerHome = "/home/tower";

  # DSDT patch: merge fragmented 32-bit MMIO regions (f0000000-f1ffffff + f2000000-f6ffffff)
  # so GPU1 bridge gets a 64MB-aligned window. Fixes BAR 0 allocation failure on dual RTX 5090.
  # See ~/towerstack/gpu-missing-probem-identified.md for full investigation.
### Testing without 6-26-26 ###
#  patchedDsdtCpio = pkgs.runCommand "patched-dsdt-cpio" {} ''
#    mkdir -p kernel/firmware/acpi
#    cp ${./dsdt-patched.aml} kernel/firmware/acpi/dsdt.aml
#    find kernel | ${pkgs.cpio}/bin/cpio -o -H newc > $out
#  '';

in
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.efi.efiSysMountPoint = "/boot/efi";

  # Matching gen 125 baseline (stable, both GPUs, 32 threads)
  # If 6.12 causes issues, try linuxPackages_6_18 next
  boot.kernelPackages = pkgs.linuxPackages_6_12;

  # Load Aqua Computer drivers early + VFIO modules
  boot.kernelModules = [ "aquacomputer_d5next" "i2c-dev" "vfio" "vfio_iommu_type1" "vfio_pci" ];

  boot.kernelParams = [
#    "iommu=pt"                # Bypass IOMMU translation overhead
    "pcie_aspm=off"
    "pcie_realloc"            # Helps with BAR allocation (test without when new board arrives) 6-27-26
    "quiet"
    "splash"
    "nvidia-drm.modeset=1"
#    "nvidia-drm.fbdev=1" #disabled 7-24-26 # NVIDIA takes over framebuffer, prevents simpledrm Unknown-1 phantom
    "nvidia.NVreg_OpenRmEnableUnsupportedGpus=1"  # RTX 5090 support on 580.x stable driver (from gen 125)
    "usbcore.autosuspend=-1"  # Prevent USB autosuspend for Aqua Computer Octo stability
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.zpool=z3fold"
    "zswap.max_pool_percent=25"
    # removed vs gen 125: threadirqs  # readded these 6-26-26, if stable after July remove note: pcie_aspm=off, pci=realloc
  ];

  boot.kernel.sysctl = {
    "vm.swappiness" = 100;
    "vm.vfs_cache_pressure" = 50;
  };

  boot.tmp.cleanOnBoot = true;

  systemd.services.nvidia-cdi-generator = {
    description = "Generate NVIDIA Container Device Interface (CDI) spec";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-udev-settle.service" ];    
    # Explicitly hand the systemd unit the path to the live NVIDIA drivers
    environment = {
      LD_LIBRARY_PATH = "/run/opengl-driver/lib:/run/opengl-driver-32/lib";
    };
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = ''
        ${config.hardware.nvidia-container-toolkit.package}/bin/nvidia-ctk cdi generate \
          --output=/etc/cdi/nvidia.yaml
      '';
    };
  };

  systemd.services.nvidia-powerlimit = {
    description = "Set GPU0 power limit to 400W";
    after = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ]; 
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -i 0 -pm 1"
        "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -i 0 -pl 400"
      ];
      RemainAfterExit = true;
    };
  };


#  system.activationScripts.generateCdiNvidia = lib.mkForce {
#    text = let
#      nctk = config.hardware.nvidia-container-toolkit.package;
#    in ''
#      ${nctk}/bin/nvidia-ctk cdi generate \
#        --mode=csv \
#        --nvidia-ctk-path="${nctk}/bin/nvidia-ctk" \
#        --output=/etc/cdi/nvidia.yaml || true
#    '';
#    deps = [];
#  };
}
