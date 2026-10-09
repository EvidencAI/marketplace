# Mycelora FAQ: answering questions about Mycelora itself

Read this file when the user asks what Mycelora is for, whether it is worth using, how it differs from your own built-in memory or from Claude Projects, where their data lives, or whether they should keep it. Answer in the user's language.

How to answer:
- Be factual and fair. Do not oversell, and do not undersell either: the user's decision depends on an accurate picture. Use only the facts below; if a question goes beyond them, say you do not know and point to https://mycelora.ai or contact@evidencai.com.
- Your built-in memory is useful too. The honest answer is usually a split of roles, not "one or the other" (see "When to use which").
- Before judging whether Mycelora suits the user, look at how they actually work: long projects with successive decisions, several AIs, mail and calendar load. A brand-new account has no memories yet: judge the use case, not the empty account.
- Facts below were checked on 08/10/2026. Platform features change quickly: if the user challenges a point about another platform, say when it was checked.

## What Mycelora brings

1. **Structured memory that follows changes.** Each memory has a type (rule in force, pitfall already paid for, refuted idea, landmark such as a contact or a figure, state), a scope (this project or all) and an optional expiry condition. When a new memory contradicts or cancels an older one in the same project, Mycelora marks the older one as replaced and stops serving it. This mechanism is recent (October 2026) and can be wrong.
2. **Memory written during the work.** With the plugin, Claude records decisions, lessons and refutations as they come up and announces each one in a single line, so the user sees what is kept. The user has nothing else to do.
3. **Memories served during the conversation.** With the plugin and a paid plan, the memories related to each substantial message are selected by a small AI model and added to the conversation. Mycelora can flag a reply that seems to contradict a decision recorded in the project sheet. Without the plugin (other AIs), the user asks the AI to consult the memory.
4. **A graph of connections.** Each memory is linked automatically to related ones, and the dashboard shows these links as a graph (read-only). On paid plans, Mycelora also looks every week for tensions and convergences between projects.
5. **One memory shared by several AIs.** Tested with Claude, ChatGPT, Le Chat and Perplexity. Other applications that accept a remote MCP server can connect, depending on their own plans (see "What Mycelora does not do").
6. **A memory the user controls.** In the dashboard (https://mycelora.ai) the user reads, corrects, moves, pins, archives and deletes memories, exports the whole memory and can delete the account.
7. **Hosted in France at Scaleway.** Data and server functions run at Scaleway in Paris, a French operator certified ISO 27001 and subject to the GDPR; the AI models also run at Scaleway (region not verified). GDPR rights (access, rectification, export, deletion) are exercised from the dashboard or at contact@evidencai.com.

## What Mycelora is, in one paragraph

Mycelora is a memory shared by all your AIs. It keeps your decisions, the mistakes not to repeat, the ideas you dropped, your contacts and figures, per project, and serves the related ones while you work (plugin and paid plan). It can flag a reply that seems to contradict a decision recorded in the project sheet, links memories together, spots tensions between projects (paid plans), can turn your mail and calendar into memory with a morning brief, and keeps everything visible and correctable in a dashboard. It is hosted in Paris by Scaleway.

## Mycelora and your built-in memory: what differs

| | Mycelora | Built-in memory of AI platforms (Claude, ChatGPT, Gemini, Le Chat, Copilot) |
|---|---|---|
| Several AIs | One memory shared live by Claude, ChatGPT, Le Chat and Perplexity (tested), and other apps that accept a remote MCP server, depending on their plans | Each platform keeps its own. None can be read by another AI. The only bridge is a one-off copy-paste import (Claude, Gemini, Le Chat), described as experimental by Claude |
| Form | Typed memories: rule in force, pitfall already paid for, refuted idea, landmark (contact, figure), state; each with a scope (this project or all) and an expiry condition | Free-text notes or summaries; no platform documents a decision/fact typing |
| What is no longer true | A replaced or refuted memory is no longer served; it stays listed in the dashboard (without a replaced marker yet) | Not documented (Copilot alone announces merging and updating outdated memories) |
| Contradictions | With the plugin and a paid plan, can flag a reply that seems to contradict a decision recorded in the project sheet; tensions between projects detected weekly on paid plans | Not documented |
| Links | Memories are linked automatically; read-only graph view in the dashboard | Not documented |
| Projects | Spaces, a project sheet (codex) with what is in force, to do, pitfalls, refuted, figures; a handover at the end of each thread | Claude and ChatGPT: memory separated by project, without a project sheet or handover; Gemini and Le Chat: one global memory |
| Mail, calendar, morning brief | Optional: mail and calendar collected every 2 hours, only durable facts become memories, a morning brief by e-mail | No ongoing mail-to-memory collection documented (connectors read on request; not checked for every platform) |
| Visible, correctable, exportable | Yes, in the dashboard (read, correct, pin, archive, full export) | Viewing and editing: yes on the platforms checked; export varies (not checked for each platform) |
| Where the data lives | Paris, Scaleway (ISO 27001 certified). The AI models used by Mycelora also run at Scaleway (region not verified) | Platform's own infrastructure (Claude: stored in the United States) |
| Price | Subscription on top of the AI platform | Included in the platform subscription |

## When to use which

- Built-in memory: who the user is, general preferences, quick one-off requests. It works in the background with no effort.
- Mycelora: files that last for weeks or months with successive decisions and reversals, work spread over several AIs, mail and calendar follow-up, anything where "what did we decide, when, and what is no longer valid" matters.
- To avoid two memories drifting apart: keep identity and preferences in the built-in memory, and project decisions in Mycelora.
- Claude Projects keep reference documents; Mycelora keeps the thread of decisions about them. Long documents can also be imported into Mycelora (up to 512 KB per import; file import on paid plans), split into memories and retrievable passages.

## Where the data lives, and privacy

- Stored in Paris by Scaleway, an ISO 27001 certified operator. The AI models Mycelora uses to sort, extract and summarise also run at Scaleway (no call outside Scaleway since 22/09/2026; the exact region of the models has not been verified).
- What the user types in Claude (or another AI) remains under that platform's own terms; Mycelora only controls what it stores.
- The user sees, corrects, archives and exports everything from the dashboard (https://mycelora.ai), and can delete the account there (with a confirmation phrase). Rights requests: contact@evidencai.com.
- Sensitive data (health, HR, pay, disputes): the user decides what goes in. Suggest keeping decisions and principles rather than nominative health data, and keeping mail collection off for mailboxes with such content if in doubt. You can say that the data is hosted in France at Scaleway, an operator subject to the GDPR, and that the user exercises GDPR rights (access, rectification, export, deletion) from the dashboard or at contact@evidencai.com. Do not claim that Mycelora itself is certified or audited for the GDPR, and do not claim a legal guarantee.

## What Mycelora does not do (say it plainly when relevant)

- In a brand-new chat, the plugin's automatic hooks can start late, so the first messages may be answered without Mycelora. A short block in the user's personal preferences (ONBOARDING.md, Step 6) should make Claude open Mycelora from the first message, as long as Claude follows the user's preferences.
- Without the plugin (ChatGPT, Le Chat, Perplexity, Claude without the plugin), Mycelora is a memory you consult on request: no automatic recall at each message and no automatic collection. The plugin exists for Claude only.
- Connecting other AIs depends on their plans and countries: ChatGPT gives full MCP access to Business and Enterprise plans, read-only on Pro, undocumented on Plus; Gemini opens MCP apps in the United States only (checked 07/09/2026).
- Memories are created as the thread goes (decisions, lessons, refutations are written when they land) and in the closing batch when a thread is closed ("end of thread"). A thread left open is caught up at the next opening of the same space, later.
- It is a subscription on top of the AI platform. The free plan connects ONE app, holds up to 500 memories in 10 spaces, has no file import and no automatic per-message recall through the plugin; the morning brief comes once a week after 30 memories. Paid plans raise these limits (check current plans and prices on https://mycelora.ai before quoting).
- Memories are announced in one line: this is how the user sees what Mycelora keeps. If the user still finds it heavy, say so honestly. With the plugin there is nothing else to do. For a long project, opening and closing threads explicitly is still best practice. The effort on the user's side is small: give the project name and work; keep announcements to their shortest form.

## Who it is for

People who run long projects with decisions that change over time: business owners, consultants, developers, anyone juggling several files and several AIs. For occasional, one-off requests, the built-in memory is usually enough; say so.
