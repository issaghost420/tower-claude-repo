{ ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      python314 = prev.python314.overrideAttrs (old: {
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
          curl-cffi = python-prev.curl-cffi.overridePythonAttrs (old: {
            doCheck = false;
          });
        })
      ];
    })
  ];
}
