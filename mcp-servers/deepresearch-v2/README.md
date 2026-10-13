# deepresearch

A research MCP server that runs the whole loop internally instead of asking the
calling model to be disciplined.

`deep_research("question")` → the server plans queries, searches SearXNG across
rotating engine subsets, enforces query diversification, fetches and extracts
pages, scores sources deterministically, drops near-duplicates, checks for gaps,
fires bounded sidechains on unexplained entities, and synthesizes a tagged,
cited report. The calling model gets a finished answer and never sees the
machinery.

## Why this shape

The alternative — hand the model `search` + `fetch` + a rulebook and hope it
runs 4 rounds × 5 diversified queries — fails for the same reason browser tools
get abandoned after one call: multi-step research discipline is *model
behavior*, and model behavior isn't controllable from outside the weights.

So: the protocol lives in Python and YAML, deterministically. The tool
descriptions and the `next_action` / `presentation_directive` fields in returns
are *nudges* — real prompt real estate, worth using, but never trusted.

## Install

```bash
nix develop   # or the mcpo.nix NixOS module — see below
python -m deepresearch.cli --health        # do this first, always
python -m deepresearch.cli "your question" -p standard
```

`--health` checks SearXNG JSON output, engine reachability, the LLM endpoint,
and prompt templates. If it fails here it'll fail under MCP, just less legibly.

## Wiring

```bash
mkdir -p ~/.config/mcp/prompts
cp config/research.yml ~/.config/mcp/research.yml
cp prompts/*.j2 ~/.config/mcp/prompts/
```

**HTTP (recommended for LM Studio + OWUI + OGnee sharing one instance):** run
one `streamable-http` service and point every client at it. stdio works too,
but every client spawns its own process with its own SQLite cache — you lose
cross-client cache reuse and get lock contention.

**Remove `web-search` from the toolset wherever this is loaded.** `web_search`
is a canonical name with heavy prior weight; `deep_research` is not. You can't
lose a race you don't enter.

## Tools exposed

| tool | shape | use |
|---|---|---|
| `deep_research(query)` | **sync**, blocks ≤ ~5 min, returns the report inline | normal questions |
| `deeper_research(query)` | **async**, returns `job_id` immediately, unlimited wall clock | hard open-ended questions |
| `research_status(job_id)` | blocks server-side up to 20s per call | poll for deeper_research |
| `research_result(job_id, full)` | fallback fetch of a finished job | after context resets |
| `research_search(queries, engines)` | raw primitive, no synthesis | drive the loop manually |
| `research_config()` | show active config | debugging |

Neither research tool takes profile/rounds/sources arguments. Profiles are
operator territory — edit `research.yml`. Every knob exposed to the calling
model is variability it will exercise at random; that is the thing this tool
exists to eliminate.

The anti-spam contract for `deeper_research`: `research_status` blocks
server-side, and the tool descriptions forbid narrating polls to the user.
The model physically cannot burn context faster than one short tool exchange
per 20s of real research.

## Profiles

Everything lives in `~/.config/mcp/research.yml`. Two profiles are pinned to
tools by the server:

* `standard` — `deep_research`. `wall_clock_budget_s` must be ≤
  `RESEARCH_SYNC_CEILING_S` (default 300). The server refuses to boot if this
  invariant is violated.
* `deeper` — `deeper_research`. `wall_clock_budget_s: 0` means **unlimited**;
  the run ends when rounds are exhausted or the gap check reports sufficiency.

The rest (`quick`, `deep`, `technical`, `adversarial`) are reachable via the
CLI (`-p name`) for experiments. Live values: `research_config` MCP tool, or
`--show-config`.

## Forensic trail

`~/.cache/deepresearch/cache.sqlite` holds every page fetched, every search run,
timestamps, and every failure reason.

```sql
SELECT url, status, error, datetime(fetched_at,'unixepoch') FROM pages
WHERE error IS NOT NULL ORDER BY fetched_at DESC LIMIT 40;
```

Reports (markdown + full JSON) land in `output_dir` (`~/research/reports`).
Finished jobs are retained in memory for 2h, then only on disk.

## Secrets

`RESEARCH_LLM_KEY` comes from the environment, never from YAML or mcp.json
(anything in a Nix config lands in /nix/store world-readable; anything in
mcp.json is plaintext in your tools directory). Under the mcpo systemd unit it
lives in `~/.secrets/lms.env`.

## Known-unknown

MCP transport naming moves fast. `streamable-http` is the current name as of my
pretraining; verify against the live spec and adjust `RESEARCH_TRANSPORT` if
it's changed. The NixOS module passes it straight through as an env var, so
it's a one-line fix, not a rebuild of anything structural.
