{ config, pkgs, lib, ... }:
let
  pkgs-unstable = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixpkgs-unstable.tar.gz";
    sha256 = "0rzfmis9kwly6af9zdxsnb90zfnvl4mqwkbd62g9g1q6i6vfi5a2";
  }) { config.allowUnfree = true; system = "x86_64-linux"; };

  owui-version = "0.12.0";
  owui-src = pkgs.fetchFromGitHub {
    owner = "open-webui";
    repo = "open-webui";
    tag = "v${owui-version}";
    hash = "sha256-x8Mxy7KHGqC1qmOp6/UsO7ntq07l1jrKTaR9XiOK2d0=";
  };

  owui-0_12_0 = pkgs-unstable.open-webui.overrideAttrs (old: {
    version = owui-version;
    src = owui-src;
    passthru = old.passthru // {
      frontend = old.passthru.frontend.overrideAttrs (_: {
        inherit (owui-src) outPath;
        version = owui-version;
        src = owui-src;
        npmDepsHash = lib.fakeHash; # round 2: paste the "got:" value here
      });
    };
  });

  clean-owui = owui-0_12_0.overridePythonAttrs (old: {
    propagatedBuildInputs = (builtins.filter (pkg:
      let pname = pkg.pname or "";
      in !(builtins.elem pname [
        "opentelemetry-api"
        "opentelemetry-sdk"
        "opentelemetry-exporter-otlp"
        "posthog"
        "amplitude-analytics"
        "google-cloud-storage"
        "azure-storage-blob"
        "boto3"
        "boto3-stubs"
        "s3transfer"
        "openai"
        "anthropic"
        "google-generativeai"
        "google-ai-generativelanguage"
        "langchain"
      ])
    ) (old.propagatedBuildInputs or []))
    ++ [ 
      pkgs-unstable.python3Packages.google-re2 
      pkgs-unstable.python3Packages.pyotp
      pkgs-unstable.python3Packages.qrcode
    ];
    doCheck = false;
    dontCheckRuntimeDeps = true;
  });
in
{
  services.open-webui.package = lib.mkForce clean-owui;
}
