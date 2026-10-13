{ config, pkgs, lib, ... }:
{

#  nixpkgs.config.permittedInsecurePackages = [
#    "glances"
#    "ladybird-0-unstable-2026-06-05"
#  ];

  # ==========================================
  # 4. DESKTOP (KDE PLASMA 6)
  # ==========================================
  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = false;  # X11 greeter for remote xdotool access
  services.displayManager.autoLogin.enable = true;
  services.displayManager.autoLogin.user = "tower";
  services.displayManager.defaultSession = "plasma";  # Wayland session, just X11 greeter
  services.desktopManager.plasma6.enable = true;
#  services.xserver.deviceSection = ''
#    Option "Device" "PCI:6:0:0"
#  '';

  # Ensure non-native KDE apps can access the file system
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.kdePackages.xdg-desktop-portal-kde ];
    config.common.default = [ "kde" ];
  };

  # force 4th display output
  environment.sessionVariables = {
    KWIN_DRM_NO_DIRECT_SCANOUT = "1";
  };  

 # Disabling fwupd since it was constantly polling cdn.fwupd.org for "metadata"
  services.fwupd.enable = lib.mkForce false;

  # Ensure GTK apps save settings in KDE
  programs.dconf.enable = true;

  # Hyprland
  programs.hyprland.enable = false;

  # Allow FUSE mounts with allow_other (needed for gocryptfs + containers)
  programs.fuse.userAllowOther = true;

  # Thunar req's
  programs.thunar.enable = false;
  programs.xfconf.enable = true; 
  services.gvfs.enable = true; # For mounting/trash support

  # Disable baloo file indexer (privacy: prevents recent files tracking)
  environment.etc."xdg/baloofilerc".text = ''
    [Basic Settings]
    Indexing-Enabled=false
  '';

  # Disable KDE Wallet (incompatible with autologin - causes constant unlock prompts)
  environment.etc."xdg/kwalletrc".text = ''
    [Wallet]
    Enabled=true
  '';
  security.pam.services.login.kwallet.enable = true;
  security.pam.services.sddm.kwallet.enable = true;  # if you ever switch back to SDDM login

  security.rtkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id == "org.kde.kio.admin.commands" && subject.isInGroup("wheel") && subject.active) {
        return polkit.Result.YES;
      }
    });
  '';

  # ==========================================
  # 4a. FONTS
  # ==========================================
  fonts.packages = with pkgs; [
    noto-fonts                    # Clean sans-serif for general UI
    noto-fonts-color-emoji        # Emoji support (the reason we're here)
    nerd-fonts.jetbrains-mono     # JetBrains Mono + Nerd Font icons (terminal/code)
    nerd-fonts.fira-code          # Fira Code + ligatures + Nerd Font icons
    inter                         # Modern UI font, tight spacing, great for dashboards
    font-awesome                  # Icon font (used by status bars, widgets, etc.)
    twemoji-color-font            # Twitter/X style — cleaner, more stylized

  ];

  fonts.fontconfig.defaultFonts = {
    emoji = [ "Noto Color Emoji" ];
  };

  environment.etc."xdg/mimeapps.list".text = ''
    [Default Applications]
    application/pdf=draw.desktop
    application/json=gram
    application/slq=sqlitebrowser
    application/toml=gram
    audio/mp3=mpv
    audio/opus=mpv
    audio/wav=mpv
    image/heic=nomacs
    image/heif=nomacs
    image/jpeg=nomacs
    image/png=nomacs
    text/csv='libreoffice --calc'
    text/javascript=gram
    text/markdown=gram
    text/richtext=gram
    text/rust=gram
    text/spreadsheet='libreoffice --calc'
    '';

  # CoolerControl (Fan control daemon + GUI)
  programs.coolercontrol.enable = true;
  environment.variables.QTWEBENGINE_CHROMIUM_FLAGS = "--disable-gpu";

  # Input-remapper - Remap keys, mouse buttons, and macros
  # GUI: input-remapper-gtk, CLI: input-remapper-control
  services.input-remapper.enable = true;

  # Ladybird browser (Alpha) 
  programs.ladybird.enable = true;
}
