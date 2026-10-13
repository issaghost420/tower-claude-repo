# chat-convert + scrollscrub — the chat laundry

Two tools, one job: take **any** chat dump and get it into LM Studio or Open WebUI as
**real history** the model conditions on — not a transcript it just comments on.

```
   ┌─────────────┐        ┌──────────────┐        ┌─────────────┐
   │ scrollscrub │  md →  │ chat-convert │  sql → │   sqlite    │
   │  ⊳ LAUNDER  │ ─────▶ │   (dryer)    │ ─────▶ │  webui.db   │
   │ (the chute) │        │              │        │             │
   └─────────────┘        └──────────────┘        └─────────────┘
    dump anything           makes clean              real chat,
    in, get clean           LM Studio /              model thinks
    markdown out            OWUI output              it's its own
```

**Chute** = scrollscrub washes any format into clean markdown.
**Dryer** = chat-convert turns that markdown into LM Studio files or OWUI SQL.

---

## TL;DR — the only commands you need

**Into Open WebUI** (the usual case):

```bash
# 1. open scrollscrub, paste your dump, hit ⊳ Launder, copy the output, save as chat.md
# 2. one command:
owui-import chat.md
# 3. it prints the 4 apply lines — paste them. done.
```

**Into LM Studio:**

```bash
lm-import chat.md
# prints the mv command — paste it. done.
```

That's it. Everything below is detail for when something's weird.

---

## Step 1 — The chute (scrollscrub ⊳ Launder)

Open `scrollscrub.html` in a browser. Paste your chat dump into the **left** box.
Hit **⊳ Launder** (orange button). Clean markdown appears on the **right**. Copy it,
save it as a `.md` file.

**What you can dump in:**
- aichat `.yaml` sessions
- ChatGPT / Claude / any JSON export
- LM Studio `.conversation.json`
- Open WebUI exports
- ChatML (`<|im_start|>user`)
- plain markdown with `Human:` / `Claude:` / `## User` labels
- basically anything with speaker markers in it

**How it decides:** if it's valid JSON, it reads the structure directly (reliable, no
guessing). If it's not JSON, it normalizes the text labels into `## User` / `## Assistant`.

**If Launder says "no speaker markers found":** the format has a label style it hasn't
seen. Open `scrollscrub.html`, find the `USER_MARKERS` / `ASSISTANT_MARKERS` lists near
the top of the `launder()` function, add one line for the new label, done forever. That's
the whole maintenance story — one line per new format you ever meet.

You can skip the chute entirely if your file is already clean markdown
(`## User` / `## Assistant`) or a JSON format chat-convert already knows.

---

## Step 2 — The dryer (chat-convert)

```
chat-convert [options] <input-file-or-dir>
```

| Flag | What it does | Default |
|------|--------------|---------|
| `--to FORMAT` | `lmstudio` · `openwebui` · `json` · `md` | `json` |
| `--title TITLE` | override the conversation title | filename |
| `--user-id UUID` | OWUI user id (needed for `--to openwebui`) | — |
| `--model NAME` | model tag for OWUI imports | `imported-chat` |
| `--output PATH` | output file or dir | stdout |

**You usually don't call this directly** — use `owui-import` / `lm-import` (next section),
which fill in your user-id and paths automatically.

### Inputs it auto-detects (no flags)
markdown (`## User` / `User:` / `Claude:` / `H:` / `A:` / bold / quoted / bare label),
LM Studio, Open WebUI (normal + wrapped), OpenAI (object + array), workpent, and its own
canonical JSON.

### Outputs
- **`lmstudio`** → a `.conversation.json` you drop in LM Studio's conversations folder
- **`openwebui`** → a `.sql` file you run against `webui.db` (see apply steps below)
- **`json`** → canonical `{title, messages:[{role,text}]}` (for inspecting / piping)
- **`md`** → clean `## User` / `## Assistant` markdown

---

## Step 3 — The wrappers (your defaults baked in)

### `owui-import` — markdown/json → Open WebUI

```bash
owui-import chat.md                      # output → /tmp/owui-import-<time>.sql
owui-import chat.md my-import.sql         # or name the output
```

It runs chat-convert with your user-id already set, then **prints the exact apply
commands** with your real db path:

```bash
systemctl stop open-webui
cp "$DB_PATH"{,.bak-$(date +%s)}     # always backs up first
sqlite3 "$DB_PATH" < /tmp/owui-import-….sql
systemctl start open-webui
```

Copy those four lines, paste them, and the chat is in as genuine history.

> Your defaults live at the top of the `owui-import` wrapper in the `.nix` file:
> `USER_ID` and `DB_PATH`. Change them there if they ever move.

### `lm-import` — markdown/json → LM Studio

```bash
lm-import chat.md
```

Builds the `.conversation.json` and prints the `mv` into LM Studio's conversations dir.

---

## Why SQL and not drag-into-the-UI

Dragging a file into the OWUI web UI just posts a conversation you can look at. Writing
it into `webui.db` makes it **real history** — the prior assistant turns sit in the actual
assistant slots, so the model conditions on them as its own output and continues the
pattern. That's the whole point. SQL is the only route that does this. There is
deliberately no drag-into-UI export in this tool.

---

## Install (NixOS)

```nix
# configuration.nix
imports = [ ./chat-convert.nix ];
```

```bash
sudo nixos-rebuild switch
```

Pulls in `jq`, `gawk`, `util-linux` (`uuidgen`), `coreutils` automatically. Installs three
commands: `chat-convert`, `owui-import`, `lm-import`.

---

## When something breaks

**Launder output is empty / "no speaker markers found"**
The input has a label style scrollscrub doesn't recognize. Add one line to the marker
lists in `scrollscrub.html` (see Step 1). Or eyeball the dump — if it has no speaker
labels at all, nothing can find the turns; add labels by hand first.

**chat-convert: "no user/assistant messages found"**
The markdown labels weren't recognized. Run it through scrollscrub Launder first — that's
what the chute is for. Confirm your file actually has `## User` / `## Assistant` (or
`User:` / `Claude:` etc.) at the start of lines.

**chat-convert: "unknown JSON shape"**
A JSON format with no handler. Don't fight it — paste it into scrollscrub Launder, which
reads arbitrary JSON structurally and hands back clean markdown chat-convert can eat.

**Imported chat shows today's date instead of the original**
chat-convert preserves the source timestamp when the export includes one (`exportedAt`,
`createdAt`, `timestamp`). If the source had none, it uses "now" — there's nothing to
recover. Workpent and LM Studio exports carry real times; bare markdown does not.

**OWUI turns look out of order** (rare)
Only happens on branched/edited OWUI exports. Flag it and the message-ordering can be
made to follow the parent/child chain instead of insertion order.

**Single-letter labels (`H:` / `A:`) eating normal text**
They're case-sensitive and need a space after the colon, on purpose. If your content
still trips them, drop those two patterns from the parser.

---

## The pieces, in one line each

- **scrollscrub** — browser tool; ⊳ Launder washes any dump → clean markdown. Maintain the marker map (one line per new format).
- **chat-convert** — CLI; clean markdown / known JSON → LM Studio file or OWUI SQL. Preserves timestamps.
- **owui-import / lm-import** — thin wrappers with your user-id, db path, and apply commands baked in.
