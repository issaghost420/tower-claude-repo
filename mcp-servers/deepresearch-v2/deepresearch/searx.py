"""SearXNG JSON client.

Talks to SearXNG directly on the LAN, not through a reverse proxy. Engine
selection is per-query so different queries in the same round can hit different
engine sets -- that is a diversification lever, not just a plumbing detail.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Iterable

import httpx

from .models import SearchHit

log = logging.getLogger("deepresearch.searx")


class SearxClient:
    def __init__(self, base_url: str, timeout_s: int = 30, cache=None,
                 max_concurrent: int = 8):
        self.base = base_url.rstrip("/")
        self.timeout = timeout_s
        self.cache = cache
        self._sem = asyncio.Semaphore(max_concurrent)
        self._client: httpx.AsyncClient | None = None

    async def __aenter__(self):
        self._client = httpx.AsyncClient(
            timeout=self.timeout,
            headers={"Accept": "application/json"},
            follow_redirects=True,
        )
        return self

    async def __aexit__(self, *exc):
        if self._client:
            await self._client.aclose()

    async def search(self, query: str, engines: list[str], pageno: int = 1,
                     limit: int = 10, language: str = "en") -> list[SearchHit]:
        if self.cache:
            cached = self.cache.get_search(query, engines, pageno)
            if cached is not None:
                return [self._row_to_hit(r, query, i) for i, r in enumerate(cached[:limit])]

        params = {
            "q": query,
            "format": "json",
            "pageno": pageno,
            "language": language,
            "safesearch": 0,
        }
        if engines:
            params["engines"] = ",".join(engines)

        async with self._sem:
            try:
                r = await self._client.get(f"{self.base}/search", params=params)
                r.raise_for_status()
                data = r.json()
            except httpx.HTTPStatusError as e:
                # 403 here almost always means SearXNG's limiter is on or the
                # json format isn't enabled in settings.yml.
                log.warning("searx %s for %r: %s", e.response.status_code, query, e)
                return []
            except Exception as e:  # noqa: BLE001
                log.warning("searx failed for %r: %s", query, e)
                return []

        rows = data.get("results", []) or []
        if self.cache:
            self.cache.put_search(query, engines, pageno, rows[: max(limit, 50)])
        return [self._row_to_hit(r, query, i) for i, r in enumerate(rows[:limit])]

    @staticmethod
    def _row_to_hit(row: dict, query: str, rank: int) -> SearchHit:
        eng = row.get("engines") or ([row["engine"]] if row.get("engine") else [])
        return SearchHit(
            url=row.get("url", ""),
            title=(row.get("title") or "").strip(),
            snippet=(row.get("content") or "").strip(),
            engines=set(eng),
            queries={query},
            published=row.get("publishedDate"),
            best_rank=rank,
            pageno=row.get("pageno", 1) or 1,
        )

    async def multi(self, queries: Iterable[str], engine_sets: list[list[str]],
                    pageno: int = 1, limit: int = 10) -> dict[str, SearchHit]:
        """Run queries x engine_sets concurrently, merge into a canonical-URL map."""
        tasks = [
            self.search(q, eng, pageno=pageno, limit=limit)
            for q in queries
            for eng in engine_sets
        ]
        merged: dict[str, SearchHit] = {}
        for batch in await asyncio.gather(*tasks, return_exceptions=True):
            if isinstance(batch, BaseException):
                log.warning("search batch error: %s", batch)
                continue
            for hit in batch:
                if not hit.url:
                    continue
                key = hit.canon
                if key in merged:
                    merged[key].merge(hit)
                else:
                    merged[key] = hit
        return merged

    async def health(self) -> dict:
        try:
            r = await self._client.get(
                f"{self.base}/search",
                params={"q": "test", "format": "json"},
            )
            return {"ok": r.status_code == 200, "status": r.status_code,
                    "json": "application/json" in r.headers.get("content-type", "")}
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e)}
