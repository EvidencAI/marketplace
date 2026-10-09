---
name: mycelora
description: >
  Persistent project memory shared across AIs (Mycelora). Use it at the first message of any
  conversation about the user's projects or ongoing work, before answering from your built-in memory,
  and whenever the user asks what was decided, where something stands, what happened before, or to
  remember or recall something: "où en est", "on avait décidé quoi", "rappelle-moi", "souviens-toi",
  "retiens que", "cherche dans ma mémoire", "what did we decide", "where are we on", "remind me",
  "remember that". Also for opening or closing a thread ("mycelora in/out", "fin de fil"), the morning
  brief ("brief matinal"), tensions between projects ("analyse les tensions"), the user's spaces ("mes
  espaces", "my spaces"), any reference to persistent memory, and questions about Mycelora itself:
  "à quoi sert Mycelora", "what is Mycelora for", "faut-il garder Mycelora", "is Mycelora worth it",
  "Mycelora ou ta mémoire", "where is my data".
---

# Mycelora — Contextual and reflective memory

Knowledge graph: **atoms** (6 types), **spaces** (projects), **profile** (principles + portrait), **neuron** (cross-insights).

## What Mycelora brings

- Typed memories that follow changes: a memory contradicted by a newer one in the same project is marked replaced and no longer served (recent mechanism, can be wrong).
- Written during the work: you record decisions as they come up and announce each one in one line, so the user sees what is kept.
- With the plugin and a paid plan, related memories are served at each substantial message, and a reply that seems to contradict a recorded decision can be flagged.
- One memory shared by several AIs (Claude, ChatGPT, Le Chat, Perplexity tested), visible, correctable and exportable by the user in the dashboard.
- Hosted at Scaleway in Paris, an operator subject to the GDPR.

Before judging whether Mycelora is useful to the user, read **FAQ.md**.

## QUICK REFERENCE

| Item | Value |
|------|--------|
| Dashboard | https://mycelora.ai |
| Plugin | Skills plus automatic hooks, nothing to configure. Active in any session where it is installed. |
| Tools | The `mycelora_*` tools come from the connector bundled with the plugin ("Mycelora OAuth" on claude.ai), or from a connector added by hand when the plugin is not installed. Their prefix varies with the connector name (`mcp__Mycelora_OAuth__`, `mcp__Mycelora__`...). |

- Before the first call to a Mycelora tool, load its definition (tool search) and read its schema: never guess a field name. `quick_boot` does not exist: never call it.
- `userId`: omit it in all calls. The server resolves the identity from the connection and ignores any value sent.
- Associated files (same folder): ONBOARDING.md, REFERENCE.md, FAQ.md.
- Personal preferences block: the plugin's automatic hooks can start late in a brand-new chat, so the user's first message may arrive without them. The most dependable way we know to have Mycelora opened from the first message is a short block in the user's Claude personal preferences (ONBOARDING.md, Step 6, text in English and French). Offer it once: at onboarding, when the user says Mycelora did not start by itself, or when you opened the thread late. Never paste it for them and never add project state to it.
- Questions about Mycelora itself (what it is for, how it differs from your built-in memory or from Claude Projects, where the data lives, whether to keep it): read **FAQ.md** before answering, and answer from it.

---

## AFTER A CONTEXT COMPACTION

When a conversation resumes from a summary ("continued from a previous conversation"), the context is mostly lost. Do not rely on the summary alone:
1. Detect the active space in the summary.
2. `mycelora_session_start(sessionId:"resume-YYYY-MM-DD", spaceId:"[space]")`; use the identifier the server returns.
3. `mycelora_read_memory(spaceId:"[space]", type:"all")` (returns the codex and the last 5 handovers in full).
4. Reread this skill, cross the summary with the memory, then say: "I'm resuming after compaction. Here is what I found: [summary]. Shall we continue?"

If the user asks to continue without a recap, still call `session_start`, then carry on. If the space cannot be identified, call `list_spaces` and ask.

---

## OPENING PROTOCOL

Two modes.

**Explicit** (default when the user asks): "start mycelora", "open a thread", "ouvre un fil", "mycelora in", "session start", "launch Mycelora", "lance Mycelora". Steps 1 and 2 below, with the welcome block.

