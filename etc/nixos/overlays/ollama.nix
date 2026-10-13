#======================================================
# OLLAMA: Optimized for efficient builds, python tricks
#======================================================
{ ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      ollama = prev.ollama.overrideAttrs (old: {
        doCheck = false;
        dontCheckRuntimeDeps = true;
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [
          "-DLLAMA_BUILD_TESTS=OFF"
          "-DLLAMA_BUILD_EXAMPLES=OFF"
        ];
      });
    })
  ];
}
