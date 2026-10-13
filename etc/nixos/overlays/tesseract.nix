{ config, pkgs, lib, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages.overrideScope (kfinal: kprev: {
        spectacle = kprev.spectacle.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [ final.tesseract ];
          runtimeInputs = (old.runtimeInputs or [ ]) ++ [ final.tesseract ];
          postFixup = (old.postFixup or "") + ''
            wrapProgram $out/bin/spectacle \
              --set TESSDATA_PREFIX "${final.tesseract}/share/tessdata"
          '';
        });
      });
    })
  ];
}
