{ ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      lmstudio = (prev.lmstudio.override {
        url = "https://installers.lmstudio.ai/linux/x64/0.4.26-4/LM-Studio-0.4.26-4-x64.AppImage";
        hash = "sha256-LGKjipOtA8pdqu8ogEiAvhZ1Zng/+vwXPOLhyxC3VS4=";
      }).overrideAttrs (old: {
        extraInstallCommands = builtins.replaceStrings
          [ "0x0" "lm-studio.desktop" "Exec=AppRun --no-sandbox %U" ]
          [ "512x512" "ai.elementlabs.lmstudio.desktop" "Exec=AppRun %U" ]
          old.extraInstallCommands;
      });
    })
  ];
}