**Silent** (default otherwise): when the local hook injects an instruction starting with `[Mycelora] This thread is not open yet.`, or at the first real message of a conversation when no recall has arrived and no thread is open. Follow the hook's instruction and open the thread without a welcome block and without asking anything (if the user's own preferences ask you to ask for the workspace when it is unclear, do so):
1. `mycelora_session_start` with a new `sessionId` and, as `spaceId`, the workspace that best matches the message (a partial name is accepted; if you used one, call it once more with the space uuid it returns, so that recall targets that workspace). If the message does not clearly belong to a workspace, omit `spaceId`: the call returns the list of workspaces, and you open with `spaceId` only once a workspace is clear.
2. Use the thread identifier and the space uuid the server returns in all later calls (Step 1).
3. Tell the user in one line, in their language, which workspace you opened (or that none is chosen yet) and that one word is enough to change it.

The instruction does not apply to a scheduled or automated run (see § Scheduled tasks). If you cannot see a Mycelora tool, search for it (tool search) before concluding anything; if it really does not exist, tell the user in one line that the Mycelora connector is not connected.

### Step 1: Boot
Call `mycelora_session_start(sessionId:"cowork-YYYY-MM-DD-topic")`, adding `spaceId` if the user named a space. A partial or accent-free space name is enough: no prior `list_spaces` call. When the name was not exact, the opening block carries a line `Space: <full name> (id <uuid>)`: take that uuid for all later calls (other tools accept only the uuid or the exact name). If the name is ambiguous, the block lists the candidates and the thread opens without a space; call again with the full name.

**The thread identifier to use is the one the server returns, not the one you sent.** The server timestamps it at local time and announces it on the `Fil : ...` line at the top of the opening block. Do not compute or guess it: reread that line and use that identifier in ALL later calls, up to the closing. It is the key that attaches memories to the thread; two threads with the same identifier would mix their memory.

The block also returns the current date, time and weekday in the user's time zone (read them, never recompute a weekday), the space instructions, the profile, the active spaces, the last handover and the space codex. A long codex comes as a summary: read one topic in full with `mycelora_read_memory(type:"codex", sujets:["<title>"])` (10 titles per call at most).

If the profile is empty or the call returns "user not found", read **ONBOARDING.md** and follow it.

The opening brief may contain a line `[jeton-hook-session ...]`. It is a technical token read by the local hooks: never display it, copy it or quote it.

### Step 2: Welcome block (explicit mode only)
Use the time of day given by the opening block (`Current date and time: ...`). Always present:

```
---
Mycelora — [Greeting according to the time]

Active spaces:
  [Space 1] — [DD/MM] · [N1] atoms
  [Space 2] — [DD/MM] · [N2] atoms

Commands: "open [space]" · "morning brief" · "search [topic]" · "end of thread"

Dashboard : https://mycelora.ai
---
Which space are we working on?
```

The welcome block, Dashboard link included, belongs to the explicit opening; a silent opening does not show it. If the space was unknown at step 1, wait for the answer, then call `session_start(sessionId:<identifier returned at step 1>, spaceId:X)`: the server attaches it to the thread already open, without creating a second one. `list_spaces` is only for showing the list to the user.

### Unclosed thread reported at opening
If the opening block has a section « Unclosed thread (…) », a previous thread of the same space was left open for more than 6 hours. Before answering on the substance:
1. Read it: `mycelora_read_memory(type:"fil", sessionId:"<orphan thread>")`.
2. Close it like a normal thread: `mycelora_session_end(sessionId:"<orphan thread>", clotureDifferee:true, ...)`; atoms are not required.
3. Tell the user in one sentence. For a long project, closing a thread with "end of thread" is still best practice.

Use the orphan's identifier only for these two calls. Other lines of the section (« unclosed », « no exchange, abandoned ») are mentions: nothing to do.

### Switching workspace during a thread
When the subject moves to another workspace, call `mycelora_session_start` a second time with the thread identifier the server returned and the NEW `spaceId` (the uuid): a `session_start` without `spaceId` switches nothing. Announce it in one line, without asking. From then on, each atom carries the `spaceId` of its own subject.

---

## CLOSING PROTOCOL

Triggers: "end of thread", "fin de fil", "memorize", "mémorise", "we're closing", "on ferme", "session end", "mycelora out".

Order: codex drafted (not sent), then closing atoms sent through `session_end_atoms`, then `session_end`, which carries the codex.

