# Patches — 2026-09-17

Two independent bugs, one archive. Both are in `deepresearch/`.

## 1. `llm.py` — `AttributeError: 'list' object has no attribute 'get'`

### Bug

`parse_json_loose()` correctly returns `dict | list | None`. `json_call()`
was returning any non-None value straight to callers. All callers in
`pipeline.py` do `data.get(...)`, `gc.get(...)`, etc. When the local model
responded with a bare JSON array (`["q1", "q2"]`) instead of the expected
object (`{"queries": ["q1", "q2"]}`) — which small models do occasionally
on planner and gap-check prompts — the list flowed through and blew up.

Both `og-version/` and `claude-version-broken/` share the same `llm.py`
inheritance path, so both showed the same crash. Not a nixpkgs issue.

### Fix

1. `json_call()` enforces `isinstance(parsed, dict)`. Anything else
   triggers retry, or salvage on the last attempt.
2. Refactored HTTP into `_post_chat(msgs, ...)` so `json_call()` can build
   its own conversation history. `complete()` is unchanged externally.
3. **Retry no longer re-sends the big prompt.** Old behavior appended a
   correction line to the original prompt string and re-fired the whole
   thing — a synthesis retry cost 50k+ tokens over the wire per attempt.
   New behavior sends the big prompt once, then appends
   `[assistant: broken_reply, user: short_correction]` turns. Corrections
   are ~150 bytes; broken assistant reply is truncated to 2k. Server-side
   prefix cache (LM Studio, vLLM, llama.cpp all have it) makes the retry
   near-free on compute too.
4. New `_coerce_to_dict()` salvages a bare list on the *final* attempt
   only — publishes it under `queries`, `gaps`, `key_findings`,
   `_bare_list`. Callers that expected something else see empty results
   and continue rather than crash.

### Verified offline

- dict on first try → 1 call
- list then dict → 2 calls, second is 164 bytes larger, not 50k+
- list × 3 → salvaged into dict, all keys present
- garbage × 3 → clean `ValueError`, not `AttributeError`

---

## 2. `server.py` — `MCP error -32001: Request timed out`

### Bug

Nearly every MCP client SDK has a **hard-coded 60-second default timeout**
on tool calls. `deep_research` blocks up to 300s (`SYNC_CEILING_S`). The
pipeline emits progress events but `_mk_progress` only appends them to
`job.events` — nothing ever leaves the server over MCP. Client sees no
activity, counts to 60, kills the request with `-32001`.

This is not related to any nixpkgs update. It's a structural gap:
progress-events-as-internal-log, never wired to `Context.report_progress()`.

### Fix

New `_heartbeat(ctx, job)` coroutine that emits
`await ctx.report_progress(...)` every `HEARTBEAT_INTERVAL_S` (default 10s,
overridable via `RESEARCH_HEARTBEAT_S`). Progress notifications reset the
client's request timer per the MCP spec.

Wired into both `deep_research` and `research_status`. `research_status`
currently only blocks 20s (safe) but heartbeating it means bumping
`RESEARCH_POLL_WAIT_S` past 60 in future won't silently reintroduce this.

`ctx: Context` is now a parameter on both tools — FastMCP auto-injects.
Doesn't show up in the tool schema the calling model sees.

### Verified offline

- Heartbeat fires 3 times in 3.5s at 1s interval
- Cancels immediately when `done_event` fires — no leaked pings
- Survives a `report_progress` exception mid-beat without dying

### Client-side caveat

Progress-resets-timeout is **reliable in the Python MCP SDK** (which
mcpo uses). It's **not reliable** in some TS clients or Cursor's ACP path —
those hard-cap at 60s regardless of progress. Your stack (Open WebUI →
mcpo → deepresearch) is Python all the way through, so this should hold.

If it doesn't, the timeout is coming from a different layer. Two likely
suspects:

1. **mcpo's own MCP client timeout.** mcpo uses the Python SDK; the
   default is 60s per tool call. Check mcpo's config for a `timeout`
   knob per server, or set the `MCP_SERVER_REQUEST_TIMEOUT` env var if
   your version honors it.
2. **Open WebUI's HTTP client timeout** when calling the mcpo OpenAPI
   endpoint. This is a separate layer entirely from MCP. If the -32001
   error text looks like it's wrapped in an HTTP layer error, that's the
   suspect.

If the heartbeat lands and the client still dies at ~60s, the pattern will
be visible in logs — you'll see `_heartbeat` firing (Python SDK logs
outgoing notifications at DEBUG) but the client still killing the request.
That's the signal it's a downstream client that doesn't honor progress.
Fallback in that case: make `deep_research` return a `job_id` immediately
like `deeper_research` does, and let the model poll.

### Environment knobs

- `RESEARCH_HEARTBEAT_S` — heartbeat interval in seconds (default 10)
- Existing knobs unchanged: `RESEARCH_SYNC_CEILING_S`,
  `RESEARCH_POLL_WAIT_S`, `RESEARCH_JOB_RETENTION_S`
