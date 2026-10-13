
{ config, pkgs, lib, ... }:
{

#  nixpkgs.config.permittedInsecurePackages = [
#   "ladybird-0-unstable-2026-06-05"
#   "gram-editor"
#  ];

  imports = [
    ./ladybird.nix
    ./gram.nix
    ./lmstudio.nix
    ./nvidia-595-stable.nix
#    ./nvidia-610.nix
    ./ollama.nix
#    ./owui.nix
    ./owui-unstable.nix
    ./python312-doc-fix.nix
    ./python314-doc-fix.nix
#    ./tesseract.nix
  ];
}
