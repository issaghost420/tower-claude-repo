"""The research loop.

plan -> [search -> fetch -> score -> gap-check]xN -> sidechains -> synthesize

Everything here is driven by the Profile object. If a number appears literally
in this file and it isn't a loop guard, that's a config-schema bug.
"""
from __future__ import annotations

import asyncio
import copy
import json
import logging
import random
import time
from pathlib import Path

from . import score as sc
from .cache import Cache
from .config import Config, Profile
from .fetch import Fetcher
from .llm import LLM
from .models import Report, RoundRecord, Source, now_iso, simhash
from .searx import SearxClient

log = logging.getLogger("deepresearch.pipeline")


def _engine_sets(profile: Profile, n_sets: int, rnd: random.Random) -> list[list[str]]:
    """Rotate engine subsets across queries so we're not asking the same three
    engines everything. Cross-engine coverage is the cheapest diversity we get."""
    pool = list(profile.engines)
    if not pool:
        return [[]]
    k = min(profile.engines_per_query, len(pool))
    sets = []
    for i in range(max(n_sets, 1)):
        rotated = pool[i * k % len(pool):] + pool[: i * k % len(pool)]
        chosen = rotated[:k]
        if len(chosen) < k:
            chosen += rnd.sample([e for e in pool if e not in chosen], k - len(chosen))
        sets.append(chosen)
    return sets


