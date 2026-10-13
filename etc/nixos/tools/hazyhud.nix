# Dependencies for HazyHud v2
{ config, pkgs, lib, ...}: 
{
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib   # libstdc++.so.6 — the error you hit
      libGL
      libxkbcommon
      xcb-util-cursor    # Qt6's xcb plugin wants this
      fontconfig
      freetype
      dbus
      glib
      zlib
      wayland
      libX11
      libxcb
      libXext
      libXi
      libXrender
      libXtst
      xcbutil
      xcbutilimage
      xcbutilkeysyms
      xcbutilrenderutil
      xcbutilwm
    ];
  };
}
