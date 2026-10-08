# Mycelora — New user onboarding

This flow applies when `mycelora_session_start` returns an empty profile or a "user not found" error. Follow the steps in order.

---

## Welcome

Present Mycelora in 3 sentences at most:
"Mycelora is your persistent memory across your conversations with Claude. It remembers your decisions, projects and contacts, and gives you back the relevant context in each new thread. Everything is stored in your secure space."

---

## Step 1: Create the profile

Ask: "What would you like me to call you? And what are your working principles that I should always keep in mind?"

With the answer, call:
```
mycelora_update_profile(displayName:[first name or chosen name], principles:[array of strings], portrait:"To be completed as we talk")
```

---

## Step 2: Create the first space

Ask: "What project are you working on right now? I'll create your first folder."

Call: `mycelora_create_space(name:[project name])`

---

## Step 3: The 5 essential commands

Present:
- "open [space]" → load a project
- "remember that..." → store a piece of information
- "search [topic]" → dig through the memory
- "morning brief" → summary of the day (mails, appointments, insights)
- "end of thread" → save and close (optional: with the plugin the thread opens by itself and memories are written as you go; for a long project, opening and closing explicitly is still best practice)

---

## Step 4: Mail/calendar collection

Collection runs on the Mycelora side every 2 hours, whether or not the computer is on. There is nothing to schedule or leave running locally.

Explain: "Mycelora can read your mails and your calendar every two hours to keep track of your exchanges and commitments. The text of the mails is erased 7 days after sorting. Shall I show you where to connect one?"

If the user accepts, send them to the **Sources** menu of the dashboard (https://mycelora.ai). Only they can connect a source there, no AI can do it for them: mail via IMAP (Gmail, Outlook, iCloud, OVH, Free, Orange and others), Google calendar by consent, CalDAV calendars.

Password: for providers that offer one (Gmail, Outlook, iCloud), always an app password, never the account's main password; for the others (OVH, Free, Orange), the mailbox password.

---

## Step 5: Dashboard

"Your Mycelora dashboard is here: https://mycelora.ai
It lets you view your spaces, atoms, connections and the activity of your memory."

---

## End of onboarding

This is an explicit opening: present the standard welcome block (SKILL.md § Opening protocol, Step 2) with the Dashboard link, then:

"You're ready. Say 'open [your space]' to get started, or 'mycelora help' to see all the commands."
