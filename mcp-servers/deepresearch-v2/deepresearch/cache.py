"""SQLite cache for fetched page content and search result sets.

Doubles as a forensic record: every URL the tool ever touched, when, what it got,
and what failed. Query it directly with sqlite3 when you want to know what the
tool actually saw versus what it reported.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS pages (
  key TEXT PRIMARY KEY,
  url TEXT NOT NULL,
  status INTEGER,
  title TEXT,
  text TEXT,
  published TEXT,
  error TEXT,
  fetched_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS searches (
  key TEXT PRIMARY KEY,
  query TEXT NOT NULL,
  engines TEXT,
  pageno INTEGER,
  payload TEXT,
  fetched_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS pages_url ON pages(url);
CREATE INDEX IF NOT EXISTS searches_query ON searches(query);
"""


def _k(*parts: str) -> str:
    return hashlib.blake2b("\x00".join(parts).encode(), digest_size=16).hexdigest()


class Cache:
    def __init__(self, path: Path, ttl_hours: int = 168):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(path), check_same_thread=False)
        self.db.executescript(SCHEMA)
        self.db.commit()
        self.ttl = ttl_hours * 3600

    def _fresh(self, ts: float) -> bool:
        return (time.time() - ts) < self.ttl

    # --- pages ---
    def get_page(self, url: str) -> dict | None:
        row = self.db.execute(
            "SELECT status,title,text,published,error,fetched_at FROM pages WHERE key=?",
            (_k("page", url),),
        ).fetchone()
        if not row or not self._fresh(row[5]):
            return None
        return {
            "status": row[0], "title": row[1], "text": row[2],
            "published": row[3], "error": row[4], "fetched_at": row[5],
        }

    def put_page(self, url: str, *, status: int | None, title: str, text: str,
                 published: str | None, error: str | None) -> None:
        self.db.execute(
            "INSERT OR REPLACE INTO pages VALUES (?,?,?,?,?,?,?,?)",
            (_k("page", url), url, status, title, text, published, error, time.time()),
        )
        self.db.commit()

    # --- searches ---
    def get_search(self, query: str, engines: list[str], pageno: int) -> list | None:
        key = _k("search", query, ",".join(sorted(engines)), str(pageno))
        row = self.db.execute(
            "SELECT payload,fetched_at FROM searches WHERE key=?", (key,)
        ).fetchone()
        if not row or not self._fresh(row[1]):
            return None
        return json.loads(row[0])

    def put_search(self, query: str, engines: list[str], pageno: int, payload: list) -> None:
        key = _k("search", query, ",".join(sorted(engines)), str(pageno))
        self.db.execute(
            "INSERT OR REPLACE INTO searches VALUES (?,?,?,?,?,?)",
            (key, query, ",".join(sorted(engines)), pageno, json.dumps(payload), time.time()),
        )
        self.db.commit()

    def close(self) -> None:
        self.db.close()
