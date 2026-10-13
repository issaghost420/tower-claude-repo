# Patch — `llm.py` (2026-09-17)

## Bug

`AttributeError: 'list' object has no attribute 'get'` crashing `deeper_research`.

`parse_json_loose()` correctly returns `dict | list | None`. `json_call()` was
returning any non-`None` value straight to callers. All callers in
`pipeline.py` do `data.get("queries")`, `gc.get("findings_summary")`, etc.
When the local model responded with a bare JSON array (`["q1", "q2"]`)
instead of the expected object (`{"queries": ["q1", "q2"]}`) — which small
models do occasionally, especially on the planner and gap-check prompts —
the list flowed through and blew up on `.get()`.

Both `og-version/` and `claude-version-broken/` share the same `llm.py`
inheritance path, so both surfaces show the same symptom. Not a nixpkgs
flake issue.

## Fix

`deepresearch/llm.py`:

1. `json_call()` now enforces `isinstance(parsed, dict)`. Anything else
   triggers a retry (or salvage on the last attempt).
2. Refactored the HTTP call into `_post_chat(msgs, ...)` so `json_call()`
   can build its own conversation history. `complete()` is unchanged
   externally.
3. **Retry no longer re-sends the big prompt.** Old behavior appended a
   correction line to the original prompt string and re-fired the whole
   thing — so a synthesis retry cost 50k+ tokens over the wire per
   attempt. New behavior sends the big prompt once, then appends
   `[assistant: broken_reply, user: short_correction]` turns. Correction
   turns are ~150 bytes each; broken assistant reply is truncated to 2k.
   Server-side prefix cache (LM Studio / vLLM / llama.cpp all have it)
   makes this near-free on compute too.
4. New `_coerce_to_dict()` salvages a bare list on the *final* attempt
   only — publishes it under `queries`, `gaps`, `key_findings`, and
   `_bare_list`. Callers that expected something else see empty results
   and continue rather than crash. Earlier attempts still ask the model
   to fix its own shape, so this is a last-resort fallback.

## Verified

Ran an offline test with a fake `_post_chat` (real endpoint not needed):

- dict on first try → 1 call, no retries
- list then dict → 2 calls; second call is 164 bytes larger than first,
  not 50k+
- list × 3 → salvaged into dict, no crash, all keys present
- garbage × 3 → clean `ValueError` naming the last raw reply

## What to check on your side

If retries are firing often, look at which prompt template the model is
choking on. `planner.j2` and `gap.j2` are the most likely — they ask for
short JSON objects and small models sometimes drop the wrapper. If it's
`synth.j2`, that's a bigger deal — synthesis is where the 50k prompt
lives and the token savings really matter.

Log lines to grep:
- `json_call got list instead of dict` — model returned an array
- `json parse failed` — unparseable garbage
- `salvaged into dict wrapper` — hit the last-resort fallback
