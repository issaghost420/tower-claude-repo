"""Internal model calls: planner, gap-check, synthesis.

This talks to YOUR endpoint (LM Studio / vLLM / whatever). The calling model
never sees these. That separation is the whole point of the architecture --
research discipline lives here, deterministically, instead of being negotiated
with whatever 8B model happens to be loaded in the chat window.
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path

import httpx
from jinja2 import Environment, FileSystemLoader, select_autoescape

log = logging.getLogger("deepresearch.llm")

_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.S)


def parse_json_loose(text: str) -> dict | list | None:
    """Local models emit preamble, fences, trailing commentary, and sometimes
    two JSON objects. Try progressively dirtier strategies."""
    if not text:
        return None
    for cand in (text, *(m.group(1) for m in _FENCE.finditer(text))):
        cand = cand.strip()
        try:
            return json.loads(cand)
        except json.JSONDecodeError:
            pass
    # brace matching for the first complete object/array
    for opener, closer in (("{", "}"), ("[", "]")):
        start = text.find(opener)
        if start == -1:
            continue
        depth, in_str, esc = 0, False, False
        for i in range(start, len(text)):
            c = text[i]
            if in_str:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == '"':
                    in_str = False
                continue
            if c == '"':
                in_str = True
            elif c == opener:
                depth += 1
            elif c == closer:
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start:i + 1])
                    except json.JSONDecodeError:
                        break
    return None


class LLM:
    def __init__(self, cfg: dict, prompts: dict[str, Path]):
        self.endpoint = cfg.get("endpoint", "http://localhost:1234/v1").rstrip("/")
        self.model = cfg.get("model", "local-model")
        # Key comes from the environment, never from the YAML. Anything you put
        # in a nix config lands in /nix/store world-readable.
        import os as _os
        self.api_key = _os.environ.get(
            cfg.get("api_key_env", "RESEARCH_LLM_KEY"), "not-needed"
        )
        self.temperature = cfg.get("temperature", 0.3)
        self.max_tokens = cfg.get("max_tokens", 4096)
        self.timeout = cfg.get("timeout_s", 300)
        self.prompts = prompts
        self._model_resolved = False
        dirs = {p.parent for p in prompts.values()} or {Path(".")}
        self.env = Environment(
            loader=FileSystemLoader([str(d) for d in dirs]),
            autoescape=select_autoescape(enabled_extensions=()),
            trim_blocks=True, lstrip_blocks=True,
        )

    def render(self, name: str, **ctx) -> str:
        path = self.prompts.get(name)
        if not path or not path.exists():
            raise FileNotFoundError(f"prompt template {name!r} not found ({path})")
        return self.env.get_template(path.name).render(**ctx)

    async def resolve_model(self, client: httpx.AsyncClient | None = None) -> str:
        """Ask the endpoint what's actually loaded.

        LM Studio serves one model at a time and you swap it constantly. A
        hardcoded name in the YAML goes stale the moment you load something
        else, and fails at synthesis time rather than at startup. Set
        `model: auto` and this asks instead of assuming.
        """
        if self._model_resolved or self.model.strip().lower() not in (
            "", "auto", "change-me", "detect",
        ):
            self._model_resolved = True
            return self.model

        own = client is None
        c = client or httpx.AsyncClient(timeout=30)
        try:
            r = await c.get(f"{self.endpoint}/models",
                            headers={"Authorization": f"Bearer {self.api_key}"})
            r.raise_for_status()
            ids = [m.get("id") for m in (r.json().get("data") or []) if m.get("id")]
        except Exception as e:  # noqa: BLE001
            raise RuntimeError(
                f"model is set to 'auto' but {self.endpoint}/models failed: "
                f"{type(e).__name__}: {e}. If this is an auth error, the key in "
                f"api_key_env isn't reaching the process."
            ) from e
        finally:
            if own:
                await c.aclose()

        if not ids:
            raise RuntimeError(
                f"{self.endpoint}/models returned no models. Load one in LM Studio."
            )
        self.model = ids[0]
        self._model_resolved = True
        log.info("auto-detected model: %s", self.model)
        return self.model

    async def complete(self, prompt: str, *, system: str | None = None,
                       json_mode: bool = False, max_tokens: int | None = None) -> str:
        await self.resolve_model()
        msgs = ([{"role": "system", "content": system}] if system else []) + [
            {"role": "user", "content": prompt}
        ]
        body = {
            "model": self.model,
            "messages": msgs,
            "temperature": self.temperature,
            "max_tokens": max_tokens or self.max_tokens,
            "stream": False,
        }
        if json_mode:
            # LM Studio 0.4.20+ requires json_schema, not the older json_object.
            # We use a permissive object schema — any keys allowed — because
            # each caller (planner, gap, synth) needs a different shape and
            # the prompt already specifies it. This just forces "output valid
            # JSON of some kind" without constraining the structure.
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {
                    "name": "response",
                    "strict": False,
                    "schema": {"type": "object", "additionalProperties": True},
                },
            }
        async with httpx.AsyncClient(timeout=self.timeout) as c:
            r = await c.post(
                f"{self.endpoint}/chat/completions",
                json=body,
                headers={"Authorization": f"Bearer {self.api_key}"},
            )
            if r.status_code == 400:
                # Strict endpoint — strip optional keys and retry.
                stripped = False
                for k in ("response_format", "chat_template_kwargs",
                          "reasoning_effort"):
                    if body.pop(k, None) is not None:
                        stripped = True
                if stripped:
                    r = await c.post(
                        f"{self.endpoint}/chat/completions", json=body,
                        headers={"Authorization": f"Bearer {self.api_key}"},
                    )
            r.raise_for_status()
            data = r.json()
        return data["choices"][0]["message"]["content"] or ""

    async def json_call(self, prompt: str, *, system: str | None = None,
                        retries: int = 2, max_tokens: int | None = None):
        last = None
        for attempt in range(retries + 1):
            txt = await self.complete(prompt, system=system, json_mode=True,
                                      max_tokens=max_tokens)
            # --- repetition guard ---
            # Local models that hit their context ceiling start looping: the
            # same JSON block (or fragments of it) appears 2-5+ times in the
            # output. Detect this and truncate to the first complete object
            # before parsing.
            txt = _truncate_repeated_json(txt)

            parsed = parse_json_loose(txt)
            if parsed is not None:
                return parsed
            last = txt
            prompt = (prompt + "\n\nYour previous reply was not valid JSON. "
                      "Reply with ONLY a JSON object. No prose, no code fences.")
            log.warning("json parse failed (attempt %d)", attempt + 1)
        raise ValueError(f"model never returned parseable JSON. Last: {(last or '')[:400]}")


def _truncate_repeated_json(text: str) -> str:
    """If the output contains a complete JSON object followed by what looks
    like a second copy (opening brace after closing brace), truncate at the
    end of the first object. This catches the most common local-model
    context-overflow symptom: valid JSON → garbage/repeated JSON."""
    if not text or text.count("{") < 2:
        return text

    # Find the end of the first top-level brace-balanced object
    depth = 0
    in_str = False
    esc = False
    start = text.find("{")
    if start == -1:
        return text

    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                remainder = text[i + 1:].strip()
                if remainder:
                    log.warning(
                        "truncated %d chars of post-JSON output (repetition guard)",
                        len(remainder),
                    )
                return text[: i + 1]
    return text
