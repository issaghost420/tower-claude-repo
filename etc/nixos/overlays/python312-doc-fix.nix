{ ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      python312 = prev.python312.overrideAttrs (old: {
        passthru = old.passthru // {
          doc = final.emptyDirectory;
        };
      });

      pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
        (python-final: python-prev: {
          scipy = python-prev.scipy.overridePythonAttrs (old: {
            doCheck = false;
          });
          inline-snapshot = python-prev.inline-snapshot.overridePythonAttrs (old: {
            doCheck = false;
          });
          pydantic-monty = python-prev.pydantic-monty.overridePythonAttrs (old: {
            doCheck = false; 
          });
#          fastmcp = python-prev.fastmcp.overridePythonAttrs (old: {
#            doCheck = false; 
        })
      ];
    })
  ];
}
