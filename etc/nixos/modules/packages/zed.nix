# ============================================================
# ZED / GRAM — SOVEREIGNTY MODULE
# Zero telemetry. Zero cloud. Local Ollama only. No bullshit.
# ============================================================

{ config, pkgs, lib, ... }:

let
  user = "tower";
  xdgConfig = "/home/${user}/.config";
  xdgData = "/home/${user}/.local/share";

  # --- Zed settings.json ---
  zedSettings = pkgs.writeText "zed-settings.json" ''
    {
      // ============================================================
      // SOVEREIGNTY: Telemetry nuked. Local Ollama only. No sign-in.
      // ============================================================

      "telemetry": {
        "diagnostics": false,
        "metrics": false
      },

      // --- Session ---
      "session": {
        "trust_all_worktrees": true
      },
      "on_last_window_closed": "quit",
      "confirm_quit": false,

      // --- Appearance ---
      "theme": "zed-dark",
      "ui_font_family": "JetBrainsMono Nerd Font",
      "buffer_font_family": "JetBrainsMono Nerd Font",
      "buffer_font_size": 15,
      "buffer_font_features": {
        "calt": true
      },
      "buffer_line_height": "comfortable",
      "buffer_font_fallbacks": ["Nerd Font"],
      "cursor_blink": false,
      "cursor_shape": "block",

      "gutter": {
        "line_numbers": true,
        "runnables": true,
        "breakpoints": true,
        "folds": true,
        "min_line_number_digits": 3
      },

      "current_line_highlight": "gutter",

      "scrollbar": {
        "show": "auto",
        "cursors": true,
        "git_diff": true,
        "search_results": true,
        "selected_text": true,
        "selected_symbol": true,
        "diagnostics": "all",
        "axes": {
          "horizontal": false,
          "vertical": true
        }
      },

      "selection_highlight": true,
      "rounded_selection": false,

      // --- Editing ---
      "autosave": "on_focus_change",
      "auto_indent": true,
      "auto_indent_on_paste": true,
      "format_on_save": "on",
      "hard_tabs": false,
      "tab_size": 4,
      "preferred_line_length": 100,
      "soft_wrap": "none",
      "show_completions_on_input": true,
      "show_completion_documentation": "inline",
      "colorize_brackets": true,
      "vim_mode": false,
      "helix_mode": false,
      "snippet_sort_order": "inline",
      "diagnostics_max_severity": "warning",

      // --- Layout ---
      "bottom_dock_layout": "full",
      "active_pane_modifiers": {
        "border_size": 0.0,
        "inactive_opacity": 0.7
      },
      "close_on_file_delete": true,
      "drop_target_size": 0.25,
      "load_direnv": "direct",

      // ============================================================
      // AI: OLLAMA ONLY. No cloud. No Copilot. No sign-in.
      // ============================================================
      "edit_predictions": {
        "provider": "ollama"
      },

      "agent": {
        "default_model": {
          "provider": "ollama",
          "model": "qwen2.5-coder:14b",
          "mode": "agent"
        },
        "inline_assistant_model": {
          "provider": "ollama",
          "model": "qwen2.5-coder:7b"
        },
        "default_profile": "write",
        "always_allow_tool_actions": true,
        "play_sound_when_agent_done": true,
        "version": "2"
      },

      "language_models": {
        "ollama": {
          "api_url": "http://127.0.0.1:11434",
          "low_speed_timeout_in_seconds": 120,
          "available_models": [
            {
              "provider": "ollama",
              "name": "qwen2.5-coder:14b",
              "display_name": "Qwen2.5 Coder 14B (Agent)",
              "max_tokens": 131072,
              "keep_alive": "30m",
              "supports_tools": true
            },
            {
              "provider": "ollama",
              "name": "qwen2.5-coder:7b",
              "display_name": "Qwen2.5 Coder 7B (Inline)",
              "max_tokens": 32768,
              "keep_alive": "10m",
              "supports_tools": true
            },
            {
              "provider": "ollama",
              "name": "qwen2.5-coder:1.5b",
              "display_name": "Qwen2.5 Coder 1.5B (Fast Completion)",
              "max_tokens": 8192,
              "keep_alive": "5m",
              "supports_tools": false
            }
          ]
        }
      },

      // ============================================================
      // MCP SERVERS — Local tools only
      // ============================================================
      "mcp_servers": {
        "filesystem": {
          "command": "${pkgs.nodejs}/bin/npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/${user}"]
        }
      },

      // ============================================================
      // LSP CONFIGURATION
      // ============================================================
      "lsp": {
        "rust-analyzer": {
          "initialization_options": {
            "check": { "command": "clippy" },
            "cargo": { "allFeatures": true }
          }
        },
        "pyright": {
          "initialization_options": {
            "pyrightconfig": {
              "pythonVersion": "3.12",
              "typeCheckingMode": "strict"
            }
          }
        },
        "gopls": {
          "initialization_options": {
            "completeUnimported": true,
            "usePlaceholders": true,
            "staticcheck": true
          }
        },
        "typescript-language-server": {
          "initialization_options": {
            "hostInfo": "zed"
          }
        },
        "json-language-server": {
          "settings": {
            "json": {
              "schemas": []
            }
          }
        },
        "yaml-language-server": {
          "settings": {
            "yaml": {
              "keyOrdering": true
            }
          }
        }
      },

      // ============================================================
      // PER-LANGUAGE OVERRIDES
      // ============================================================
      "languages": {
        "Python": {
          "tab_size": 4,
          "formatter": "language_server",
          "format_on_save": "on",
          "preferred_line_length": 88
        },
        "Rust": {
          "tab_size": 4,
          "formatter": "language_server",
          "format_on_save": "on",
          "preferred_line_length": 100
        },
        "Go": {
          "tab_size": 4,
          "hard_tabs": true,
          "formatter": "language_server",
          "format_on_save": "on"
        },
        "JavaScript": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.nodejs}/bin/node ${pkgs.yarn}/bin/yarn prettier",
              "arguments": ["--stdin-filepath", "{buffer_path}"]
            }
          },
          "format_on_save": "on",
          "preferred_line_length": 100
        },
        "TypeScript": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.prettier}/bin/prettier",
              "arguments": ["--stdin-filepath", "{buffer_path}"]
            }
          },
          "format_on_save": "on",
          "preferred_line_length": 100
        },
        "JSON": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.prettier}/bin/prettier",
              "arguments": ["--stdin-filepath", "{buffer_path}", "--parser", "json"]
            }
          },
          "format_on_save": "on"
        },
        "JSONC": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.prettier}/bin/prettier",
              "arguments": ["--stdin-filepath", "{buffer_path}", "--parser", "json"]
            }
          },
          "format_on_save": "on"
        },
        "YAML": {
          "tab_size": 2,
          "formatter": "language_server",
          "format_on_save": "on"
        },
        "TOML": {
          "tab_size": 4,
          "formatter": {
            "external": {
              "command": "${pkgs.taplo}/bin/taplo",
              "arguments": ["format", "--stdin", "--compact-arrays=false"]
            }
          },
          "format_on_save": "on"
        },
        "Markdown": {
          "tab_size": 2,
          "soft_wrap": "editor_width",
          "preferred_line_length": 80,
          "formatter": {
            "external": {
              "command": "${pkgs.prettier}/bin/prettier",
              "arguments": ["--stdin-filepath", "{buffer_path}", "--prose-wrap", "preserve"]
            }
          }
        },
        "Shell": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.shellfmt}/bin/shellfmt",
              "arguments": ["-i", "2", "-ci", "-s", "-"]
            }
          },
          "format_on_save": "on"
        },
        "Lua": {
          "tab_size": 2,
          "formatter": "language_server",
          "format_on_save": "on"
        },
        "Dockerfile": {
          "tab_size": 4
        }
      },

      "file_types": {
        "TOML": ["Cargo.toml", "flake.nix"],
        "Dockerfile": ["Dockerfile*", "*.Dockerfile"]
      }
    }
  '';

  # --- Gram settings.jsonc (same structure, no AI section) ---
  gramSettings = pkgs.writeText "gram-settings.jsonc" ''
    {
      // ============================================================
      // GRAM — SOVEREIGNTY CONFIG
      // No telemetry. No cloud. No AI. No auto-updates. No bullshit.
      // ============================================================

      "session": {
        "trust_all_worktrees": true
      },
      "on_last_window_closed": "quit",
      "confirm_quit": false,

      // --- Appearance ---
      "theme": "gram-dark",
      "ui_font_family": "JetBrainsMono Nerd Font",
      "buffer_font_family": "JetBrainsMono Nerd Font",
      "buffer_font_size": 15,
      "buffer_font_features": {
        "calt": true
      },
      "buffer_line_height": "comfortable",
      "buffer_font_fallbacks": ["Nerd Font"],
      "cursor_blink": false,
      "cursor_shape": "block",

      "gutter": {
        "line_numbers": true,
        "runnables": true,
        "breakpoints": true,
        "folds": true,
        "min_line_number_digits": 3
      },

      "current_line_highlight": "gutter",
      "selection_highlight": true,
      "rounded_selection": false,

      "scrollbar": {
        "show": "auto",
        "cursors": true,
        "git_diff": true,
        "search_results": true,
        "selected_text": true,
        "selected_symbol": true,
        "diagnostics": "all",
        "axes": {
          "horizontal": false,
          "vertical": true
        }
      },

      // --- Editing ---
      "autosave": "on_focus_change",
      "auto_indent": true,
      "auto_indent_on_paste": true,
      "format_on_save": "on",
      "hard_tabs": false,
      "tab_size": 4,
      "preferred_line_length": 100,
      "soft_wrap": "none",
      "show_completions_on_input": true,
      "show_completion_documentation": "inline",
      "colorize_brackets": true,
      "vim_mode": false,
      "snippet_sort_order": "inline",
      "diagnostics_max_severity": "warning",

      "bottom_dock_layout": "full",
      "active_pane_modifiers": {
        "border_size": 0.0,
        "inactive_opacity": 0.7
      },
      "close_on_file_delete": true,
      "drop_target_size": 0.25,
      "load_direnv": "direct",

      // --- LSP ---
      "lsp": {
        "rust-analyzer": {
          "initialization_options": {
            "check": { "command": "clippy" },
            "cargo": { "allFeatures": true }
          }
        },
        "pyright": {
          "initialization_options": {
            "pyrightconfig": {
              "pythonVersion": "3.12",
              "typeCheckingMode": "strict"
            }
          }
        },
        "gopls": {
          "initialization_options": {
            "completeUnimported": true,
            "usePlaceholders": true
          }
        },
        "yaml-language-server": {
          "settings": {
            "yaml": {
              "keyOrdering": true
            }
          }
        }
      },

      // --- Languages ---
      "languages": {
        "Python": {
          "tab_size": 4,
          "formatter": "language_server",
          "format_on_save": "on",
          "preferred_line_length": 88
        },
        "Rust": {
          "tab_size": 4,
          "formatter": "language_server",
          "format_on_save": "on"
        },
        "Go": {
          "tab_size": 4,
          "hard_tabs": true,
          "formatter": "language_server",
          "format_on_save": "on"
        },
        "TypeScript": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.prettier}/bin/prettier",
              "arguments": ["--stdin-filepath", "{buffer_path}"]
            }
          },
          "format_on_save": "on"
        },
        "TOML": {
          "tab_size": 4,
          "formatter": {
            "external": {
              "command": "${pkgs.taplo}/bin/taplo",
              "arguments": ["format", "--stdin"]
            }
          },
          "format_on_save": "on"
        },
        "Shell": {
          "tab_size": 2,
          "formatter": {
            "external": {
              "command": "${pkgs.shellfmt}/bin/shellfmt",
              "arguments": ["-i", "2", "-ci", "-s", "-"]
            }
          },
          "format_on_save": "on"
        }
      },

      "file_types": {
        "TOML": ["Cargo.toml", "flake.nix"],
        "Dockerfile": ["Dockerfile*"]
      }
    }
  '';

  # --- LSP sovereignty: local binaries directory ---
  lspDir = pkgs.runCommand "lsp-servers" { } ''
    mkdir -p $out/bin

    # These are the LSPs that get made available via PATH
    # Zed/Gram extensions will find them before trying to download
    ln -s ${pkgs.rust-analyzer}/bin/rust-analyzer $out/bin/rust-analyzer
    ln -s ${pkgs.go}/bin/gopls $out/bin/gopls

    # Pyright needs node
    mkdir -p $out/bin
    echo '#!/bin/sh' > $out/bin/pyright-langserver
    echo 'exec ${pkgs.python312}/bin/python3 -m pyright_langserver "$@"' >> $out/bin/pyright-langserver
    chmod +x $out/bin/pyright-langserver

    # TypeScript
    ln -s ${pkgs.typescript-language-server}/bin/typescript-language-server $out/bin/typescript-language-server

    # YAML
    ln -s ${pkgs.yaml-language-server}/bin/yaml-language-server $out/bin/yaml-language-server

    # JSON
    ln -s ${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server $out/bin/json-language-server
  '';

in
{
  options.zed = {
    enable = lib.mkEnableOption "Zed code editor (sovereignty config)";
    useGram = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use Gram instead of Zed (no AI, no cloud, pure editor)";
    };
  };

  config = lib.mkIf config.zed.enable {

    environment.systemPackages = with pkgs; [
      # Editor
      (if config.zed.useGram then (
        # Gram: from source or AUR. On NixOS, build from source:
        (pkgs.buildRustPackage {
          pname = "gram";
          version = "0.1.0";
          src = pkgs.fetchFromGitHub {
            owner = "GramEditor";
            repo = "gram";
            rev = "main";
            hash = ""; # TODO: fill in from `nix-prefetch-git`
          };
          # ... full build config would go here
          # For now, use the AppImage if available:
        } // { meta.description = "Gram editor (Zed fork, no AI/telemetry)"; })
      ) else (
        zed-editor
      ))

      # LSP servers (local, sovereign)
      rust-analyzer
      go
      python312
      typescript
      nodejs
      prettier
      taplo
      shellfmt
      vscode-langservers-extracted
      yaml-language-server

      # Ollama (local AI)
      ollama

      # MCP server for filesystem
      nodejs

      # Formatting tools
      prettier
      taplo
      shellfmt
      tree-sitter

      # Direnv (if you use it)
      direnv

      # For verification
      (pkgs.writeShellScriptBin "zed-audit" ''
        #!/usr/bin/env bash
        # Verify Zed is not phoning home
        echo "=== Zed Network Audit ==="
        echo ""
        echo "Active connections:"
        ss -tnp 2>/dev/null | grep -iE "zed|gram" || echo "  (none)"
        echo ""
        echo "Non-localhost connections (should be empty):"
        ss -tnp 2>/dev/null | grep -iE "zed|gram" | grep -v "127.0.0.1" | grep -v "::1" || echo "  CLEAN ✓"
        echo ""
        echo "Telemetry log size:"
        wc -c ~/.local/share/zed/logs/ 2>/dev/null || echo "  (no logs dir)"
      '')
    ];

    # Ollama service
    services.ollama = lib.mkIf (lib.getVersion pkgs.ollama) != null {
      enable = true;
    };
    systemd.services.ollama = {
      enable = true;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.ollama}/bin/ollama serve";
        Environment = "OLLAMA_HOST=127.0.0.1:11434";
        # Only listen on localhost — no network exposure
      };
    };

    # User environment: LSPs on PATH
    users.users.${user} = {
      environment.PATH = [
        "${lspDir}/bin"
        "${pkgs.prettier}/bin"
        "${pkgs.taplo}/bin"
        "${pkgs.shellfmt}/bin"
      ];
    };

    # Write settings files
    system.activationScripts.zed-settings.text = ''
      set -e

      # Zed config
      mkdir -p ${xdgConfig}/zed
      cp ${zedSettings} ${xdgConfig}/zed/settings.json
      chown -R ${user}:${user} ${xdgConfig}/zed

      # Gram config (if using Gram)
      mkdir -p ${xdgConfig}/gram
      cp ${gramSettings} ${xdgConfig}/gram/settings.jsonc
      chown -R ${user}:${user} ${xdgConfig}/gram

      # Ensure data dirs exist (clean state)
      mkdir -p ${xdgData}/zed/extensions/installed
      mkdir -p ${xdgData}/zed/extensions/work
      chown -R ${user}:${user} ${xdgData}/zed

      # Nuke any leftover telemetry/auth state
      rm -f ${xdgData}/zed/installation_id
      rm -f ${xdgData}/zed/system_id
      rm -rf ${xdgData}/zed/copilot
      rm -rf ${xdgData}/zed/logs

      echo "✓ Zed/Gram sovereignty config deployed"
      echo "  Settings: ${xdgConfig}/zed/settings.json"
      echo "  LSPs: ${lspDir}/bin/"
      echo "  Ollama: 127.0.0.1:11434 (localhost only)"
    '';

    # Firewall: block Zed from phoning home (belt and suspenders)
    # Uncomment if you want to be absolutely paranoid:
    # networking.firewall.allowedTCPPorts = lib.mkMerge [
    #   # Ollama is localhost only, no firewall needed
    #   # If Zed tries to hit zed.dev, it'll be blocked
    # ];
  };
}
