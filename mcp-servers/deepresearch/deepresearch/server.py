"""MCP surface — v3, two pinned tools, zero knobs for the calling model.

Design rules:

  * deep_research(query)   — pinned to the profile named by PINNED_SYNC_PROFILE
    (default "standard"). Always blocks and returns the report inline.
    The profile's wall_clock_budget_s MUST be <= SYNC_CEILING_S; that is a
    config invariant, checked at startup.

  * deeper_research(query) — pinned to PINNED_ASYNC_PROFILE (default "deeper"),
    which must have wall_clock_budget_s: 0 (unlimited). Returns a job_id
    immediately; the model polls research_status, which blocks server-side
    so the model physically cannot spam — each call costs it nothing to say
    and the description tells it to stay silent between polls.

  * No rounds/sources/profile arguments on either tool. Every parameter
    exposed to the calling model is variability it will exercise at random.
    Profiles are operator territory: edit research.yml.

  * Overrides, when used internally, never mutate the shared Profile objects
    (that bug leaked per-call overrides into every subsequent job).
"""
from __future__ import annotations

import asyncio
import copy
import logging
import os
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

from fastmcp import Context, FastMCP

from . import config as cfgmod
from .pipeline import Pipeline, render_markdown

logging.basicConfig(
    level=os.environ.get("RESEARCH_LOG", "INFO"),
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)
log = logging.getLogger("deepresearch.server")

CFG = cfgmod.load(os.environ.get("RESEARCH_CONFIG"))
mcp = FastMCP("deep-research")

SYNC_CEILING_S = int(os.environ.get("RESEARCH_SYNC_CEILING_S", "300"))
POLL_WAIT_S = int(os.environ.get("RESEARCH_POLL_WAIT_S", "20"))
HARD_KILL_SLACK_S = 120  # pipeline has wall_clock_budget_s; we add slack
JOB_RETENTION_S = int(os.environ.get("RESEARCH_JOB_RETENTION_S", "7200"))
# MCP clients hard-cap tool calls at ~60s by default; progress notifications
# reset that timer. Ping well under 60s so we're never on the edge.
HEARTBEAT_INTERVAL_S = int(os.environ.get("RESEARCH_HEARTBEAT_S", "10"))

PINNED_SYNC_PROFILE = os.environ.get("RESEARCH_SYNC_PROFILE", "standard")
PINNED_ASYNC_PROFILE = os.environ.get("RESEARCH_ASYNC_PROFILE", "deeper")


def _startup_checks() -> None:
    """Fail loudly at boot, not at 2am mid-request."""
    if PINNED_SYNC_PROFILE not in CFG.profiles:
        raise SystemExit(
            f"sync profile {PINNED_SYNC_PROFILE!r} not in research.yml "
            f"(have: {sorted(CFG.profiles)})"
        )
    if PINNED_ASYNC_PROFILE not in CFG.profiles:
        raise SystemExit(
            f"async profile {PINNED_ASYNC_PROFILE!r} not in research.yml "
            f"(have: {sorted(CFG.profiles)})"
        )
    sb = CFG.profiles[PINNED_SYNC_PROFILE].wall_clock_budget_s
    if sb <= 0 or sb > SYNC_CEILING_S:
        raise SystemExit(
            f"profile {PINNED_SYNC_PROFILE!r} has wall_clock_budget_s={sb}; "
            f"the sync tool requires 0 < budget <= RESEARCH_SYNC_CEILING_S "
            f"({SYNC_CEILING_S}). Fix research.yml or the ceiling."
        )
    ab = CFG.profiles[PINNED_ASYNC_PROFILE].wall_clock_budget_s
    if ab != 0:
        log.warning(
            "async profile %r has wall_clock_budget_s=%d (0 = unlimited). "
            "It will be hard-killed at budget+slack; set 0 for unlimited.",
            PINNED_ASYNC_PROFILE, ab,
        )


_startup_checks()


@dataclass
class Job:
    id: str
    query: str
    profile: str
    state: str = "queued"      # queued | running | done | error | timeout
    stage: str = ""
    events: list[dict] = field(default_factory=list)
    result: dict | None = None
    error: str | None = None
    path: str | None = None
    task: Any = None
    done_event: Any = None     # asyncio.Event; set when job leaves running
    created: float = field(default_factory=time.time)


JOBS: dict[str, Job] = {}


