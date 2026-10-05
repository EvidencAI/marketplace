# Mycelora — Technical reference

Consult this document on demand, not every turn: for a technical detail, in case of error, or at the user's request.

---

## Configuration

Two channels give access to the memory (details: install.md):

| Channel | What the user needs |
|-------|-------------------------------|
| Mycelora plugin (Claude directory) | Nothing to configure: skills and hooks work once the plugin is enabled |
| Mycelora connector (claude.ai / Claude Desktop) | OAuth sign-in (recommended), or an API key `mk_live_...` for advanced use |

`userId` is ignored by the server, which resolves the identity from the connection: do not pass it.

`mycelora_get_profile()` returns principles, portrait and instructions. First setup: see ONBOARDING.md.

---

## Atom types

| Type | Answers | Natural scope | Expires with age | Typical triggers |
|------|----------|------------------|------------------|----------------------|
| regle | how to act here: decision in force, method, preference, instruction | local or cross-cutting | no | "we're going with X", "always do it this way" |
| piege | what fails and why, paid for at least once | cross-cutting | no | "I learned that", "don't do X anymore" |
| refute | what must no longer be believed | local or cross-cutting | no | "actually no", "that was wrong" |
| repere | where, who, how much, how it is made: pointer, figure, contact, identifier | local | no | verifiable fact, figure, path, "Alex is the CEO" |
| etat | where we stand, what is waiting | local | **yes** | "this is where we are", "what's left is" |
| non_affecte | fits none of the other five | local | no | a hand-sorting pile, not a choice |

Analyze the content; do not map mechanically. `portee` is mandatory for `regle` and `refute` (refused without it). `perime_si` is optional: the condition that will make the memory false.

Older types (`fact`, `decision`, `position`, `intention`, `event`, `contact`, `contradiction`, `signal_externe`, `apprentissage`, `reflexion`) are abandoned: existing atoms stay readable, but never create new ones with them.

---

## MCP tools

Grouped by domain:

**Spaces**: list_spaces, create_space, update_space, suggest_spaces
**Atoms**: search_atoms, create_atom_manual, update_atom, toggle_pin_atom
**Context**: get_context (modes: auto, onboard, recall, briefing, explore), recall (automatic contextual recall used by the hook)
**Maintenance**: get_stats, health_check, triage_atoms, garbage_collect
**Sessions**: session_start, session_end, session_end_atoms
**Memory**: write_memory, read_memory
**Profile**: get_profile, update_profile, get_calibration
**Contacts**: upsert_contact, search_contacts
**Ingestion**: ingest_document, ingest_events, process_events, collect_events
**Sources**: create_source, disconnect_source, test_source_connection, google_consent_url
**API keys**: create_api_key, list_api_keys, revoke_api_key
**Insights and tensions**: cross_insights, analyze_space, ack_tension, ack_alerte, close_topic, reopen_topic
**Documents**: list_documents
**Connections**: create_connection
**Extraction**: log_exchange, extract_atoms (called by the hooks)
**Sync**: sync_status
**Export**: export_memory, export_status
**Feedback**: submit_feedback
**Account**: delete_account

All names carry the `mycelora_` prefix. `log_exchange` is called by the hooks: do not call it routinely.

`spaceId` accepts the space name (case-insensitive) or the UUID, including on `read_memory` and `write_memory`.

---

## get_context modes

| Mode | Atoms | Usage |
|------|--------|-------|
| auto | variable | Default, adaptive |
| onboard | 25 | Thread opening |
| recall | 8 | One-off recall |
| briefing | 15 | Project summary |
| explore | 20 | Brainstorm, exploration |

---

## ingest_events — event format

Each element of the `events` array:

| Field | Required | Type | Example |
|-------|--------|------|---------|
| source | yes | string, constrained values (below) | "gmail" |
| event_type | yes | string, constrained values (below) | "mail_received" |
| event_id | yes | string | unique identifier (deduplication) |
| event_timestamp | yes | ISO 8601 string | "2026-07-14T09:00:00Z" |
| subject | no | string | — |
| body_preview | no | string | — |
| participants | no | array of strings | — |
| metadata | no | free-form object | — |

