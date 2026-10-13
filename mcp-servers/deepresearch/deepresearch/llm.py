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


def _coerce_to_dict(parsed) -> dict | None:
    """If the model returned a bare list where the caller wants an object,
    try to salvage it before spending another round-trip. A planner that
    replied `["q1", "q2"]` instead of `{"queries": [...]}` is not actually
    wrong about the content, only the wrapping."""
    if isinstance(parsed, dict):
        return parsed
    if isinstance(parsed, list):
        # Common case: model returned the queries/gaps array bare.
        # We can't know the intended key with certainty, but callers use
        # `.get("queries")` or `.get("gaps")` etc. -- publishing the list
        # under all the likely keys is cheap. Callers that expected a
        # different shape will just see empty results and move on rather
        # than crash.
        return {"_bare_list": parsed, "queries": parsed, "gaps": parsed,
                "key_findings": parsed}
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

    async def _post_chat(self, msgs: list[dict], *, json_mode: bool = False,
                         max_tokens: int | None = None) -> str:
        """Fire one chat/completions request. Handles the LM Studio 400
        fallback (strict endpoints reject response_format et al) transparently.
        """
        body: dict = {
            "model": self.model,
            "messages": msgs,
            "temperature": self.temperature,
            "max_tokens": max_tokens or self.max_tokens,
            "stream": False,
        }
        if json_mode:
            # LM Studio 0.4.20+ requires json_schema, not the older json_object.
            # We use a permissive object schema -- any keys allowed -- because
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
                # Strict endpoint -- strip optional keys and retry.
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

    async def complete(self, prompt: str, *, system: str | None = None,
                       json_mode: bool = False, max_tokens: int | None = None) -> str:
        await self.resolve_model()
        msgs = ([{"role": "system", "content": system}] if system else []) + [
            {"role": "user", "content": prompt}
        ]
        return await self._post_chat(msgs, json_mode=json_mode, max_tokens=max_tokens)

    async def json_call(self, prompt: str, *, system: str | None = None,
                        retries: int = 2, max_tokens: int | None = None) -> dict:
        """Call the model, insist on a JSON object back.

        Retry strategy: the big prompt (synthesis can be 50k+ tokens) goes down
        the wire ONCE. Corrections are short follow-up turns on the same
        conversation, so we're paying kilobytes-per-retry instead of megabytes.
        Server-side prefix caching (LM Studio, vLLM, llama.cpp all have it)
        makes the retries near-free on the compute side too.

        A bare JSON array on the final attempt is salvaged rather than left to
        crash the caller -- the content is usually right, only the wrapping is
        wrong. Earlier attempts still ask the model to correct itself so the
        salvage is a last resort, not the default.
        """
        await self.resolve_model()
        msgs: list[dict] = (
            ([{"role": "system", "content": system}] if system else [])
            + [{"role": "user", "content": prompt}]
        )
        last = ""
        for attempt in range(retries + 1):
            txt = await self._post_chat(msgs, json_mode=True, max_tokens=max_tokens)
            parsed = parse_json_loose(txt)

            # Fast path: got an object as designed.
            if isinstance(parsed, dict):
                return parsed

            # Salvage path: last attempt, list with usable content.
            # Costs zero extra round-trips.
            if attempt == retries:
                coerced = _coerce_to_dict(parsed)
                if coerced is not None:
                    log.warning(
                        "json_call: model returned %s on final attempt; "
                        "salvaged into dict wrapper",
                        type(parsed).__name__,
                    )
                    return coerced

            last = txt
            # Build a short correction turn instead of concatenating to the
            # original prompt. Truncate the broken reply -- it's usually
            # garbage and inflating context helps no one.
            if parsed is None:
                correction = (
                    "Your previous reply was not valid JSON. "
                    "Reply with ONLY a JSON object (starting with `{` and "
                    "ending with `}`). No prose, no code fences, no commentary."
                )
                log.warning("json parse failed (attempt %d)", attempt + 1)
            else:
                correction = (
                    f"You returned a JSON {type(parsed).__name__}, not an object. "
                    f"Reply with a JSON object (curly braces `{{...}}`) using the "
                    f"fields originally requested. Do not wrap it in an array."
                )
                log.warning(
                    "json_call got %s instead of dict (attempt %d)",
                    type(parsed).__name__, attempt + 1,
                )
            msgs.append({"role": "assistant", "content": txt[:2000]})
            msgs.append({"role": "user", "content": correction})

        raise ValueError(
            f"model never returned parseable JSON dict. Last: {(last or '')[:400]}"
        )