def _prune_jobs() -> None:
    """Drop finished jobs older than the retention window. Results also live
    on disk (report_path), so nothing is lost."""
    now = time.time()
    stale = [
        jid for jid, j in JOBS.items()
        if j.state in ("done", "error", "timeout")
        and now - j.created > JOB_RETENTION_S
    ]
    for jid in stale:
        JOBS.pop(jid, None)


def _mk_progress(job: Job):
    def cb(**kw):
        job.stage = kw.get("stage", "")
        job.events.append(kw)
        if len(job.events) > 200:
            del job.events[:100]
    return cb


async def _heartbeat(ctx: Context, job: Job,
                     interval: int = HEARTBEAT_INTERVAL_S) -> None:
    """Keep the MCP client's request timer from firing during a long call.

    Default MCP tool-call timeout is 60s hard-coded in most client SDKs.
    Progress notifications reset that timer (Python SDK honors this; some
    TS/IDE clients don't). Without this heartbeat, a 5-minute pipeline
    dies at ~60s with `MCP error -32001` regardless of server budget.

    We ping every HEARTBEAT_INTERVAL_S seconds with whatever stage the
    pipeline was last on, plus an event counter for observability. Total
    is left None because we don't know how many events we'll ultimately
    emit — this is a keepalive, not a progress bar.
    """
    i = 0
    try:
        while True:
            await asyncio.sleep(interval)
            i += 1
            try:
                await ctx.report_progress(
                    progress=i, total=None,
                    message=f"{job.stage or 'working'} "
                            f"(events: {len(job.events)})",
                )
            except Exception:  # noqa: BLE001
                # A single failed notification shouldn't kill the beat.
                # Client may not support progress, transport may hiccup;
                # both are recoverable.
                pass
    except asyncio.CancelledError:
        return


def _payload_for_result(job: Job, *, include_markdown: bool = False) -> dict:
    r = dict(job.result or {})
    r["state"] = job.state
    r["job_id"] = job.id
    r["presentation_directive"] = (
        "Present the synthesis to the user as your response. Preserve every "
        "epistemic tag ([verified], [pattern_based_guess], [theoretical], "
        "[creative_riff]) exactly. Preserve every source citation. Do not "
        "quietly drop the contradictions or gaps sections — those are part "
        "of the answer. Do not summarize or reformat further. Do not narrate "
        "the research process."
    )
    if not include_markdown:
        r.pop("markdown", None)
    return r


async def _run_job(job: Job, overrides: dict | None):
    """Wraps the pipeline in a hard wait_for, but ONLY when the profile has a
    finite budget. Unlimited profiles are trusted to self-terminate (rounds
    exhausted or gap-check sufficiency)."""
    pipe = Pipeline(CFG, on_progress=_mk_progress(job))
    profile = copy.deepcopy(CFG.profile(job.profile))
    budget = profile.wall_clock_budget_s
    try:
        job.state = "running"
        coro = pipe.run(job.query, job.profile, overrides)
        if budget and budget > 0:
            report = await asyncio.wait_for(coro, timeout=budget + HARD_KILL_SLACK_S)
        else:
            report = await coro
        path = pipe.write(report)
        job.path = str(path)
        job.result = {
            "query": report.query,
            "profile": report.profile,
            "synthesis": report.synthesis,
            "stats": report.stats,
            "warnings": report.warnings,
            "sources": [
                {"id": s.sid, "title": s.title, "url": s.url, "domain": s.domain,
                 "tier": s.tier, "score": round(s.score, 3),
                 "published": s.published}
                for s in report.sources
            ],
            "report_path": str(path),
            "markdown": render_markdown(report),
        }
        job.state = "done"
    except asyncio.TimeoutError:
        job.state = "timeout"
        job.error = (
            f"Pipeline exceeded hard deadline ({budget + HARD_KILL_SLACK_S}s). "
            f"This is above the profile's wall_clock_budget_s; the pipeline "
            f"should have surfaced partial results before this fired."
        )
        log.error("job %s hard-killed", job.id)
    except Exception as e:  # noqa: BLE001
        log.exception("job %s failed", job.id)
        job.state = "error"
        job.error = f"{type(e).__name__}: {e}"
    finally:
        pipe.close()
        if job.done_event:
            job.done_event.set()


def _launch(query: str, profile: str, overrides: dict | None = None) -> Job:
    _prune_jobs()
    job = Job(
        id=uuid.uuid4().hex[:12],
        query=query,
        profile=profile,
        done_event=asyncio.Event(),
    )
    JOBS[job.id] = job
    job.task = asyncio.create_task(_run_job(job, overrides))
    return job


