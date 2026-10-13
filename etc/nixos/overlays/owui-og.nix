#===================================================
# Python fixes, speedups, and anti-bloat owui config
#===================================================
{ ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      # 1. Python 3.12 Base Fix: Nuke empty doc output issue
      python312 = prev.python312.overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          doc = final.emptyDirectory;
        };
      });
      # 2. Python Package Extensions: OWUI Bloat Stripper & Pytest Bypass
      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          # Strip Open WebUI down to its bare local-runner core
          open-webui = python-prev.open-webui.overrideAttrs (old: {
            propagatedBuildInputs = builtins.filter (pkg:
              let
                pname = pkg.pname or "";
              in
              !(builtins.elem pname [
                # TIER 1 - Pure telemetry, always safe:
                "opentelemetry-api"
                "opentelemetry-sdk"
                "opentelemetry-exporter-otlp"
                "posthog"
                "amplitude-analytics"
                # TIER 2 - Safe if not using cloud storage backends:
                "google-cloud-storage"
                "azure-storage-blob"
                "boto3"
                "boto3-stubs"
                "s3transfer"
                # TIER 3 - Breaks features if you use them:
                #   openai/anthropic/google-generativeai -> cloud model routing
                #   langchain* -> RAG pipelines, some retrievers
                #   gitpython/pygit2 -> tools/functions git sync
                "openai"
                "anthropic"
                "google-generativeai"
                "google-ai-generativelanguage"
                "langchain"
#                "langchain-community"
#                "langchain-core"
                "langchain-openai"
#                "langchain-classic"
#                "gitpython"
#                "pygit2"
              ])
            ) (old.propagatedBuildInputs or [ ]);
            # Skip tests & ignore missing stripped runtime dependencies
            doCheck = false;
            dontCheckRuntimeDeps = true;
          });
          # Disable check phases on flaky C/Fortran math & snapshot packages
          scipy = python-prev.scipy.overridePythonAttrs (old: { doCheck = false; });
          inline-snapshot = python-prev.inline-snapshot.overridePythonAttrs (old: { doCheck = false; });
          scikit-learn = python-prev.scikit-learn.overridePythonAttrs (old: { doCheck = false; });
          # Kill pytestCheckPhase on the torch/ML stack — these run full model
          # inference in the sandbox and eat 10-30min each with no cache hit
          # on bleeding-edge Python versions.
          torchaudio = python-prev.torchaudio.overridePythonAttrs (old: { doCheck = false; });
          torchcodec = python-prev.torchcodec.overridePythonAttrs (old: { doCheck = false; });
          sentence-transformers = python-prev.sentence-transformers.overridePythonAttrs (old: { doCheck = false; });
          chromadb = python-prev.chromadb.overridePythonAttrs (old: { doCheck = false; });
        })
      ];
    })
  ];
}