Constrained values (any other value is rejected at insertion and counted in `errors`):
- `source`: `gmail`, `google_calendar`, `outlook`, `microsoft_calendar`, `imap_ovh`
- `event_type`: `mail_received`, `mail_sent`, `meeting_created`, `meeting_updated`, `meeting_cancelled`

When an insertion fails, the response includes an `errorDetails` array (`{event_id, message}` per failed event) in addition to the `errors` counter.

---

## Cloud mail/calendar collection

Collection runs on the Mycelora side: no computer needs to be on. Source types:

- **IMAP** (Gmail, Outlook, iCloud, OVH and others): mail, with an app password. Useful folders are read (trash, junk and drafts excluded), with a 7-day catch-up window.
- **Google Calendar**: calendar via OAuth 2.0, read-only scope.
- **CalDAV**: calendar.

Each account is a separate source, with its own sync status and error counter. All active sources are processed every 2 hours. Secrets are stored in a secrets vault, never in clear text.

---

## Reflexes (impact, thread state, contradiction)

**Impact reflex.** Before a structuring command-line action (schema change, mass deletion or update, production operation), the plugin refuses the first time and shows a report (who reads and writes the targeted object, or the scope of the production operation). The same action, replayed as is, goes through: the refusal does not repeat for the same object in the same thread. Limited to shell commands; other tools are only noted, without blocking.

**Thread state.** The plugin keeps a short state of the thread (objective, scope in progress, decided, ruled out, open, corrections), regenerated at regular intervals. It is visible in the dashboard, **Réflexes** tab, **Fils en cours** block.

**Contradiction reflex.** When a reply contradicts a decision made elsewhere (another project, an earlier thread), an alert appears in the conversation's recall and in the dashboard, Réflexes tab, **Alertes** block.

**Acknowledging an alert**, two equivalent paths:
- In conversation: ask Claude to acknowledge it; it uses `mycelora_ack_alerte` with the short identifier given in the alert text and a verdict, useful or noise.
- In the dashboard: Réflexes tab, Alertes block, buttons **Utile** / **Bruit**.

Both mark the alert, never delete it. The verdict is a supplementary signal; the user decides. It feeds the reliability counters of the same tab (**Compteurs** block, dashboard only).

None of these reflexes asks the user to paste a key or token: the plugin's hooks authenticate automatically.

---

## Memory hygiene

**Automatic deduplication.** Every insertion path checks for duplicates before inserting, by vector similarity: at 0.90 or above the new atom is skipped (the longest is kept); between 0.80 and 0.90 a classification decides between duplicate, supersession and distinct.

**Temporal supersession.** When an atom makes a previous one obsolete ("problem X" then "problem X resolved"), follow this convention: `search_atoms`, then `update_atom(active:false)` on the old one, then `create_connection(type:"précède")`. Similarity alone detects supersession poorly (opposite vocabulary scores low); the garbage collector is only a safety net.

**garbage_collect.** Runs automatically each week and can be called directly. It handles insight lifecycle, archiving of obsolete items and deduplication (0.95 and above merged automatically, 0.85 to 0.95 reported), and consolidates orphan atoms per space.

**health_check.** Runs automatically each day. It generates missing embeddings, reconnects orphans and purges obsolete connections. Manual call: `mycelora_health_check(repair:true)`.

---

## Error handling

1. A `mycelora_*` call fails: retry once. If it persists, check that the channel (plugin or connector, see install.md) is active and authenticated.
2. Still unavailable: tell the user "Memory access is unavailable. I'm continuing without it, thread not saved."
3. Never ignore a write failure (handover, memory, atom): always warn the user.
4. Closing failed: copy the handover and codex into the chat for manual saving.

---

## Architecture

- **Plugin**: skills and automatic hooks, distributed through the Claude directory.
- **Connector**: remote MCP server `https://api.mycelora.ai/functions/v1/mycelora-mcp` (OAuth or API key `mk_live_...`).
- **Dashboard**: https://mycelora.ai
- **Storage**: vector database with semantic search.