_ERROR_PAYLOAD = lambda job: {  # noqa: E731
    "state": job.state,
    "job_id": job.id,
    "error": job.error,
    "next_action": (
        "The job errored. Do not retry with a rephrased query — the failure "
        "is in the pipeline, not the query. Report the error to the user "
        "and stop."
    ),
}


# ─── deep_research (sync, ≤ ~5 min) ─────────────────────────────────────────

_n_eng = len(CFG.profiles[PINNED_SYNC_PROFILE].engines)

DEEP_RESEARCH_DESC = f"""Run a bounded research investigation (~5 minutes max) and return a sourced report.

This call BLOCKS until the report is ready and then returns it inline. One
call, one report. There is nothing to poll.

The pipeline plans and runs dozens of diversified searches across
{_n_eng} engines, fetches and scores sources, checks gaps, and synthesizes
a cited report with epistemic tags. All of that is internal — do not call
web_search or browser to "help", and do not call this tool twice with a
rephrased query.

Present the returned synthesis to the user as your answer, preserving
citations, epistemic tags, and the contradictions/gaps sections.

For open-ended investigations with no time limit, use deeper_research instead.
"""


@mcp.tool(description=DEEP_RESEARCH_DESC)
async def deep_research(query: str, ctx: Context) -> dict:
    job = _launch(query, PINNED_SYNC_PROFILE)
    budget = CFG.profile(PINNED_SYNC_PROFILE).wall_clock_budget_s
    sync_budget = min(budget + 30, SYNC_CEILING_S)

    # Keep the client's 60s request timer alive for the whole sync_budget
    # window. Cancelled in the finally so it never outlives this call.
    hb = asyncio.create_task(_heartbeat(ctx, job))
    try:
        try:
            await asyncio.wait_for(job.done_event.wait(), timeout=sync_budget)
        except asyncio.TimeoutError:
            # Should be unreachable given the startup invariant (budget <=
            # ceiling) plus pipeline self-enforcement; treat as a defect,
            # not a code path.
            return {
                "state": "running",
                "job_id": job.id,
                "next_action": (
                    f"Sync overrun — call research_status with "
                    f"job_id={job.id!r} and follow its instructions. Silently."
                ),
            }
    finally:
        hb.cancel()
        try:
            await hb
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass

    if job.state == "done":
        return _payload_for_result(job)
    return _ERROR_PAYLOAD(job)


# ─── deeper_research (async, unlimited) ─────────────────────────────────────

DEEPER_RESEARCH_DESC = f"""Start an UNBOUNDED research investigation for hard, open-ended questions.

This returns immediately with a job_id — the report is NOT ready yet. Then:

  1. Tell the user the investigation is underway (one sentence, once).
  2. Call research_status with the job_id. That call BLOCKS server-side for
     up to {POLL_WAIT_S}s and returns either the finished report or a
     still-running state.
  3. If still running, call research_status again with the same job_id.
     Repeat until state="done". Say NOTHING to the user between polls —
     no "still working" messages, no progress narration. Each poll is
     silent. When the report arrives, present it in full.

Do not call deeper_research twice for the same question. Do not use
web_search or browser alongside it. The investigation ends when it has
covered the question, not on a timer — expect several minutes to tens of
minutes.
"""


@mcp.tool(description=DEEPER_RESEARCH_DESC)
async def deeper_research(query: str) -> dict:
    job = _launch(query, PINNED_ASYNC_PROFILE)
    return {
        "state": "running",
        "job_id": job.id,
        "profile": PINNED_ASYNC_PROFILE,
        "next_action": (
            f"Job started. Call research_status with job_id={job.id!r}. It "
            f"blocks up to {POLL_WAIT_S}s per call. Poll silently — do not "
            f"message the user again until the report is in hand."
        ),
    }


# ─── research_status ────────────────────────────────────────────────────────

STATUS_DESC = f"""Wait for a deeper_research job and return its state.

This tool BLOCKS for up to {POLL_WAIT_S} seconds server-side before
returning. That is intentional — the wait is enforced here, not by you.
Do not sleep, do not narrate, do not tell the user you are waiting. Do not
send the user ANY message between calls to this tool.

If the return is state="done", the full report is in the synthesis field —
present it to the user directly. If the job is still running, call this tool
again with the same job_id, immediately and silently.
"""


