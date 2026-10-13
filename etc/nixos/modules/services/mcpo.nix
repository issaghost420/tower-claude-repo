{ config, pkgs, lib, ... }:
let
  py312 = pkgs.python312;
  py312pkgs = pkgs.python312Packages;

  mcp-py = py312pkgs.buildPythonPackage rec {
    pname = "mcp";
    version = "1.29.0";
    src = py312pkgs.fetchPypi {
      pname = pname;
      version = version;
      sha256 = "sha256-UtAfM03hhozDuy1mBJMRJqZ2MfmabF07grpHKQMV7DY=";
    };
    pyproject = true;
    nativeBuildInputs = with py312pkgs; [ hatchling uv-dynamic-versioning uvicorn pyjwt ];
    propagatedBuildInputs = with py312pkgs; [
      anyio httpx-sse httpx jsonschema pydantic-settings python-multipart sse-starlette starlette typing-extensions typing-inspection
    ];
  };

  mcpo-py = py312pkgs.buildPythonPackage rec {
    pname = "mcpo";
    version = "0.0.17";
    src = py312pkgs.fetchPypi {
      pname = pname;
      version = version;
      sha256 = "sha256-BfyAEJeJfiYe+LdPwKwizKsA+wUiolwbM+wtYdx77MM=";
    };
    pyproject = true;
    nativeBuildInputs = [ py312pkgs.hatchling ];
    propagatedBuildInputs = with py312pkgs; [
      mcp-py click passlib pydantic python-dotenv typer watchdog fastapi pyjwt uvicorn
    ];
  };

  mcpoRuntime = py312.withPackages (ps: with ps; [
    mcpo-py mcp-py fastapi uvicorn
  ]);

  mcpServerRuntime = py312.withPackages (ps: with ps; [
    mcp-py
    aiofile annotated-doc annotated-types anyio attrs authlib babel beartype cachetools caio certifi cffi charset-normalizer click courlan cryptography cyclopts dateparser dnspython docstring-parser email-validator exceptiongroup fastmcp-slim griffelib h11 htmldate httpcore httpcore2 httpx httpx-sse httpx2 idna jaraco-classes jaraco-context jaraco-functools jeepney jinja2 joserfc jsonref jsonschema jsonschema-path jsonschema-specifications justext keyring lxml lxml-html-clean markdown-it-py markupsafe mdurl more-itertools openapi-pydantic opentelemetry-api packaging pathable platformdirs py-key-value-aio pycparser pydantic pydantic-core pydantic-settings pygments pyjwt pyperclip python-dateutil python-dotenv python-multipart pytz pyyaml referencing regex rich rich-rst rpds-py secretstorage shellingham six sse-starlette starlette tld trafilatura truststore typer typing-extensions typing-inspection tzlocal uncalled-for urllib3 uvicorn watchfiles websockets
  ]);

  mcpServerWrapper = pkgs.writeShellScriptBin "deepresearch-mcp" ''
    export PYTHONPATH=/home/tower/tools/mcp-servers/deepresearch:''${PYTHONPATH:-}
    cd /home/tower/tools/mcp-servers/deepresearch
    exec ${mcpServerRuntime}/bin/python -m deepresearch.server "$@"
  '';

in {
  environment.systemPackages = [ mcpServerWrapper ];

  systemd.services.mcpo = {
    description = "MCP-to-OpenAPI proxy for Open WebUI";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${mcpoRuntime}/bin/mcpo --port 8001 --config /home/tower/tools/mcp-servers/mcp.json";
      User = "tower";
      Restart = "always";
      RestartSec = 5;
      Environment = "PATH=${pkgs.nodejs}/bin:${pkgs.coreutils}/bin";
      EnvironmentFile = "/home/tower/.secrets/lms.env";
    };
  };
}
