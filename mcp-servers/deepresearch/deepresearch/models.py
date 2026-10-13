from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

TRACKING_PARAMS = re.compile(
    r"^(utm_\w*|fbclid|gclid|msclkid|mc_cid|mc_eid|ref|ref_src|igshid|si|source|"
    r"_ga|yclid|dclid|twclid|spm|scid|campaign_id)$",
    re.I,
)


def canonical_url(url: str) -> str:
    """Strip fragments, tracking params, trailing slash, normalize host.
    Two URLs that canonicalize identically are the same source."""
    try:
        s = urlsplit(url)
    except ValueError:
        return url
    host = (s.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    if s.port and s.port not in (80, 443):
        host = f"{host}:{s.port}"
    q = [(k, v) for k, v in parse_qsl(s.query, keep_blank_values=False)
         if not TRACKING_PARAMS.match(k)]
    q.sort()
    path = s.path.rstrip("/") or "/"
    return urlunsplit(("https", host, path, urlencode(q), ""))


def domain_of(url: str) -> str:
    host = (urlsplit(url).hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def _tokens(text: str) -> list[str]:
    return re.findall(r"[a-z0-9]{3,}", text.lower())


def simhash(text: str, bits: int = 64) -> int:
    """64-bit simhash over 3-token shingles. Near-duplicate detection for
    syndicated articles that live at different URLs."""
    toks = _tokens(text)
    if len(toks) < 3:
        return 0
    shingles = [" ".join(toks[i:i + 3]) for i in range(len(toks) - 2)]
    v = [0] * bits
    for sh in shingles:
        h = int.from_bytes(hashlib.blake2b(sh.encode(), digest_size=8).digest(), "big")
        for i in range(bits):
            v[i] += 1 if (h >> i) & 1 else -1
    out = 0
    for i in range(bits):
        if v[i] > 0:
            out |= 1 << i
    return out


def hamming(a: int, b: int) -> int:
    return bin(a ^ b).count("1")


@dataclass
class SearchHit:
    """One result row from one engine. Pre-fetch."""
    url: str
    title: str = ""
    snippet: str = ""
    engines: set[str] = field(default_factory=set)
    queries: set[str] = field(default_factory=set)
    published: str | None = None
    best_rank: int = 999
    pageno: int = 1

    @property
    def canon(self) -> str:
        return canonical_url(self.url)

    @property
    def domain(self) -> str:
        return domain_of(self.url)

    def merge(self, other: "SearchHit") -> None:
        self.engines |= other.engines
        self.queries |= other.queries
        self.best_rank = min(self.best_rank, other.best_rank)
        self.pageno = min(self.pageno, other.pageno)
        if not self.published and other.published:
            self.published = other.published
        if len(other.snippet) > len(self.snippet):
            self.snippet = other.snippet


@dataclass
class Source:
    """A hit that has been fetched, extracted and scored."""
    sid: str
    url: str
    title: str
    domain: str
    tier: str
    text: str
    published: str | None
    engines: list[str]
    queries: list[str]
    score: float
    score_parts: dict[str, float]
    simhash: int
    fetched_at: str
    round_no: int
    sidechain: str | None = None
    error: str | None = None

    def brief(self, max_chars: int = 6000) -> dict:
        return {
            "id": self.sid,
            "title": self.title,
            "url": self.url,
            "domain": self.domain,
            "tier": self.tier,
            "published": self.published,
            "score": round(self.score, 3),
            "engines": self.engines,
            "excerpt": self.text[:max_chars],
        }


@dataclass
class RoundRecord:
    n: int
    queries: list[str]
    rationale: str
    hits_seen: int
    new_sources: int
    sidechain: str | None = None


@dataclass
class Report:
    query: str
    profile: str
    started: str
    finished: str | None = None
    rounds: list[RoundRecord] = field(default_factory=list)
    sources: list[Source] = field(default_factory=list)
    synthesis: dict = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)
    stats: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        d = asdict(self)
        for s in d["sources"]:
            s.pop("text", None)
        return d


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