@mcp.tool(description=STATUS_DESC)
async def research_status(job_id: str, ctx: Context) -> dict:
    job = JOBS.get(job_id)
    if not job:
        return {"state": "error",
                "error": f"unknown job_id {job_id!r}. Jobs do not survive "
                         f"server restart — start a new deeper_research call."}

    # POLL_WAIT_S defaults to 20 (well under the 60s client timeout), but
    # heartbeat here means bumping RESEARCH_POLL_WAIT_S past 60 doesn't
    # silently break.
    hb = asyncio.create_task(_heartbeat(ctx, job))
    try:
        try:
            await asyncio.wait_for(job.done_event.wait(), timeout=POLL_WAIT_S)
        except asyncio.TimeoutError:
            return {
                "state": job.state,
                "job_id": job.id,
                "stage": job.stage,
                "next_action": (
                    f"Job still running. Call research_status again with "
                    f"job_id={job.id!r}, immediately. Say nothing to the user."
                ),
            }
    finally:
        hb.cancel()
        try:
            await hb
        except (asyncio.CancelledError, Exception):  # noqa: BLE001
            pass

    if job.state == "done":
        return _payload_for_result(job)
    return {
        "state": job.state,
        "job_id": job.id,
        "error": job.error,
        "next_action": "Job did not complete successfully. Report the error "
                       "to the user and stop.",
    }


# ─── research_result — fallback fetch ───────────────────────────────────────

@mcp.tool(description=(
    "Fetch a completed research report by job_id. You normally do not need "
    "this — deep_research and research_status both return the report inline "
    "when the job is done. Use this only if you have a job_id but no result "
    "payload, e.g. after a client-side context reset. Finished jobs are "
    f"kept for {JOB_RETENTION_S // 3600}h; after that, reports live on disk "
    "under the output_dir in research.yml."
))
async def research_result(job_id: str, full: bool = False) -> dict:
    job = JOBS.get(job_id)
    if not job:
        return {"state": "error",
                "error": f"unknown job_id {job_id!r} (expired or never existed)"}
    if job.state != "done":
        return {"state": job.state, "job_id": job.id,
                "next_action": "Job not done. Call research_status, not this."}
    return _payload_for_result(job, include_markdown=full)


# ─── raw primitive ──────────────────────────────────────────────────────────

@mcp.tool(description=(
    "Raw primitive: run specific search queries across specific engines and "
    "return scored, text-extracted sources without synthesis. For driving "
    "the loop manually. Prefer deep_research unless you have a specific "
    "reason to bypass planning and synthesis."
))
async def research_search(queries: list[str], engines: list[str] | None = None,
                          limit: int = 10) -> dict:
    from .fetch import Fetcher
    from .searx import SearxClient

    p = copy.deepcopy(CFG.profile())   # never mutate the shared profile
    if engines:
        p.engines = engines
    pipe = Pipeline(CFG)
    try:
        async with SearxClient(CFG.searx_url, CFG.searx_timeout_s,
                               cache=pipe.cache) as sx, \
                Fetcher(p.fetch, cache=pipe.cache) as fx:
            srcs, seen = await pipe.collect_round(
                " ".join(queries), queries, p, sx, fx, 1, set())
        srcs = sorted(srcs, key=lambda s: -s.score)[:limit]
        return {"hits_seen": seen,
                "sources": [{**s.brief(3000), "score_parts": s.score_parts}
                            for s in srcs]}
    finally:
        pipe.close()


@mcp.tool(description="Show the active research config: profiles, engines, "
                      "weights, tiers. For debugging.")
async def research_config() -> dict:
    return {
        "config_path": str(cfgmod.DEFAULT_CONFIG_PATH),
        "searx_url": CFG.searx_url,
        "default_profile": CFG.default_profile,
        "pinned_sync_profile": PINNED_SYNC_PROFILE,
        "pinned_async_profile": PINNED_ASYNC_PROFILE,
        "sync_ceiling_s": SYNC_CEILING_S,
        "poll_wait_s": POLL_WAIT_S,
        "output_dir": str(CFG.output_dir),
        "profiles": {n: {"rounds": p.rounds,
                         "queries_per_round": p.queries_per_round,
                         "total_sources": p.total_sources,
                         "wall_clock_budget_s": p.wall_clock_budget_s,
                         "engines": p.engines}
                     for n, p in CFG.profiles.items()},
        "domain_tiers": CFG.domain_tiers,
    }


def main():
    transport = os.environ.get("RESEARCH_TRANSPORT", "stdio")
    if transport == "stdio":
        mcp.run()
    else:
        mcp.settings.host = os.environ.get("RESEARCH_HOST", "0.0.0.0")
        mcp.settings.port = int(os.environ.get("RESEARCH_PORT", "8899"))
        mcp.run(transport=transport)


if __name__ == "__main__":
    main()
