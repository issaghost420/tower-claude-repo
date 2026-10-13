#===================================================
# Python fixes, speedups, and anti-bloat owui config
#===================================================
{ config, pkgs, lib, ... }:
let
  pkgs-unstable = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixpkgs-unstable.tar.gz";
    sha256 = "sha256:0vplppav4izj2462i00a3vd0nbvaj6dbp4m582ndfhhnf8688579";
  }) { config.allowUnfree = true; system = "x86_64-linux"; };
in
{
  services.open-webui.package = pkgs-unstable.open-webui;
}
{
  nixpkgs.overlays = [
    (final: prev: {
      python312 = prev.python312.overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          doc = final.emptyDirectory;
        };
      });
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          open-webui = python-prev.open-webui.overrideAttrs (old: {
            version = "0.11.3";
            src = prev.fetchFromGitHub {
              owner = "open-webui";
              repo = "open-webui";
              tag = "v0.11.3";
              hash = "sha256:0vplppav4izj2462i00a3vd0nbvaj6dbp4m582ndfhhnf8688579";
            };

            propagatedBuildInputs = builtins.filter (pkg:
              let
                pname = pkg.pname or "";
              in
              !(builtins.elem pname [
                # TIER 1 - Pure telemetry, always safe:
#                "opentelemetry-api"
#                "opentelemetry-sdk"
#                "opentelemetry-exporter-otlp"
#                "posthog"
#                "amplitude-analytics"
                # TIER 2 - Safe if not using cloud storage backends:
#                "google-cloud-storage"
#                "azure-storage-blob"
#                "boto3"
#                "boto3-stubs"
#                "s3transfer"
                # TIER 3 - Breaks features if you use them:
                #   openai/anthropic/google-generativeai -> cloud model routing
                #   langchain* -> RAG pipelines, some retrievers
                #   gitpython/pygit2 -> tools/functions git sync
#                "openai"
#                "anthropic"
#                "google-generativeai"
#                "google-ai-generativelanguage"
#                "langchain"
#                "langchain-community"
#                "langchain-core"
#                "langchain-openai"
#                "langchain-classic"
#                "gitpython"
#                "pygit2"
              ])
            ) (old.propagatedBuildInputs or [ ]);
            doCheck = false;
            dontCheckRuntimeDeps = true;
          });
 #         scipy = python-prev.scipy.overridePythonAttrs (old: { doCheck = false; });
 #         inline-snapshot = python-prev.inline-snapshot.overridePythonAttrs (old: { doCheck = false; });
 #         scikit-learn = python-prev.scikit-learn.overridePythonAttrs (old: { doCheck = false; });
#          torchaudio = python-prev.torchaudio.overridePythonAttrs (old: { doCheck = false; });
#          torchcodec = python-prev.torchcodec.overridePythonAttrs (old: { doCheck = false; });
#          sentence-transformers = python-prev.sentence-transformers.overridePythonAttrs (old: { doCheck = false; });
#          chromadb = python-prev.chromadb.overridePythonAttrs (old: { doCheck = false; });
        })
      ];
    })
  ];
}
