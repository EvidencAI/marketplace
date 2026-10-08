# Mycelora

Persistent memory for Claude, across chat, Cowork and Claude Code.

Mycelora keeps what matters from your conversations (decisions, facts, open questions, pitfalls already met) in a knowledge graph organized by workspace. When you open a thread, Claude receives the context of that workspace: where things stand, the decisions in force, what was ruled out, what is still pending. At each message, Mycelora recalls the few memories relevant to what you are asking, so you stop re-explaining your projects.

Mycelora is a hosted service run by EvidencAI SAS (France). This plugin connects Claude to it. You need a Mycelora account: sign up at [mycelora.ai](https://mycelora.ai).

## What the plugin contains

| Component | Role | Where it runs |
|---|---|---|
| Mycelora connector (`.mcp.json`) | Remote MCP server `https://api.mycelora.ai/functions/v1/mycelora-mcp`, signed in with OAuth. It provides the memory tools: open and close a thread, recall, search, write memories, manage workspaces | Chat, Cowork, Claude Code |
| Skill `mycelora` | Teaches Claude when to open a thread, how to use the recalled context and how to close a thread | Chat, Cowork, Claude Code |
| Commands `/mycelora:start` and `/mycelora:install` | Open a thread on a workspace, check the connection | Cowork, Claude Code (chat applies them as skills) |
| Hooks | Automatic recall and collection, described below | Wherever Claude runs plugin hooks (Claude Code, Cowork; depends on the surface) |

## Getting started

1. Install the plugin.
2. Connect the Mycelora connector from the plugin's Connectors tab (chat and Cowork) or when Claude Code asks you to sign in. You sign in to your Mycelora account; Claude never sees your password.
3. Start a thread with `/mycelora:start <workspace name>`, or simply ask Claude to open your Mycelora memory.

Where hooks do not run, or on the Mycelora Free plan, Claude calls the memory tools itself when the skill tells it to.

## What the plugin sends, and where

Everything goes to one destination: `https://api.mycelora.ai`, the Mycelora service, over HTTPS. Nothing is sent to any other party by the plugin.

The hooks only act once Claude has opened a Mycelora thread in the session: opening the thread returns a short-lived session token (24 hours, restricted to recall, collection and impact lookup), which the hooks read from the session transcript on your machine. Before that, they make no network call; the only thing `UserPromptSubmit` may do is inject one local instruction (see the table).

| Hook | When | What is sent |
|---|---|---|
| `UserPromptSubmit` | Each message you send (short or system messages are skipped locally). Before the thread is open, it may inject ONE local instruction asking Claude to open it (nothing is sent; disable it with `MYCELORA_OUVERTURE_AUTO=0`) | The message, truncated to 2,000 characters, with the workspace and thread identifiers, to fetch the relevant memories. The recalled memories are added to Claude's context |
| `Stop` | At the end of each Claude reply | Your last message and Claude's reply, sent in full (not truncated), with the workspace and thread identifiers, the technical name of the thread (its session label), the thread title if you named it, the identifiers of the memory batches recalled during the turn, and the local log of the impact checks of the turn (tool, object names, a fingerprint, timestamps, and whether Claude's reply contains a question mark). Mycelora keeps the exchange to write the summary of a thread left open, to track the state of the thread, and to warn when something contradicts a decision already recorded. Memories themselves are written by Claude, not extracted from the exchange. The raw exchanges are kept 90 days at most (automatic purge) and are no longer turned into memories |
| `PreToolUse` | Before a shell command (Bash, or Desktop Commander) that changes a database structure or deletes data without a filter | The names of the objects involved (for example a table name) and the workspace identifier, to check what depends on them. The command itself is not sent. Commands that touch infrastructure (ssh, rsync, container restart) are checked locally only, nothing is sent. The hook may ask Claude to confirm the action once |
| `PostToolUse` | After such a command, or after an edit to a server function file (`supabase/functions/<name>/index.ts`) | The same object names (or the function name) and the workspace identifier, to look up what depends on them. In a repository that holds a `supabase/` or `plugins/mycelora/` folder, it also adds a line to a local `.carte-perimee` file at the repository root to flag that the code map needs a refresh |

Local files: the hooks keep small working files in `/tmp`, readable only by you (mode 0600):
- `mycelora-hook-<thread>.json`: the thread cache, which holds the session token (valid 24 hours) and the workspace identifier;
- `mycelora-ack-*`, `mycelora-impact-*`, `mycelora-reflexes-*.jsonl`: impact-check state for the thread;
- `mycelora-hook-*-body|cfg|resp|stdin.*`, `mycelora-hook-pre-*`, `mycelora-hook-post-*`: request and response files of a single call, deleted when the hook ends;
- `/tmp/mycelora-hook.log`: a technical log (event, duration, status; no message content), trimmed past 1 MB.

The session token is passed to `curl` through a temporary configuration file, never on the command line.

To turn off the impact check: set `MYCELORA_REFLEXE_IMPACT=0` (in a repository that holds a `supabase/` or `plugins/mycelora/` folder, an empty `.mycelora-reflexes-off` file at its root also works). To turn off all hooks, disable the plugin.

Requirements: the hooks use `bash`, `python3`, `curl`, `shasum`, `awk` and `sed`, present by default on macOS and most Linux systems. If one is missing, the hooks stay silent and Claude falls back to calling the memory tools itself.

## Plans

The connector works on every Mycelora plan, within the limits of each plan. Automatic recall and collection by the hooks require a paid Mycelora plan or the Pro trial; on the Mycelora Free plan the hooks stay silent.

## Privacy and terms

- Privacy policy (in French): [mycelora.ai/legal/politique-confidentialite](https://mycelora.ai/legal/politique-confidentialite)
- Terms of service (in French): [mycelora.ai/legal/cgu](https://mycelora.ai/legal/cgu)
- Data protection requests: contact@evidencai.com
- Support: info@mycelora.ai

## License

The plugin files are released under the MIT License (see `LICENSE`). The Mycelora service is proprietary.
