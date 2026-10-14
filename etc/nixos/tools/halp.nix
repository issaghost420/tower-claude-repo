# halp.nix — terminal LLM helper (aichat -> LM Studio) with MCP tools. Import it and rebuild:
#   imports = [ ./tools/halp.nix ];
#
# Pieces:
#   1. halp             — the engine, a real executable (rolling history, loop guard, timeout)
#   2. halp-mcp-start   — clones/links llm-functions and (re)starts its MCP bridge on :8808
#   3. sqlite-recover   — guarded SQLite recovery (generic fix-pi), also a halp tool
#   4. the zsh wrapper  — auto-loaded into every interactive zsh, pipes in $PWD + recent
#                         commands (a subprocess can't read the shell's history)
#
# Source files live in ./halp/. Tools come from mcp-servers/ in ~/tools/mcp-servers
# (searxng + local-files-smart.js), see ./halp/mcp.json.
#
# Runtime state, not managed here:
#   ~/tools/llm-functions          cloned on first run
#   ~/.local/state/halp/           rolling history (halp --flush clears it)
#   ~/.secrets/lms.env             LMSTUDIO_API_KEY=...

{ pkgs, lib, ... }:

let
  toolGuard = pkgs.writeShellScript "halp-tool-guard" (builtins.readFile ./halp/tool-guard.sh);

  mcpJson = pkgs.writeText "halp-mcp.json" (builtins.readFile ./halp/mcp.json);

  rolesDir = pkgs.writeTextDir "halp.md" (builtins.readFile ./halp/halp.md);

  # Generic fix-pi: also usable directly, e.g.
  #   sqlite-recover --db ~/ninjastack/etc-pihole/pihole-FTL.db --service podman-pihole.service
  sqliteRecover = pkgs.writeShellApplication {
    name = "sqlite-recover";
    runtimeInputs = with pkgs; [ sqlite coreutils gnugrep gnused ];
    text = builtins.readFile ./halp/sqlite-recover.sh;
  };

  # halp's sqlite_recover tool: model passes db + service, human types "yes"
  recoverTool = pkgs.writeShellApplication {
    name = "halp-sqlite-recover-tool";
    runtimeInputs = [ pkgs.jq pkgs.coreutils sqliteRecover ];
    text = builtins.readFile ./halp/recover-tool.sh;
  };

  nativeToolsJson = pkgs.writeText "halp-native-tools.json" (builtins.readFile ./halp/native-tools.json);

  mcpStart = pkgs.writeShellApplication {
    name = "halp-mcp-start";
    # sqlite: the bridge's local-files server shells out to sqlite3 for sqlite_query
    runtimeInputs = with pkgs; [ argc jq curl nodejs_22 git coreutils gnugrep gnused sqlite ];
    text = ''
      export HALP_MCP_JSON="''${HALP_MCP_JSON:-${mcpJson}}"   # override to test other MCP servers
      export HALP_TOOL_GUARD=${toolGuard}
      export HALP_NATIVE_TOOLS_JSON=${nativeToolsJson}
      export HALP_RECOVER_TOOL=${lib.getExe recoverTool}
    '' + builtins.readFile ./halp/mcp-start.sh;
  };

  halpEngine = pkgs.writeShellApplication {
    name = "halp";
    # tools run as children of aichat, so curl/grep/argc must be on this PATH too
    runtimeInputs = with pkgs; [ aichat argc jq curl nodejs_22 coreutils gnugrep gnused ];
    text = ''
      export HALP_ROLES_DIR=${rolesDir}
      export HALP_MCP_START=${lib.getExe mcpStart}
    '' + builtins.readFile ./halp/halp.sh;
  };
in
{
  environment.systemPackages = [ halpEngine mcpStart sqliteRecover ];

  programs.zsh.interactiveShellInit = lib.mkAfter ''
    # halp: pass the shell's context to the halp engine (see /etc/nixos/tools/halp.nix)
    halp() {
      local ctx="Current directory: $PWD
    Recent commands:
    $(fc -ln -10 2>/dev/null)"
      print -r -- "$ctx" | command halp "$@"
    }
  '';
}
