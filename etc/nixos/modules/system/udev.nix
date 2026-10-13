{ config, pkgs, lib, ... }:

{
  services.udev.extraRules = ''
    KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
    KERNEL=="nvidia-cap*", MODE="0666"
    # Aqua Computer OCTO permissions (0c70:f011)
    SUBSYSTEMS=="usb", ATTRS{idVendor}=="0c70", ATTRS{idProduct}=="f011", MODE="0666", GROUP="users", TAG+="uaccess"
    # MSI Mystic Light RGB
    SUBSYSTEM=="usb", ATTR{idVendor}=="0db0", ATTR{idProduct}=="0076", MODE="0666"
    KERNEL=="hidraw*", ATTRS{idVendor}=="0db0", ATTRS{idProduct}=="0076", MODE="0666"
    # VM evdev passthrough (Razer Viper V2 Pro Mouse)
    SUBSYSTEM=="input", ATTRS{idVendor}=="1532", ATTRS{idProduct}=="00a6", KERNEL=="event*", GROUP="kvm", MODE="0660", TAG+="uaccess"
    # VM evdev passthrough (Keychron Link Keyboard)
    SUBSYSTEM=="input", ATTRS{idVendor}=="3434", ATTRS{idProduct}=="d030", KERNEL=="event*", GROUP="kvm", MODE="0660", TAG+="uaccess"
    # Mini monitor touchscreen (222a:0335) - suppress seat/power events on USB reconnect
    ACTION=="add", ATTRS{idVendor}=="222a", ATTRS{idProduct}=="0335", ATTR{authorized}="0"
    # DDC poll on LG UltraGear which cascades into KScreen crash killing plasmashell
    # threadirqs handles audio IRQ priority now, no need for aggressive batching
    ACTION=="add", SUBSYSTEM=="net", DRIVERS=="r8152", RUN+="${pkgs.ethtool}/bin/ethtool -G $name rx 4096"
    ACTION=="add", SUBSYSTEM=="net", DRIVERS=="r8152", RUN+="${pkgs.ethtool}/bin/ethtool -C $name rx-usecs 2000"
    ACTION=="add", SUBSYSTEM=="net", KERNEL=="enp*", RUN+="${pkgs.ethtool}/bin/ethtool -s $name wol g"
    # Enables WOL 

    # Disabled 6-4-26 to test sleep/WOL fuctionality to save power
    # Disable runtime PM for all PCI devices - workstation mode, no sleeping
#    ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="on"

    # Fix for keychron q6 qmk detection (see /data/aoif/logs-user/VERY-IMPORTANT-KEYCHRON-FIX.md for the usevia.app fix)
    KERNEL=="hidraw*", ATTRS{idVendor}=="3434", ATTRS{idProduct}=="0860", MODE="0660", GROUP="users", TAG+="uaccess", TAG+="udev-acl"
    KERNEL=="hidraw*", ATTRS{idVendor}=="3434", ATTRS{idProduct}=="d030", MODE="0660", GROUP="users", TAG+="uaccess"
    SUBSYSTEM=="hidraw", MODE="0666", GROUP="users", TAG+="uaccess"

  '';
}
