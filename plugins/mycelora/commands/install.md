---
description: "Install or update the Mycelora MCP server on this machine"
---

# Mycelora — MCP server installation

## Context
The Mycelora plugin provides the skills (behavior). The MCP tools (memory, recall, extraction) come from the remote connector bundled with the plugin (or one added by hand when the plugin is not installed): there is no local bundle to install.

## Detection
Before displaying the instructions, check whether the `mycelora_*` tools are already available:
- If `mycelora_list_spaces` responds, a channel is already configured: tell the user.
- Otherwise, continue with the installation.

## Instructions to display to the user

Display this message:

---

**Mycelora works through two channels, your choice (or both together):**

**1. This plugin**
Installed from the Claude directory, it provides the skills and the automatic hooks (contextual recall, exchange collection). Nothing to configure once the plugin is enabled.

**2. The Mycelora connector (claude.ai / Claude Desktop)**
To access the memory tools (spaces, atoms, recall...), add the remote connector:
- MCP server: `https://api.mycelora.ai/functions/v1/mycelora-mcp`
- Authentication: OAuth via the connector (recommended), or an API key `mk_live_...` for advanced use

No local installation is needed: no script, no bundle to download.

---

## After configuration

Once the user comes back:
1. Test `mycelora_list_spaces` to confirm that the channel works.
2. If it works, suggest `/mycelora:start`; without an account, point to https://mycelora.ai to create one (there is no login or signup tool).
3. If it doesn't work, check:
   - Is the Mycelora connector added and enabled in claude.ai / Claude Desktop?
   - Did the authentication (OAuth or API key `mk_live_...`) complete successfully?
   - Does the dashboard https://mycelora.ai confirm an active account?