class Pipeline:
    def __init__(self, cfg: Config, on_progress=None):
        self.cfg = cfg
        self.cache = Cache(cfg.cache_path, cfg.cache_ttl_hours)
        self.llm = LLM(cfg.llm, cfg.prompts)
        self.on_progress = on_progress or (lambda **kw: None)

    def _progress(self, stage: str, **kw):
        try:
            self.on_progress(stage=stage, **kw)
        except Exception:  # noqa: BLE001
            pass

    # ------------------------------------------------------------------ plan
    async def plan(self, query: str, profile: Profile, seen_queries: list[str],
                   round_no: int, prior_findings: str = "",
                   gaps: list[str] | None = None) -> tuple[list[str], str]:
        prompt = self.llm.render(
            "planner",
            query=query,
            round_no=round_no,
            total_rounds=profile.rounds,
            n_queries=profile.queries_per_round,
            strategy=profile.diversification.strategy,
            require_negative_case=profile.diversification.require_negative_case,
            seen_queries=seen_queries,
            prior_findings=prior_findings,
            gaps=gaps or [],
        )
        kept: list[str] = []
        rationale = ""
        for attempt in range(profile.diversification.max_regen_attempts):
            data = await self.llm.json_call(prompt, max_tokens=1500)
            cand = [str(q) for q in (data.get("queries") or [])]
            rationale = data.get("rationale", rationale)
            k, rejected = sc.filter_diverse(
                cand, seen_queries + kept, profile.diversification.min_edit_distance
            )
            kept.extend(k)
            if len(kept) >= profile.queries_per_round:
                break
            if rejected:
                prompt += (
                    f"\n\nThese queries were REJECTED as too similar to prior ones: "
                    f"{json.dumps(rejected)}. Generate materially different angles "
                    f"-- different vocabulary, different facet, different source type."
                )
        return kept[: profile.queries_per_round], rationale

    # ---------------------------------------------------------------- search
    async def collect_round(self, query: str, queries: list[str], profile: Profile,
                            searx: SearxClient, fetcher: Fetcher, round_no: int,
                            known_urls: set[str], sidechain: str | None = None
                            ) -> tuple[list[Source], int]:
        rnd = random.Random(f"{query}:{round_no}")
        esets = _engine_sets(profile, len(queries), rnd)
        pageno = 1
        hits = await searx.multi(queries, esets, pageno=pageno,
                                 limit=profile.results_per_query)
        fresh = {k: v for k, v in hits.items() if k not in known_urls}

        # Page 2+ only when page 1 came back thin. Deeper pages are lower quality
        # by construction; going there by default just adds noise.
        while (profile.escalate_pageno_if_thin
               and len(fresh) < profile.thin_round_threshold
               and pageno < profile.max_pageno):
            pageno += 1
            self._progress("escalate_page", round=round_no, pageno=pageno)
            more = await searx.multi(queries, esets, pageno=pageno,
                                     limit=profile.results_per_query)
            for k, v in more.items():
                if k in hits:
                    hits[k].merge(v)
                elif k not in known_urls:
                    fresh[k] = v
                    hits[k] = v

        # tier filter before we spend any bandwidth
        candidates = []
        for canon, hit in fresh.items():
            tier = self.cfg.tier_of(hit.domain)
            if tier == "blocked":
                continue
            candidates.append((canon, hit, tier))

        # prefetch-rank on metadata alone so we don't fetch 200 pages
        n_eng = len(profile.engines) or 5
        candidates.sort(key=lambda t: -sc.agreement_score(t[1], n_eng))
        budget = max(profile.total_sources, profile.queries_per_round * 4)
        candidates = candidates[:budget]

        self._progress("fetching", round=round_no, n=len(candidates))
        pages = await fetcher.get_many([h.url for _, h, _ in candidates])

        sources: list[Source] = []
        for canon, hit, tier in candidates:
            page = pages.get(hit.url, {})
            text = page.get("text") or ""
            if len(text) < profile.fetch.min_content_chars:
                continue
            published = hit.published or page.get("published")
            hit.published = published
            s_, parts = sc.score_source(hit, text, tier, query, profile.scoring, n_eng)
            if s_ < profile.min_score_to_keep:
                continue
            sources.append(Source(
                sid="", url=hit.url, title=(page.get("title") or hit.title or hit.url),
                domain=hit.domain, tier=tier, text=text, published=published,
                engines=sorted(hit.engines), queries=sorted(hit.queries),
                score=s_, score_parts=parts, simhash=simhash(text[:20000]),
                fetched_at=now_iso(), round_no=round_no, sidechain=sidechain,
            ))
        return sources, len(hits)

    # ------------------------------------------------------------- gap check
    async def gap_check(self, query: str, sources: list[Source], profile: Profile) -> dict:
        if not sources:
            return {"gaps": [], "unknown_entities": [], "sufficient": False,
                    "findings_summary": ""}
        prompt = self.llm.render(
            "gap",
            query=query,
            sources=[s.brief(1800) for s in sources[:20]],
            triggers=profile.sidechain.triggers,
        )
        try:
            return await self.llm.json_call(prompt, max_tokens=1500)
        except Exception as e:  # noqa: BLE001
            log.warning("gap check failed: %s", e)
            return {"gaps": [], "unknown_entities": [], "sufficient": False,
                    "findings_summary": ""}

    # ------------------------------------------------------------------- run
    @staticmethod
    def _budget_exceeded(profile: Profile, started: float) -> bool:
        """wall_clock_budget_s == 0 means unlimited (operator-enrolled via the
        async profile). Any positive value is enforced."""
        b = profile.wall_clock_budget_s
        return b > 0 and (time.monotonic() - started) > b

    async def run(self, query: str, profile_name: str | None = None,
                  overrides: dict | None = None) -> Report:
        # Deep copy: overrides apply to THIS run only. Mutating the cached
        # profile leaks per-call parameters into every later job.
        profile = copy.deepcopy(self.cfg.profile(profile_name))
        if overrides:
            for k, v in overrides.items():
                if hasattr(profile, k):
                    setattr(profile, k, v)

        started = time.monotonic()
        report = Report(query=query, profile=profile.name, started=now_iso())
        known_urls: set[str] = set()
        seen_queries: list[str] = []
        all_sources: list[Source] = []
        findings = ""
        gaps: list[str] = []
        entities: list[str] = []

        async with SearxClient(self.cfg.searx_url, self.cfg.searx_timeout_s,
                               cache=self.cache) as searx, \
                Fetcher(profile.fetch, cache=self.cache) as fetcher:

            health = await searx.health()
            if not health.get("ok"):
                report.warnings.append(f"searxng health check failed: {health}")

            for rn in range(1, profile.rounds + 1):
                if self._budget_exceeded(profile, started):
                    report.warnings.append(f"wall clock budget hit after round {rn - 1}")
                    break
                self._progress("planning", round=rn)
                queries, rationale = await self.plan(
                    query, profile, seen_queries, rn, findings, gaps
                )
                if not queries:
                    report.warnings.append(f"round {rn}: planner produced no novel queries")
                    break
                seen_queries.extend(queries)
                self._progress("searching", round=rn, queries=queries)

                new, seen_n = await self.collect_round(
                    query, queries, profile, searx, fetcher, rn, known_urls
                )
                known_urls |= {s.url for s in new}
                all_sources.extend(new)
                report.rounds.append(RoundRecord(
                    n=rn, queries=queries, rationale=rationale,
                    hits_seen=seen_n, new_sources=len(new),
                ))
                self._progress("round_done", round=rn, new=len(new),
                               total=len(all_sources))

                gc = await self.gap_check(query, all_sources, profile)
                findings = gc.get("findings_summary", findings) or findings
                gaps = [str(g) for g in (gc.get("gaps") or [])]
                entities = [str(e) for e in (gc.get("unknown_entities") or [])]
                if gc.get("sufficient") and rn >= 2:
                    report.warnings.append(
                        f"stopped early at round {rn}: gap check reported sufficiency"
                    )
                    break

            # ------------------------------------------------------ sidechains
            if profile.sidechain.enabled and (gaps or entities):
                targets = (entities + gaps)[: profile.sidechain.max_sidechains]
                for t in targets:
                    if self._budget_exceeded(profile, started):
                        report.warnings.append("wall clock budget hit before sidechains done")
                        break
                    self._progress("sidechain", target=t)
                    sub = copy.deepcopy(profile)
                    sub.rounds = profile.sidechain.rounds
                    sub.queries_per_round = profile.sidechain.queries
                    sub.total_sources = profile.sidechain.sources
                    sub_qs, _ = await self.plan(t, sub, seen_queries, 1)
                    if not sub_qs:
                        continue
                    seen_queries.extend(sub_qs)
                    subs, _ = await self.collect_round(
                        t, sub_qs, sub, searx, fetcher, 99, known_urls, sidechain=t
                    )
                    subs = sorted(subs, key=lambda s: -s.score)[: profile.sidechain.sources]
                    known_urls |= {s.url for s in subs}
                    all_sources.extend(subs)
                    report.rounds.append(RoundRecord(
                        n=99, queries=sub_qs, rationale=f"sidechain: {t}",
                        hits_seen=0, new_sources=len(subs), sidechain=t,
                    ))

        # ------------------------------------------------------------- select
        kept, dup = sc.dedupe_by_simhash(all_sources)
        kept, capped = sc.apply_domain_cap(kept, profile.max_per_domain)
        kept = sorted(kept, key=lambda s: -s.score)[: profile.total_sources]
        for i, s in enumerate(kept, 1):
            s.sid = f"S{i}"
        report.sources = kept
        report.stats = {
            "sources_considered": len(all_sources),
            "dropped_near_duplicate": len(dup),
            "dropped_domain_cap": len(capped),
            "sources_kept": len(kept),
            "unique_domains": len({s.domain for s in kept}),
            "tier1_share": round(
                sum(1 for s in kept if s.tier == "tier1") / max(len(kept), 1), 2),
            "queries_run": len(seen_queries),
            "elapsed_s": round(time.monotonic() - started, 1),
        }

        # ---------------------------------------------------------- synthesize
        self._progress("synthesizing", sources=len(kept))
        report.synthesis = await self.synthesize(query, kept, report)
        report.finished = now_iso()
        return report

    async def synthesize(self, query: str, sources: list[Source], report: Report) -> dict:
        if not sources:
            return {"answer": "No usable sources retrieved.", "confidence": "none",
                    "key_findings": [], "contradictions": [], "gaps": [
                        "Every search round came back empty or below quality threshold."]}
        out_cfg = self.cfg.output
        budget = out_cfg.get("synthesis_char_budget", 90000)
        per = max(int(budget / max(len(sources), 1)), 1500)
        prompt = self.llm.render(
            "synth",
            query=query,
            sources=[s.brief(per) for s in sources],
            sections=out_cfg.get("sections", []),
            taxonomy=(out_cfg.get("epistemic_tags") or {}).get("taxonomy", []),
            require_tags=(out_cfg.get("epistemic_tags") or {}).get("required", True),
            claim_citation=out_cfg.get("claim_citation", "mandatory"),
            stats=report.stats,
        )
        try:
            return await self.llm.json_call(prompt, max_tokens=self.llm.max_tokens)
        except Exception as e:  # noqa: BLE001
            log.error("synthesis failed: %s", e)
            return {"answer": f"Synthesis step failed: {e}", "confidence": "none",
                    "key_findings": [], "contradictions": [], "gaps": [],
                    "error": str(e)}

    # ---------------------------------------------------------------- output
    def write(self, report: Report) -> Path:
        self.cfg.output_dir.mkdir(parents=True, exist_ok=True)
        slug = "".join(c if c.isalnum() else "-" for c in report.query.lower())[:60]
        stem = f"{report.started[:19].replace(':', '')}-{slug}".strip("-")
        md = self.cfg.output_dir / f"{stem}.md"
        js = self.cfg.output_dir / f"{stem}.json"
        js.write_text(json.dumps(report.to_dict(), indent=2, default=str))
        md.write_text(render_markdown(report))
        return md

    def close(self):
        self.cache.close()


