"""Deterministic scoring. No model calls in this file, on purpose.

Asking an LLM to rank sources is slow, non-reproducible across runs, and no
better than a weighted formula you can inspect and tune. Every score returned
here decomposes into named parts so you can see exactly why a source ranked
where it did.
"""
from __future__ import annotations

import math
import re
from datetime import datetime, timezone
from difflib import SequenceMatcher

from .models import SearchHit, hamming

TIER_VALUE = {"tier1": 1.0, "tier2": 0.55, "tier3": 0.15, "blocked": 0.0}


def _parse_date(s: str | None) -> datetime | None:
    if not s:
        return None
    s = s.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%d",
                "%Y-%m", "%Y", "%d %B %Y", "%B %d, %Y"):
        try:
            d = datetime.strptime(s[: len(fmt) + 8], fmt)
            return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    m = re.search(r"(19|20)\d{2}", s)
    if m:
        return datetime(int(m.group(0)), 6, 15, tzinfo=timezone.utc)
    return None


def recency_score(published: str | None, halflife_days: float) -> float:
    d = _parse_date(published)
    if not d:
        return 0.4  # unknown date is neutral-ish, not a penalty
    age = (datetime.now(timezone.utc) - d).days
    if age < 0:
        return 1.0
    return math.exp(-math.log(2) * age / max(halflife_days, 1.0))


def term_density(text: str, query: str) -> float:
    terms = {t for t in re.findall(r"[a-z0-9]{4,}", query.lower())}
    if not terms or not text:
        return 0.0
    toks = re.findall(r"[a-z0-9]{4,}", text.lower())
    if not toks:
        return 0.0
    hits = sum(1 for t in toks if t in terms)
    covered = len({t for t in terms if t in set(toks)}) / len(terms)
    density = min(hits / max(len(toks), 1) * 40, 1.0)
    return 0.6 * covered + 0.4 * density


def length_score(text: str) -> float:
    n = len(text)
    if n < 500:
        return n / 500 * 0.3
    return min(0.3 + math.log10(n / 500) * 0.5, 1.0)


def agreement_score(hit: SearchHit, engines_available: int) -> float:
    """Cross-engine consensus. A URL that surfaces on four independent engines is
    meaningfully stronger than one that ranks #1 on Google alone -- and this
    naturally punishes SEO farms, which win single-engine rankings and lose
    consensus. Also folds in rank and query-coverage."""
    n_eng = len(hit.engines)
    consensus = min(n_eng / max(min(engines_available, 5), 1), 1.0)
    rank_bonus = max(0.0, 1.0 - hit.best_rank / 20.0)
    query_bonus = min(len(hit.queries) / 3.0, 1.0)
    return 0.6 * consensus + 0.25 * rank_bonus + 0.15 * query_bonus


def score_source(hit: SearchHit, text: str, tier: str, query: str,
                 cfg, engines_available: int) -> tuple[float, dict]:
    w = cfg
    parts = {
        "cross_engine_agreement": agreement_score(hit, engines_available),
        "domain_tier": TIER_VALUE.get(tier, 0.5),
        "recency": 1.0 if tier in (w.ignore_recency_for_tiers or [])
        else recency_score(hit.published, w.recency_halflife_days),
        "term_density": term_density(text, query),
        "content_length": length_score(text),
    }
    weights = {
        "cross_engine_agreement": w.cross_engine_agreement,
        "domain_tier": w.domain_tier,
        "recency": w.recency,
        "term_density": w.term_density,
        "content_length": w.content_length,
    }
    total = sum(parts[k] * weights[k] for k in parts)
    denom = sum(weights.values()) or 1.0
    return total / denom, {k: round(v, 3) for k, v in parts.items()}


# --- diversification enforcement -------------------------------------------

def similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, a.lower().strip(), b.lower().strip()).ratio()


def filter_diverse(new: list[str], seen: list[str], min_edit_distance: float) -> tuple[list[str], list[str]]:
    """Reject queries too close to anything already run, or to each other.

    This is where most implementations quietly fail: the planner emits four
    rephrasings of the same question, you get one round of results four times,
    and the report looks thorough while being shallow. Enforce it structurally.
    """
    threshold = 1.0 - min_edit_distance
    kept, rejected = [], []
    pool = list(seen)
    for q in new:
        q = q.strip()
        if not q:
            continue
        if any(similarity(q, p) > threshold for p in pool):
            rejected.append(q)
        else:
            kept.append(q)
            pool.append(q)
    return kept, rejected


def dedupe_by_simhash(sources: list, threshold: int = 3) -> tuple[list, list]:
    """Same article syndicated across five outlets is one source, not five."""
    kept, dropped = [], []
    for s in sorted(sources, key=lambda x: -x.score):
        if s.simhash and any(hamming(s.simhash, k.simhash) <= threshold
                             for k in kept if k.simhash):
            dropped.append(s)
        else:
            kept.append(s)
    return kept, dropped


def apply_domain_cap(sources: list, max_per_domain: int) -> tuple[list, list]:
    counts: dict[str, int] = {}
    kept, dropped = [], []
    for s in sorted(sources, key=lambda x: -x.score):
        c = counts.get(s.domain, 0)
        if c >= max_per_domain:
            dropped.append(s)
        else:
            counts[s.domain] = c + 1
            kept.append(s)
    return kept, dropped
