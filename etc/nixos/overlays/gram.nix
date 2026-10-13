{ config, pkgs, lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      gram = prev.gram.overrideAttrs (old: {
        src = prev.fetchurl {
          inherit (old.src) url;
          hash = "sha256-/Y75IW0qqb5JqGZ8BI8xd1oUnc8gfOISO7/M/Txo9a8=";
        };
      });
    })
  ];
}