def render_markdown(report: Report) -> str:
    s = report.synthesis
    L = [f"# {report.query}", "",
         f"*profile `{report.profile}` · {report.started} → {report.finished} · "
         f"{report.stats.get('sources_kept', 0)} sources / "
         f"{report.stats.get('unique_domains', 0)} domains · "
         f"{report.stats.get('elapsed_s', 0)}s*", ""]
    if s.get("confidence"):
        L += [f"**Confidence:** {s['confidence']}", ""]
    if s.get("answer"):
        L += ["## Answer", "", str(s["answer"]), ""]
    for key, title in (("key_findings", "Key findings"),
                       ("contradictions", "Contradictions between sources"),
                       ("gaps", "Gaps / what this did not establish")):
        items = s.get(key) or []
        if items:
            L += [f"## {title}", ""]
            for it in items:
                if isinstance(it, dict):
                    tag = f" `[{it['tag']}]`" if it.get("tag") else ""
                    cites = f" ({', '.join(it.get('sources', []))})" if it.get("sources") else ""
                    L.append(f"- {it.get('claim') or it.get('text', '')}{tag}{cites}")
                else:
                    L.append(f"- {it}")
            L.append("")
    if report.warnings:
        L += ["## Run warnings", ""] + [f"- {w}" for w in report.warnings] + [""]
    L += ["## Sources", ""]
    for src in report.sources:
        date = f" · {src.published[:10]}" if src.published else ""
        L.append(f"- **{src.sid}** [{src.title}]({src.url}) — `{src.domain}` "
                 f"{src.tier} · score {src.score:.2f}{date} · "
                 f"engines: {', '.join(src.engines)}")
    L += ["", "## Query trail", ""]
    for r in report.rounds:
        label = f"sidechain → {r.sidechain}" if r.sidechain else f"round {r.n}"
        L.append(f"**{label}** ({r.new_sources} new)")
        for q in r.queries:
            L.append(f"  - `{q}`")
        if r.rationale:
            L.append(f"  - *{r.rationale}*")
    return "\n".join(L)
