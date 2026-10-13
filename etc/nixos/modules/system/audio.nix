{ config, pkgs, lib, ... }:
{
  # PAM limits for realtime audio (audio group)
  security.pam.loginLimits = [
    { domain = "@audio"; item = "memlock"; type = "-"; value = "unlimited"; }
    { domain = "@audio"; item = "rtprio"; type = "-"; value = "99"; }
    { domain = "@audio"; item = "nice"; type = "-"; value = "-19"; }
  ];

  # PipeWire audio - JACK-style config for Native Instruments Komplete Audio 6
  # Goal: Pro audio stability - no glitches during disk I/O or window ops
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;

    extraConfig.pipewire = {
      # Global clock settings - adaptive quantum for USB audio stability
      "10-clock-config" = {
        "context.properties" = {
          "default.clock.rate" = 96000;
          "default.clock.allowed-rates" = [ 44100 48000 96000 ];
          "default.clock.quantum" = 2048;      # 21ms at 96kHz - absorbs PCIe latency spikes
          "default.clock.min-quantum" = 1024;  # Floor: 10.7ms (was 512, too tight for shared PCIe)
          "default.clock.max-quantum" = 4096;  # Ceiling: 42ms (GPU1 shares PCIe switch with USB audio)
          # No force-quantum - let PipeWire adapt to USB timing
        };
      };

      # NOTE: Komplete Audio 6 ALSA properties are in WirePlumber monitor.alsa.rules
      # PipeWire context.rules don't apply to ALSA devices discovered by WirePlumber

      # Realtime scheduling - DISABLE module-rt, let systemd handle it
      # PipeWire's built-in module-rt fights with systemd's CPUSchedulingPolicy=fifo,
      # resulting in RT being lost entirely. Setting module.rt=false prevents the
      # built-in from loading. All RT scheduling comes from systemd service overrides
      # below (pipewire=FIFO/95, pipewire-pulse=FIFO/90, wireplumber=FIFO/85).
      "90-realtime" = {
        "context.properties" = {
          "module.rt" = false;
        };
      };
    };

    # PipeWire-Pulse: high quality resampling
    extraConfig.pipewire-pulse = {
      "99-audio-quality" = {
        "stream.properties" = {
          "resample.quality" = 15;
        };
      };
    };

    # WirePlumber: make Komplete the preferred default
    wireplumber.extraConfig = {
      "50-komplete-default" = {
        "monitor.alsa.rules" = [
          {
            matches = [{ "device.name" = "~alsa_card.usb-Native_Instruments.*"; }];
            actions = {
              update-props = {
                "device.disabled" = false;
                "node.priority.session" = 2000;   # High priority
                "node.priority.driver" = 2000;    # Prefer as driver
                "audio.format" = "S24LE";
                "audio.rate" = 96000;
                "api.alsa.period-size" = 1024;    # Match quantum
                "api.alsa.headroom" = 1024;       # USB jitter buffer
                "api.alsa.disable-batch" = true;  # Prevent batching
                "session.suspend-timeout-seconds" = 0;  # Never suspend
              };
            };
          }
          # Lower priority for consumer devices
          {
            matches = [{ "device.name" = "~alsa_card.usb-Razer*"; }];
            actions = {
              update-props = {
                "node.priority.session" = 1000;
                "node.priority.driver" = 1000;
              };
            };
          }
          # Disable HDMI audio sinks (NVIDIA + AMD) - never used, just overhead
          {
            matches = [{ "device.name" = "~alsa_card.pci-*"; }];
            actions = {
              update-props = {
                "device.disabled" = true;
              };
            };
          }
        ];
      };
    };
  };

  services.dbus.enable = true;
  security.polkit.enable = true;

  # Force PipeWire to run with realtime priority via systemd
  # This bypasses the unreliable module-rt + rtkit chain
  systemd.user.services.pipewire.serviceConfig = {
    Nice = -20;
    LimitRTPRIO = 99;
    LimitMEMLOCK = "infinity";
    CPUSchedulingPolicy = "fifo";
    CPUSchedulingPriority = 95;
  };

  systemd.user.services.pipewire-pulse.serviceConfig = {
    Nice = -20;
    LimitRTPRIO = 99;
    LimitMEMLOCK = "infinity";
    CPUSchedulingPolicy = "fifo";
    CPUSchedulingPriority = 90;
  };

  systemd.user.services.wireplumber.serviceConfig = {
    Nice = -15;
    LimitRTPRIO = 99;
    LimitMEMLOCK = "infinity";
    CPUSchedulingPolicy = "fifo";
    CPUSchedulingPriority = 85;
  };
}
