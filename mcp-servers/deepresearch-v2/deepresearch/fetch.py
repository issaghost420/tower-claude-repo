"""Page fetch + extraction.

Hard rule: never return raw HTML anywhere. Extraction happens here, at the edge.
Everything downstream (scoring, synthesis, the calling model) sees clean text or
nothing. This is the single biggest lever on whether a research tool is usable.
"""
from __future__ import annotations

import asyncio
import logging

import httpx

log = logging.getLogger("deepresearch.fetch")

try:
    import trafilatura
    _HAVE_TRAFILATURA = True
except ImportError:  # pragma: no cover
    _HAVE_TRAFILATURA = False

SKIP_EXT = (".pdf", ".zip", ".mp4", ".mp3", ".jpg", ".png", ".gif", ".webm", ".iso")
JS_WALL_MARKERS = ("enable javascript", "checking your browser", "cf-browser-verification",
                   "just a moment", "captcha")


class Fetcher:
    def __init__(self, cfg, cache=None):
        self.cfg = cfg
        self.cache = cache
        self._sem = asyncio.Semaphore(cfg.concurrency)
        self._client: httpx.AsyncClient | None = None

    async def __aenter__(self):
        self._client = httpx.AsyncClient(
            timeout=self.cfg.timeout_s,
            follow_redirects=True,
            headers={"User-Agent": self.cfg.user_agent,
                     "Accept-Language": "en-US,en;q=0.9"},
            limits=httpx.Limits(max_connections=self.cfg.concurrency * 2),
        )
        return self

    async def __aexit__(self, *exc):
        if self._client:
            await self._client.aclose()

    async def get(self, url: str) -> dict:
        if self.cache:
            hit = self.cache.get_page(url)
            if hit is not None:
                return hit

        if url.lower().rsplit("?", 1)[0].endswith(SKIP_EXT):
            out = {"status": None, "title": "", "text": "", "published": None,
                   "error": "skipped_binary"}
            self._store(url, out)
            return out

        async with self._sem:
            out = await self._fetch_once(url)

        if (out.get("error") or len(out.get("text", "")) < self.cfg.min_content_chars) \
                and self.cfg.browser_fallback:
            alt = await self._browser_fetch(url)
            if alt and len(alt.get("text", "")) > len(out.get("text", "")):
                out = alt

        self._store(url, out)
        return out

    async def _fetch_once(self, url: str) -> dict:
        try:
            r = await self._client.get(url)
        except Exception as e:  # noqa: BLE001
            return {"status": None, "title": "", "text": "", "published": None,
                    "error": f"{type(e).__name__}: {e}"}

        ctype = r.headers.get("content-type", "")
        if "html" not in ctype and "text" not in ctype and "xml" not in ctype:
            return {"status": r.status_code, "title": "", "text": "", "published": None,
                    "error": f"non_html:{ctype}"}
        raw = r.content[: self.cfg.max_bytes]
        html = raw.decode(r.encoding or "utf-8", errors="replace")

        title, text, published = self._extract(html, url)
        low = text[:500].lower()
        err = None
        if r.status_code >= 400:
            err = f"http_{r.status_code}"
        elif any(m in low for m in JS_WALL_MARKERS) and len(text) < 1200:
            err = "js_wall"
        return {"status": r.status_code, "title": title, "text": text,
                "published": published, "error": err}

    def _extract(self, html: str, url: str) -> tuple[str, str, str | None]:
        if not _HAVE_TRAFILATURA:
            import re
            txt = re.sub(r"<script.*?</script>|<style.*?</style>", " ", html,
                         flags=re.S | re.I)
            txt = re.sub(r"<[^>]+>", " ", txt)
            txt = re.sub(r"\s+", " ", txt).strip()
            m = re.search(r"<title[^>]*>(.*?)</title>", html, re.S | re.I)
            return (m.group(1).strip() if m else ""), txt, None
        try:
            text = trafilatura.extract(
                html, url=url, include_comments=False, include_tables=True,
                favor_precision=True, no_fallback=False,
            ) or ""
            md = trafilatura.extract_metadata(html, default_url=url)
            title = (md.title or "") if md else ""
            published = (md.date or None) if md else None
            return title, text, published
        except Exception as e:  # noqa: BLE001
            log.debug("extract failed %s: %s", url, e)
            return "", "", None

    async def _browser_fetch(self, url: str) -> dict | None:
        """Playwright fallback. Only fires on JS walls / thin extractions, so the
        expensive path stays rare. Requires playwright installed."""
        try:
            from playwright.async_api import async_playwright
        except ImportError:
            return None
        try:
            async with async_playwright() as pw:
                browser = await pw.chromium.launch(
                    args=["--disable-gpu", "--disable-software-rasterizer", "--no-sandbox"]
                )
                page = await browser.new_page(user_agent=self.cfg.user_agent)
                await page.goto(url, timeout=self.cfg.timeout_s * 1000,
                                wait_until="domcontentloaded")
                await page.wait_for_timeout(1200)
                html = await page.content()
                await browser.close()
            title, text, published = self._extract(html, url)
            return {"status": 200, "title": title, "text": text,
                    "published": published, "error": None if text else "empty_after_browser"}
        except Exception as e:  # noqa: BLE001
            log.debug("browser fallback failed %s: %s", url, e)
            return None

    def _store(self, url: str, out: dict) -> None:
        if self.cache:
            self.cache.put_page(
                url, status=out.get("status"), title=out.get("title", ""),
                text=out.get("text", ""), published=out.get("published"),
                error=out.get("error"),
            )

    async def get_many(self, urls: list[str]) -> dict[str, dict]:
        results = await asyncio.gather(*(self.get(u) for u in urls),
                                       return_exceptions=True)
        out = {}
        for u, r in zip(urls, results):
            out[u] = r if not isinstance(r, BaseException) else {
                "status": None, "title": "", "text": "", "published": None,
                "error": f"{type(r).__name__}: {r}",
            }
        return out
