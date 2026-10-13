"""CLI. Debug the pipeline without MCP in the loop.

  deepresearch-cli "your question" --profile deep
  deepresearch-cli --health
  deepresearch-cli --show-config

Always get this working before you wire it into a client. If it fails here it
will fail there, just less legibly.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys

from . import config as cfgmod
from .pipeline import Pipeline
from .searx import SearxClient


async def _health(cfg):
    async with SearxClient(cfg.searx_url, cfg.searx_timeout_s) as sx:
        h = await sx.health()
        print(f"searxng {cfg.searx_url}: {h}")
        if not h.get("ok"):
            print("  -> check: formats includes 'json' in settings.yml, "
                  "limiter false, service listening on this address")
        elif not h.get("json"):
            print("  -> HTTP 200 but not JSON. 'json' is missing from search.formats.")
        for q in ("nixos flake secure boot", "rtx 5090 xid 79"):
            hits = await sx.search(q, cfg.profile().engines[:4], limit=5)
            print(f"  {q!r}: {len(hits)} hits, engines seen: "
                  f"{sorted({e for h_ in hits for e in h_.engines})}")
    from .llm import LLM
    llm = LLM(cfg.llm, cfg.prompts)
    try:
        out = await llm.complete("Reply with the single word: ok", max_tokens=10)
        print(f"llm {llm.endpoint} ({llm.model}): {out.strip()[:40]!r}")
    except Exception as e:  # noqa: BLE001
        print(f"llm {llm.endpoint}: FAILED {type(e).__name__}: {e}")
    for name, p in cfg.prompts.items():
        print(f"prompt {name}: {'ok' if p.exists() else 'MISSING'} {p}")


def main() -> int:
    ap = argparse.ArgumentParser(prog="deepresearch-cli")
    ap.add_argument("query", nargs="?")
    ap.add_argument("--profile", "-p", default=None)
    ap.add_argument("--rounds", type=int, default=0)
    ap.add_argument("--sources", type=int, default=0)
    ap.add_argument("--config", "-c", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--health", action="store_true")
    ap.add_argument("--show-config", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if a.verbose else logging.INFO,
        format="%(levelname)s %(name)s %(message)s", stream=sys.stderr,
    )
    cfg = cfgmod.load(a.config)

    if a.health:
        asyncio.run(_health(cfg))
        return 0
    if a.show_config:
        print(json.dumps({n: {"rounds": p.rounds, "queries": p.queries_per_round,
                              "sources": p.total_sources, "engines": p.engines}
                          for n, p in cfg.profiles.items()}, indent=2))
        return 0
    if not a.query:
        ap.error("need a query (or --health / --show-config)")

    overrides = {}
    if a.rounds:
        overrides["rounds"] = a.rounds
    if a.sources:
        overrides["total_sources"] = a.sources

    def prog(**kw):
        print(f"  [{kw.get('stage')}] "
              f"{ {k: v for k, v in kw.items() if k != 'stage'} }", file=sys.stderr)

    pipe = Pipeline(cfg, on_progress=prog)
    try:
        report = asyncio.run(pipe.run(a.query, a.profile, overrides))
        path = pipe.write(report)
        if a.json:
            print(json.dumps(report.to_dict(), indent=2, default=str))
        else:
            print(path.read_text())
        print(f"\n--- written to {path}", file=sys.stderr)
    finally:
        pipe.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