1. **workSummary**: 8 lines at most, "where we stopped and why". The detail goes in the structured lists.
2. **Closing atoms**: before the handover, with the same `sessionId`, write the thread's memories in ONE call: `mycelora_session_end_atoms(sessionId:<identifier returned at opening>, atomes:[...])`, 1 to 20 entries. Each has `type` and `contenu`, plus `portee` (mandatory for `regle` and `refute`, otherwise refused) and optionally `perime_si`. The batch refuses `remplace`: to replace a memory that became false, use `create_atom_manual` one at a time. Types and criteria: see § Atoms. If the call is forgotten, the closing is accepted but marked INCOMPLETE and the response returns the `sessionId`: call `session_end_atoms` again right away. If the thread truly has nothing to retain, say so in the `sansAtomes` field of `session_end`, with the reason.
   **Safety reviewer.** Some clients run an automatic safety reviewer that reads tool inputs before they run. It can mistake a memory that *recounts* a sensitive action already done (a merge, a deletion or change in production, a deployment, a remote command) for the action itself, and refuse the write. This applies to every memory write, in the thread (`create_atom_manual`) and at closing. When a batch plainly narrates such an action, or after a first refusal, ask the user one line in their language ("Record these N memories? YES/NO") and, once they agree, send the same content unchanged. If they decline, do not write those memories and say so. Never reword a memory to get past the reviewer. In a scheduled task there is nobody to ask: write the atom as is; if it is refused, report the refusal in the task output.
3. **Codex**: draft the space's up-to-date codex now (do not send it yet; step 4 carries it in `session_end`), BEFORE the closing call. It is an update, not a rewrite: start from the existing codex, apply the thread's delta (what happened, was settled, refuted, done), keep every line that is neither contradicted nor replaced, with its date and wording. Two forms exist, see § Codex.
4. **Handover**: first load the definition of `mycelora_session_end` and read its schema (never guess a field name). Then call `mycelora_session_end(spaceId:<the thread's space>, workSummary, decisions, pendingTasks, refutations, pieges, pointeurs, correctionsUtilisateur, nonVerifie, codex or sujets/enBref, retraits if lines are removed)`.

   **`workSummary` is required and cannot be empty**: without it the server refuses the closing and writes nothing, so you can simply call again. A field that is not in the schema is ignored, and the response names it (`champsIgnores`).

   **`spaceId` is mandatory at closing**, even if the thread was opened with it: without it the handover has no space and the codex is not updated. Pass the uuid returned at opening.

   Provide both lists, always. `decisions` = facts settled, with their reason. `pendingTasks` = what remains actionable, next action first. One of the two may be empty, not both. Write complete sentences: they are reinjected as is at the next opening. With both lists and a `workSummary` over 300 characters, the server makes no model call and the closing is fast.

   **Five structured fields are required on the client path** (a `workSummary` of at least 300 characters and both lists, sent in the same call): the server refuses the closing if any of the five is absent or empty. Without a codex, a shorter summary or a missing list sends the closing down a model-written handover. With a codex (`codex` or `sujets`/`enBref`), the server instead refuses the whole closing and NOTHING WAS WRITTEN: call `mycelora_session_end` again with everything. So always send everything in one call:
   - `refutations`: what was tried or asserted then found false, and why.
   - `pieges`: what must not be rediscovered (treacherous behaviors, tool limits).
   - `pointeurs`: paths, scripts, identifiers, commands useful to resume.
   - `correctionsUtilisateur`: what the user corrected in your assertions, quoted.
   - `nonVerifie`: what you assert without proof.

   An empty list is refused: if there is nothing to put, the justification is the entry (`["no refutation: read-only thread"]`). These fields come back at the next opening, and refutations and traps feed the codex.
5. **Verify the response.** `context_snapshot.source_listes` must be `client`. The `codex` block must carry `source:"client", accepte:true`. If the codex was refused, tell the user the `raisons`, fix the codex accordingly and resubmit through `mycelora_write_memory(type:"codex", ...)`. Never re-run `session_end` to retry: the handover is already written and the server returns it unchanged (`rejeu:true`). Exception: any error saying NOTHING WAS WRITTEN (e.g. « Topics refused », « codex and sujets/enBref are mutually exclusive », a missing `workSummary`, an incomplete closing): fix and call `session_end` again. On other failures see REFERENCE.md § Error handling.
6. **Confirm**: "Thread closed. Handover (XXX words) and codex updated for [space]." and say whether the codex was accepted first time or resubmitted.

