{ config, pkgs, lib, ... }:

{
  # Btrfs device scan (systemd stage 1 replacement for postDeviceCommands)
  boot.initrd.systemd.services.btrfs-scan = {
    description = "Scan for Btrfs devices";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-udev-settle.service" ];
    before = [ "sysroot.mount" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.btrfs-progs}/bin/btrfs device scan";
    };
  };

  fileSystems."/data" = {
    device = "/dev/disk/by-label/ARCHIVE";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  fileSystems."/990" = {
    device = "/dev/disk/by-label/990";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  fileSystems."/sata" = {
    device = "/dev/disk/by-label/SATA";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  fileSystems."/hdd2" = {
    device = "/dev/disk/by-label/HDD2";
    fsType = "ext4";
    options = [ "noatime" "nofail" ];
  };

  fileSystems."/mnt/titan" = {
    device = "titan@192.168.50.103:/";  # 97:/"; 
    fsType = "fuse.sshfs";
    options = [
      "noauto"                                   # Don't mount at boot
      "x-systemd.automount"                      # Mount on first access
      "x-systemd.idle-timeout=300"               # Unmount after 5min idle
      "x-systemd.mount-timeout=10"               # Don't hang forever if offline
      "reconnect"                                # Auto-reconnect on drop
      "ServerAliveInterval=15"                   # Keepalive
      "ServerAliveCountMax=3"                    # Give up after 3 missed keepalives
      "IdentityFile=/home/tower/.ssh/id_ed25519"
      "allow_other"                              # Let OGnee access it
      "_netdev"                                  # Mark as network device
    ];
  };

  fileSystems."/mnt/dacrib" = {
    device = "dacrib@192.168.50.141:/";
    fsType = "fuse.sshfs";
    options = [
      "noauto"
      "x-systemd.automount"
      "x-systemd.idle-timeout=300"
      "x-systemd.mount-timeout=10"
      "reconnect"
      "ServerAliveInterval=15"
      "ServerAliveCountMax=3"
      "IdentityFile=/home/tower/.ssh/id_ed25519"
      "allow_other"
      "default_permissions"
      "_netdev"
    ];
  };
}
