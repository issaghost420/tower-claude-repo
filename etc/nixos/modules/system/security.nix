{ config, pkgs, lib, ... }:
{
  # Namespace cloning for unprivileged containers (Podman)
  security.allowUserNamespaces = true;

  # sysctl settings that are security-focused
  boot.kernel.sysctl = {
    "kernel.unprivileged_userns_clone" = 1;
  };
}