**Thread that touched several workspaces.** One `session_end_atoms` per workspace (with that workspace's `spaceId`). ONE `session_end` only, in the main workspace: a second one is a replay without effect, so never one `session_end` per workspace. The handover feeds only on the atoms of the workspace passed to `session_end`. The codex of the main workspace goes in `session_end`; the codex of each other workspace touched goes through `mycelora_write_memory(type:"codex", spaceId:<that workspace>)`.

**Without an explicit closing.** Without an explicit closing, the memories and codex lines already written stay. The thread handover is written later, when a new thread is opened in the same space (the opening block flags the unclosed thread). "end of thread" remains the richest closing and the best practice for a long project.

### Codex

**Language.** Write content (codex, handover lists, memories) in the user's language, structure keywords included (French: EN BREF / - En vigueur / - À faire / - Piège / - Réfuté / - Chiffre; English: IN SHORT / - In force / - To do / - Pitfall / - Refuted / - Figure, "(ref. x)"). Never translate existing content: an existing codex keeps its language.

A codex in **MAP form** has at least one line starting with `- En vigueur : `, `- À faire : `, `- Piège : `, `- Réfuté : ` or `- Chiffre : ` (French), or `- In force : `, `- To do : `, `- Pitfall : `, `- Refuted : ` or `- Figure : ` (English). Otherwise it is in the **old form**. Never convert a space on your own; only at the user's request (total rewrite).

**MAP codex (by topic)**
- Send only the topics touched by the thread: `sujets:["## <Title>\n- En vigueur : ... (DD/MM)\n..."]` (one or more complete « ## » blocks per string) and, if it changed, `enBref:"<text only, without the EN BREF : prefix>"` (one line). Use them on `session_end` instead of `codex`, or on `write_memory(type:"codex")` instead of `content`. They are mutually exclusive with `codex`/`content`.
- The server merges: a block replaces the whole topic (title compared without accent or case), a new title is added at the end, a lone title removes the topic (lines not taken up elsewhere go to `retraits`, 30 at most; unknown title or last topic = refusal). To rename or move lines, send two blocks in the same call (destination in full, source without the line or its lone title); a new title sent alone adds a topic and renames nothing.
- Read before sending: above 6,000 characters the opening serves only a summary (lines cut by « … », counters on a separate line, Pièges, Réfutés and Chiffres omitted). Before sending a topic, read it whole with `read_memory(spaceId, type:"codex", sujets:["<title>"])`. Reread the whole codex (`read_memory(type:"codex")`) only for a restructuring or a write through `codex`/`content`. A line or EN BREF ending with « … » is refused; never copy the counters line `[…]`; a title never carries counters.
- If your tool does not show `sujets`/`enBref` (cached schema) and requires `content` or `codex`, send the whole codex reread through `read_memory`.
- Form: `EN BREF : ` (state in one or two sentences, then the next deadline), then topics `## <Title>` (80 characters at most, unique up to accent and case, 60 topics at most). Within a topic, only typed lines, with the keywords in the user's language: French `EN BREF`, `- En vigueur : `, `- À faire : `, `- Piège : `, `- Réfuté : `, `- Chiffre : ` and `(réf. x)`; English `IN SHORT`, `- In force : `, `- To do : `, `- Pitfall : `, `- Refuted : `, `- Figure : ` and `(ref. x)`. No prose, sub-bullet or untyped line.
- Each line ends with its date, mandatory: `(03/10)`, `(12/08, 19/08)` or `(03/10, réf. 790115b2)`. Use only dates found in recent handovers or the current codex. A `réf.` is optional and verified: only the first 8 hexadecimal characters (or full uuid) of an existing memory or handover of the account, separated by comma, semicolon or space. A story, PR or file name goes in the line's text, never in `réf.`: the whole write is refused. Check a ref with `mycelora_read_memory(type:"ref", refs:["790115b2"])`. The current thread's handover does not exist before its closing and cannot be referenced.
- Update: a changed decision replaces its line; a finished task leaves « À faire »; the same thing never appears in two topics.
- Removal: a line of the old codex that is absent from the new one must be replaced by a new line of the same kind in the same topic, or declared in `retraits` (`{ligne: copied identically from the old codex, motif: 10 to 300 characters}`, 30 at most; a line altered even by a period or a capital is refused as a fictitious removal). A line moved unchanged to another topic passes. Rename or modify a topic, not both in the same write.
- The response field `remplacees` lists old lines that disappeared without a declared removal: reread it and, if a line should not have left, put it back by writing the topic again.
- Safeguards: 600 characters minimum; 100,000 characters maximum when it also grows (condensing always passes); a MAP space never goes back to the old form. Without a codex supplied at closing, nothing changes.

**Old form (spaces not yet converted)**
- Direct markdown, no frontmatter, fence, emoji or table.
- Head `EN BREF : ` (the space's state in one sentence, then the next dated deadline).
- Exactly five sections: `## Situation`, `## Décisions en vigueur`, `## Réfuté ou abandonné`, `## En attente`, `## Repères chiffrés`. Never a sixth.
- Lines `- DD/MM : ...`, only with dates cited by the thread, the handovers or the old codex (`(antérieur)` if unknown). Planned is not done: the future goes in En attente, where the leading date is that of the source that sets the task, never a guessed deadline (a deadline goes in the text). The same thing never appears in two sections.
- Budget: each space has a codex size budget (10,000 characters by default; the opening block says « WARNING: codex at L characters for a budget of B » when exceeded). A codex above budget that also grows is refused; a condensation always passes.
- To slim down, never delete silently: (a) merge several lines of the same theme into one dense line carrying all their dates; (b) remove a useless line by declaring it in `retraits` (`[{ligne:"- 16/04 : exact text of the old line", motif:"case closed"}]`, copied identically, motif 10 to 300 characters, 30 at most; a line altered even by a period or a capital is refused as a fictitious removal). Removed lines are archived and retrievable through `mycelora_search_atoms(inclure_clos:true)`. A date of the old codex that disappears undeclared counts as lost history.
- The server checks: minimum size 60% of the old codex (never more than 8,500 characters) and at least 60% of the older dates kept. If refused, the old codex stays protected and resubmitting is up to you through `mycelora_write_memory(type:"codex", content:..., retraits:...)`.

---

## ATOMS

### Writing atoms
Automatic extraction of atoms from exchanges is off. A thread's atoms are written by you, as the thread goes: when a decisive fact lands (`create_atom_manual`), and also at closing as a batch (step 2) if the thread is closed explicitly. What you do not write is not in memory.

When the user expresses a decision, a lesson paid for, a denial, a landmark or a state, you MUST create the atom with `create_atom_manual` right away and say: "I'm keeping that as [type]." Also update, right away, the line of the touched topic in the space's codex (`mycelora_write_memory(type:"codex", sujets:[...])`, after reading that topic with `read_memory(sujets)`; see § Codex), and keep the announcement short. Each atom carries the `spaceId` of its subject. If the atom recounts a sensitive action, the one-line agreement of § Closing protocol, step 2 (Safety reviewer) comes first; announce the atom once it is written. MUST, not MAY: "MAY" means it never happens. The user can correct the type or refuse.

**The criterion: will this memory be useful elsewhere or later?** Another model, in another thread, must be able to use it without having read this one. Each memory is a complete, self-contained sentence: "He said yes" is worthless, "Client X approved the €12k quote on 12/09/2026" is useful.

**The six types** (no other; an unknown type becomes `non_affecte`):

| type | the question it answers | natural scope |
|---|---|---|
| `regle` | how to act here: decision in force, method, preference, instruction | local or cross-cutting |
| `piege` | what fails and why, paid for at least once | cross-cutting |
| `refute` | what must no longer be believed | local or cross-cutting |
| `repere` | where, who, how much, how it is made: pointer, figure, contact, identifier | local |
| `etat` | where we stand, what is waiting | local |
| `non_affecte` | fits none of the above: to be sorted by hand | local |

`non_affecte` is not a fallback: a thread that mostly produces it has misclassified. `etat` is the only type that expires with age.

**`portee`**: `locale` (this space only) or `transverse` (all spaces). Mandatory for `regle` and `refute`, optional elsewhere. **`perime_si`** (optional): the condition that will make the memory false, in a few words.

Deserves an atom:
- "We're going with Next.js for the site" → `regle`, local
- "I learned that mails arrive twice if the job runs more often than hourly" → `piege`, cross-cutting
- "Actually the job runs every quarter hour, not at night" → `refute`, local
- "Alex is the CEO, he leaves the project at the end of April" → `repere`, local

Does not deserve one: "Yes, good idea"; "Pass me file X"; a transient technical discussion that the handover will cover.

**Size: 1,500 characters, hard ceiling.** A longer atom is cut at write time and the excess is lost. Write under the limit, or make two atoms. One fact per atom is also found better by recall.

### Replacing a memory
When a new atom makes a previous one obsolete: `search_atoms`, then `update_atom(active:false)` on the old one, then `create_connection(type:"précède")`.

### Memory hygiene
`triage_atoms`: when more than 30% of atoms are low confidence, or on request. `garbage_collect` and `health_check` also run automatically and can be called directly. Details in REFERENCE.md.

---

## HOOKS AND RECALL

The plugin's hooks provide automatic memory:
- At each user message: a contextual recall is injected before the reply.
- At the end of each exchange: the exchange is collected (`mycelora_log_exchange`) to build the report of abandoned threads, the thread state and the contradiction reflex.

Both ignore system notifications and messages too short to be useful.

A session may have no hooks (connector alone, plugin disabled), and even with hooks a recall may be missing (nothing relevant, filtered message, no `session_start` done yet; before the thread is open, the hook may instead inject one local instruction asking you to open it, see § Opening protocol). **Rule:** when a question concerns the user's context (projects, decisions, figures) and no recall has arrived, call `mycelora_search_atoms` or `mycelora_recall` yourself before answering.

Opening, atom creation, closing atoms and handover are identical with or without hooks. **Never call `mycelora_log_exchange` yourself**: it is the hooks' call, and the server refuses a connector batch when a hook batch exists for the thread.

### Reflexes

**Impact reflex** (shell commands only): before a structuring action (schema change, mass deletion or update, production operation), the call is refused once, with a report of who reads and writes the targeted object. Read the report, handle what it flags, then replay the same command as is: the refusal does not repeat for the same object in the same thread. Never work around it.

**Thread state**: a short state of the thread (objective, decided, ruled out, open, corrections) may appear in the recall when it has changed. It is context for you, not something to copy or comment to the user.

**Contradiction reflex**: when what was just said contradicts a decision in force elsewhere, a line `ALERTE (...)` with a short identifier may appear in the recall. Judge in one sentence whether it is relevant, acknowledge it with `mycelora_ack_alerte(id:"<identifier from the text>", verdict:"utile"|"bruit")`, and tell the user in one sentence. The verdict is a signal; the user decides. Acknowledging never erases the alert.

---

## NATURAL-LANGUAGE COMMANDS

| The user says | Action |
|-------------------|--------|
| (first real message, no thread open yet) | silent opening: session_start with the guessed space (without spaceId if unclear), one announcement line |
| start mycelora, open a thread | explicit opening: session_start, welcome block with the Dashboard link |
| mycelora in X, open X / ouvre X | session_start(spaceId:X) |
| mycelora out, end of thread / fin de fil | session_end_atoms(atomes) THEN session_end(...), codex written by you |
| remember that... / retiens que..., decision: / décision:, fact: / fait:, I learned / j'ai appris | create_atom_manual (type, + portee if regle or refute) |
| search Y / cherche Y, in my memory / dans ma mémoire | search_atoms(query:Y) |
| my spaces / mes espaces, my folders / mes dossiers | list_spaces |
| create folder X / crée dossier X | create_space(name:X) |
| analyze the tensions / analyse les tensions | cross_insights |
| morning brief / brief matinal | get_context(mode:"auto") |
| stats, memory status / état mémoire | get_stats |
| my profile / mon profil, who am I / qui suis-je | get_profile |
| show the memory of X / montre la mémoire de X | read_memory(spaceId:X, type:"codex") |
| inject this note / injecte cette note | extract_atoms (short note, 12,000 characters at most, every plan) or injecter_note (long note, Pro and Max) |
| diagnostic, health / santé | health_check |
| contact:, who is X / qui est X | upsert_contact / search_contacts |
| mycelora help | display this table in thematic blocks |

---

## MAIL AND CALENDAR COLLECTION

Collection runs on the Mycelora side, whether or not the user's computer is on. Only the user can connect a source, in the dashboard (Sources menu): no AI can do it for them, so point them to that page (ONBOARDING.md, step 4). Details: REFERENCE.md § Cloud mail/calendar collection. Never create a local scheduled task for it.

---

## SCHEDULED TASKS

A scheduled task that touches Mycelora (a check, a digest, a watch) is a probe, not a thread: it never calls `mycelora_session_start` or `mycelora_session_end`, and writes no handover and no codex. The instruction `[Mycelora] This thread is not open yet.` does not apply to it. Its only write is at most one atom, through `mycelora_create_atom_manual`, in a workspace named in the task's prompt, and only when there is something worth keeping. Put the essential first (symptom, figure, gap): atoms are cut at 1,500 characters.

## TONE

Mycelora is the app's name, use it freely. Say "I remember that..." or "in the X folder..." rather than detailing the mechanics. Do not mention technical channels, MCP tools or memory files unless asked or for debugging.
