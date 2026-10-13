{ config, pkgs, lib, nixpkgs-ladybird, ... }:
let
  ladybirdPkgs = import nixpkgs-ladybird { system = "x86_64-linux"; };
in {
  nixpkgs.overlays = [
    (final: prev: {
      ladybird = ladybirdPkgs.ladybird.override {
      };
    })
  ];
}
