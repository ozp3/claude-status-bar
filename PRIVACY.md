# Privacy

Claude Status Bar collects no data and has no servers. It runs entirely on your Mac.

It makes two kinds of network call, both to third parties, never to the developer.

**1. Update check** — a once-a-day request to GitHub's public API for the latest release tag, used only to show "Update available" in the menu.

**2. Usage** — a request to Anthropic's `/api/oauth/usage` endpoint, the same one the Claude UI uses, to read your plan's rate-limit utilization. This is what fills the **Usage** section of the dropdown. *(This fork only — upstream has no usage feature and makes only call #1.)*

- It sends your Claude Code OAuth token to Anthropic so they can identify your account. Nothing else is sent: no prompts, no files, no project paths, no conversation content.
- The token is read at request time from `CLAUDE_CODE_OAUTH_TOKEN`, `~/.claude/.credentials.json`, or your Keychain — the same credentials Claude Code itself uses. It is never copied elsewhere, cached to disk, or logged.
- Requests fire only when you press the refresh button in the dropdown's Usage header (at most one per 30 seconds). Nothing else — not launching the app, not opening the dropdown, no background timer. Turning off **Show usage** hides the section (and its button) entirely.
- Anthropic sees these requests, as they do every Claude Code request. The developer never does.
- The most recent utilization numbers (percentages and reset times, nothing else) are stored locally in the app's preferences so they can still be shown when a fetch fails. Signing out of Claude Code clears them.
- A small local log of usage-fetch attempts (timestamps, trigger, HTTP outcome, durations — no account data) is kept at `~/.claude/statusbar/usage.log` (capped at 128KB) to diagnose rate-limit behavior. It never leaves your machine.

---
Back to the [README](README.md).
