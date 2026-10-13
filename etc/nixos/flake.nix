{
  description = "Tower NixOS Configuration with Lanzaboote Secure Boot";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-ladybird.url = "github:schembriaiden/nixpkgs/c21d41d5cb37d8e496d23152f0bb0bc3a4b5e9a7";
    nixpkgs-openwebui.url = "github:NixOS/nixpkgs/93178f6a00c22fcdee1c6f5f9ab92f2072072ea9";
    zedless.url = "git+https://dojos.duckdns.org/git/edgecase/zedless.git";
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, nixpkgs-openwebui, nixpkgs-ladybird, lanzaboote, zedless, ... }: { # REMOVED: claude-code, openclaw, home-manager, plasma-manager
    nixosConfigurations.tower = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit nixpkgs-openwebui nixpkgs-ladybird zedless; };
      modules = [
        { nixpkgs.hostPlatform = "x86_64-linux"; }
        lanzaboote.nixosModules.lanzaboote
        ({ pkgs, lib, ... }: {
          boot.loader.systemd-boot.enable = lib.mkForce false;
          boot.lanzaboote = {
            enable = true;
            pkiBundle = "/var/lib/sbctl";
          };
        })
        ./hosts
        ./overlays
      ];
    };
  };
}
