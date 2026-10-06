---
description: Start Mycelora — persistent memory for Claude
argument-hint: [space] or "help"
---

# Command /mycelora:start

Initializes Mycelora, Claude's persistent memory.

## Decision flow

### 1. Check the connection (always first)

The `mycelora_*` tools come from the connector bundled with the plugin ("Mycelora OAuth"), or from a connector added by hand. Their prefix varies with the connector name (`mcp__Mycelora__`, `mcp__Mycelora_OAuth__`...). Load them if needed (tool search), then call `mycelora_list_spaces()` with no arguments. There is no `mycelora_whoami`, `mycelora_login` or `mycelora_signup` tool: never call them.

**If the list of spaces comes back:** the user is connected. Go to step 2. Never pass a `userId`: the server resolves the identity from the connection and ignores any value sent.

**If no `mycelora_*` tool is available, or the call fails (401, authentication error):** display:

```
Mycelora — Smart memory for Claude

Mycelora gives Claude a persistent memory across your conversations:
decisions, learnings, contacts, facts, reflections...

The Mycelora connector is not connected yet.
Connect it once: Your plugins, Mycelora, Connectors tab, Connect
(chat and Cowork; Claude Code asks you to sign in by itself),
then run /mycelora:start again.
If you added the connector by hand: Settings, Connectors
(server https://api.mycelora.ai/functions/v1/mycelora-mcp), sign in,
then run /mycelora:start again.
No account yet: create one at https://mycelora.ai

Dashboard : https://mycelora.ai
```

Then stop.

### 2. User connected — handle the arguments

The brief returned by `mycelora_session_start` may carry a line `[jeton-hook-session ...]` on its first line. It is a technical token read by the local hooks: never display it, copy it or quote it.

Choose a `sessionId` of the form `surface-YYYY-MM-DD-topic`. The server may timestamp it: in that case use the one it returns in all later calls, until closing.

If `$ARGUMENTS` is empty or absent:
- Run `mycelora_session_start(sessionId)` without `spaceId`.
- Display the welcome block with spaces, commands and Dashboard link.
- Ask "Which space are we working on?"

If `$ARGUMENTS` = "help":
- Read `${CLAUDE_PLUGIN_ROOT}/skills/mycelora/SKILL.md`.
- Display the "Natural-language commands" table reformatted into thematic blocks.

If `$ARGUMENTS` = a space name (e.g. "Product launch", "Marketing"):
- Find the space's UUID in the list from step 1 (exact name, otherwise the closest; when in doubt, ask the user, never guess).
- Run `mycelora_session_start(sessionId, spaceId: <UUID>)`.
- Load `read_memory(spaceId, type:"all")`.
- Display the context and ask for confirmation.

If `$ARGUMENTS` = "out" or "fin":
- Follow the skill's closing protocol (§ CLOSING PROTOCOL), in this order:
  1. `mycelora_session_end_atoms` with the sessionId returned at opening;
  2. `mycelora_session_end` with `spaceId`, workSummary, decisions, pendingTasks, the five structured lists, and the space's updated codex in the `codex` field (old form: the codex served at opening plus the thread's delta; MAP form: fields `sujets` and `enBref` instead of `codex`, only the topics touched, each reread beforehand with `read_memory(sujets)`; see the skill's Codex section).
- Language: write the handover lists and the codex in the user's language, structure keywords included (French: EN BREF / - En vigueur / - À faire / - Piège / - Réfuté / - Chiffre; English: IN SHORT / - In force / - To do / - Pitfall / - Refuted / - Figure, "(ref. x)"). Never translate existing content.
- Without a supplied codex, the server keeps the old one as is. Check in the response that the `codex` block carries `accepte: true`; otherwise fix it according to its reasons and resubmit through `mycelora_write_memory(type:"codex")`, without re-running `session_end`. Exception: any error saying NOTHING WAS WRITTEN (e.g. "Topics refused", "codex and sujets/enBref are mutually exclusive", a missing `workSummary`, an incomplete closing) means nothing was written, handover included: fix what the message names and call `session_end` again.

If `$ARGUMENTS` = "stats":
- Call `mycelora_get_stats` and display the counters.

### 3. Always display the Dashboard link

Every /mycelora:start response must end with:
```
Dashboard : https://mycelora.ai
```
