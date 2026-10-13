"""Config loading. Single source of truth = ~/.config/mcp/research.yml

Design rule: nothing in this codebase hardcodes a research parameter.
If you find yourself editing Python to change research behavior, that's a bug
in the config schema, not a reason to edit Python.
"""
from __future__ import annotations

import fnmatch
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

DEFAULT_CONFIG_PATH = Path(
    os.environ.get("RESEARCH_CONFIG", "~/.config/mcp/research.yml")
).expanduser()


def _deep_merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


@dataclass
class Diversification:
    strategy: str = "facet"
    min_edit_distance: float = 0.4
    require_negative_case: bool = True
    max_regen_attempts: int = 3


@dataclass
class FetchCfg:
    concurrency: int = 8
    timeout_s: int = 20
    max_bytes: int = 3_000_000
    min_content_chars: int = 400
    user_agent: str = "Mozilla/5.0 (compatible; deepresearch/0.1)"
    browser_fallback: bool = False
    browser_cdp_url: str | None = None


@dataclass
class Scoring:
    cross_engine_agreement: float = 0.30
    domain_tier: float = 0.25
    recency: float = 0.20
    term_density: float = 0.15
    content_length: float = 0.10
    recency_halflife_days: float = 540.0
    ignore_recency_for_tiers: list[str] = field(default_factory=lambda: ["tier1"])


@dataclass
class Sidechain:
    enabled: bool = True
    triggers: list[str] = field(default_factory=lambda: ["unknown_entity", "unanswered_question"])
    max_sidechains: int = 3
    max_depth: int = 1
    rounds: int = 1
    queries: int = 2
    sources: int = 5


@dataclass
class Profile:
    name: str = "standard"
    rounds: int = 3
    queries_per_round: int = 4
    engines: list[str] = field(default_factory=list)
    engines_per_query: int = 3
    results_per_query: int = 10
    max_pageno: int = 1
    escalate_pageno_if_thin: bool = True
    thin_round_threshold: int = 3
    total_sources: int = 25
    max_per_domain: int = 3
    min_score_to_keep: float = 0.25
    diversification: Diversification = field(default_factory=Diversification)
    fetch: FetchCfg = field(default_factory=FetchCfg)
    scoring: Scoring = field(default_factory=Scoring)
    sidechain: Sidechain = field(default_factory=Sidechain)
    wall_clock_budget_s: int = 900


@dataclass
class Config:
    raw: dict[str, Any]
    searx_url: str
    searx_timeout_s: int
    cache_path: Path
    cache_ttl_hours: int
    output_dir: Path
    default_profile: str
    profiles: dict[str, Profile]
    domain_tiers: dict[str, list[str]]
    llm: dict[str, Any]
    output: dict[str, Any]
    prompts: dict[str, Path]

    def profile(self, name: str | None = None) -> Profile:
        key = name or self.default_profile
        if key not in self.profiles:
            raise KeyError(
                f"unknown profile {key!r}; available: {sorted(self.profiles)}"
            )
        return self.profiles[key]

    def tier_of(self, domain: str) -> str:
        """First matching tier wins. 'blocked' is checked first."""
        for tier in ("blocked", "tier1", "tier2", "tier3"):
            for pat in self.domain_tiers.get(tier, []):
                if fnmatch.fnmatch(domain, pat) or domain.endswith("." + pat.lstrip("*.")):
                    return tier
        return "tier2"


def _mk_profile(name: str, d: dict, shared: dict) -> Profile:
    d = _deep_merge(shared, d)
    return Profile(
        name=name,
        rounds=d.get("rounds", 3),
        queries_per_round=d.get("queries_per_round", 4),
        engines=d.get("engines", []),
        engines_per_query=d.get("engines_per_query", 3),
        results_per_query=d.get("results_per_query", 10),
        max_pageno=d.get("max_pageno", 1),
        escalate_pageno_if_thin=d.get("escalate_pageno_if_thin", True),
        thin_round_threshold=d.get("thin_round_threshold", 3),
        total_sources=d.get("total_sources", 25),
        max_per_domain=d.get("max_per_domain", 3),
        min_score_to_keep=d.get("min_score_to_keep", 0.25),
        wall_clock_budget_s=d.get("wall_clock_budget_s", 900),
        diversification=Diversification(**(d.get("diversification") or {})),
        fetch=FetchCfg(**(d.get("fetch") or {})),
        scoring=Scoring(**(d.get("scoring") or {})),
        sidechain=Sidechain(**(d.get("sidechain") or {})),
    )


def load(path: Path | str | None = None) -> Config:
    p = Path(path).expanduser() if path else DEFAULT_CONFIG_PATH
    if not p.exists():
        raise FileNotFoundError(
            f"no research config at {p}. Copy config/research.yml there, or set RESEARCH_CONFIG."
        )
    raw = yaml.safe_load(p.read_text()) or {}
    defaults = raw.get("defaults", {})
    shared = raw.get("shared", {})

    profiles = {
        name: _mk_profile(name, body or {}, shared)
        for name, body in (raw.get("profiles") or {}).items()
    }
    if not profiles:
        profiles = {"standard": _mk_profile("standard", {}, shared)}

    prompt_dir = Path(
        (raw.get("synthesis") or {}).get("prompt_dir", p.parent / "prompts")
    ).expanduser()
    templates = (raw.get("synthesis") or {}).get("templates", {})
    prompts = {
        k: Path(v).expanduser() if os.path.isabs(str(v)) else prompt_dir / str(v)
        for k, v in (templates or {}).items()
    }

    return Config(
        raw=raw,
        searx_url=(raw.get("searx") or {}).get("url", "http://localhost:8888"),
        searx_timeout_s=(raw.get("searx") or {}).get("timeout_s", 30),
        cache_path=Path(
            defaults.get("cache_path", "~/.cache/deepresearch/cache.sqlite")
        ).expanduser(),
        cache_ttl_hours=defaults.get("cache_ttl_hours", 168),
        output_dir=Path(defaults.get("output_dir", "~/research/reports")).expanduser(),
        default_profile=defaults.get("profile", next(iter(profiles))),
        profiles=profiles,
        domain_tiers=raw.get("domain_tiers") or {},
        llm=raw.get("synthesis") or {},
        output=raw.get("output") or {},
        prompts=prompts,
    )
