{
  programs.starship = {
    enable = true;
    settings = {
      format = ''
        [┌─](bold white)$username$hostname$directory$git_branch$git_status$nix_shell$python$custom$fill$cmd_duration$status
        [└─](bold white)$character'';

      fill = {
        symbol = " ";
        style = "bold gray";
      };

      username = {
        show_always = true;
        style_user = "bold cyan";
        format = "[$user]($style) ";
      };

      hostname = {
        ssh_only = false;
        style = "bold green";
        format = "at [󰒋 $hostname]($style) ";
      };

      directory = {
        truncation_length = 4;
        style = "bold blue";
        read_only = " 󰌾";
        format = "in [$path]($style)[$read_only]($read_only_style) ";
      };

      git_branch = {
        symbol = " ";
        style = "bold magenta";
        format = "on [$symbol$branch]($style) ";
      };

      git_status = {
        style = "bold red";
        format = "([$all_status$ahead_behind]($style)) ";
      };

      nix_shell = {
        symbol = " ";
        style = "bold blue";
        format = "via [$symbol$state(\\($name\\))]($style) ";
      };

      cmd_duration = {
        min_time = 500;
        style = "bold yellow";
        format = "took [$duration]($style) ";
      };

      status = {
        disabled = false;
        format = "[$symbol $int]($style) ";
      };

      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
        vimcmd_symbol = "[❮](bold blue)";
      };

      custom = {
        gpu_vram = {
          description = "Dual RTX 5090 VRAM Usage";
          command = "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | awk '{sum+=$1} END {printf \"%.1fGB\", sum/1024}'";
          when = "command -v nvidia-smi > /dev/null";
          shell = [ "bash" "--noprofile" "--norc" ];
          style = "bold italic green";
          format = "with [󱚥 $output]($style) ";
        };

        vault = {
          description = "Gocryptfs Vault Status";
          command = "mount | grep -q tower-data-plain && echo '󰦝 UNLOCKED' || echo '󰦞 LOCKED'";
          when = "ls ~/archive-of-infinite-fold > /dev/null 2>&1";
          style = "bold orange";
          format = "vault [$output]($style) ";
        };
      };

      python = {
        symbol = "🐍 ";
        style = "bold yellow";
        detect_extensions = [ ];
        detect_files = [ ];
        detect_folders = [ ];
        format = "[$symbol$virtualenv]($style) ";
      };
    };
  };
}
