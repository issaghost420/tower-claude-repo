{ pkgs ? import <nixpkgs> { } }:

let
  qtRuntimeLibs = with pkgs; [
    stdenv.cc.cc.lib   # libstdc++.so.6
    libGL
    libxkbcommon
    xcb-util-cursor
    fontconfig
    freetype
    dbus
    glib
    zlib
    wayland
    libxcb
    libX11
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
in
pkgs.mkShell {
  shellHook = ''
    export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath qtRuntimeLibs}:$LD_LIBRARY_PATH
  
    VENV_DIR=""
    if [ -d ".venv" ]; then
      VENV_DIR=".venv"
    elif [ -d "venv" ]; then
      VENV_DIR="venv"
    fi
  
    if [ -z "$VENV_DIR" ]; then
      echo "No venv found — creating .venv..."
      python3 -m venv .venv
      VENV_DIR=".venv"
    fi
  
    source "$VENV_DIR/bin/activate"
    exec zsh
  '';
}
