{ config, pkgs, lib, ... }:
{
  # ==========================================
  # POWER MANAGEMENT - WORKSTATION MODE (no sleeping, no throttling)
  # ==========================================
   # Disabled 6-4-26, testing without maxing clocks to evaluate cost/benefit
   # If renableing, powerManagement.cpuFreqGovernor can't be defined twice
#  powerManagement.cpuFreqGovernor = "performance";  # CPU always at max freq

  # Allow suspend
  powerManagement.cpuFreqGovernor = "schedutil"; 
  powerManagement.enable = true;

  # Disable all power saving
  services.power-profiles-daemon.enable = false;
  services.tlp.enable = false;

  # IRQ balancing - distributes hardware interrupts across CPUs
  # Re-enabled 2026-03-07: Manual CCD0 pinning caused interrupt concentration
  # on 1-2 cores (17M+ interrupts on CPU21/23 alone). Let irqbalance spread load.
  services.irqbalance.enable = true;
}
