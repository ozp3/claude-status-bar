# Privacy

Claude Status Bar collects no data and has no servers. It runs entirely on your Mac.

It makes two kinds of network call, both to third parties, never to the developer.

**1. Update check** — a once-a-day request to GitHub's public API for the latest release tag, used only to show "Update available" in the menu.

**2. Usage** — a request to Anthropic's `/api/oauth/usage` endpoint, the same one the Claude UI uses, to read your plan's rate-limit utilization. This is what fills the **Usage** section of the dropdown. *(This fork only — upstream has no usage feature and makes only call #1.)*

- It sends your Claude Code OAuth token to Anthropic so they can identify your account. Nothing else is sent: no prompts, no files, no project paths, no conversation content.
- The token is read at request time from `CLAUDE_CODE_OAUTH_TOKEN`, an optional `~/.claude/statusbar/token` file you create yourself (see the README tip), `~/.claude/.credentials.json`, or your Keychain — the same credentials Claude Code itself uses. The app never copies a token elsewhere, caches one to disk, or logs one.
- Requests fire only when you press the refresh button in the dropdown's Usage header (at most one per 30 seconds). Nothing else — not launching the app, not opening the dropdown, no background timer. Turning off **Show usage** hides the section (and its button) entirely.
- Anthropic sees these requests, as they do every Claude Code request. The developer never does.
- The most recent utilization numbers (percentages and reset times, nothing else) are stored locally in the app's preferences so they can still be shown when a fetch fails. Signing out of Claude Code clears them.
- A small local log of usage-fetch attempts (timestamps, trigger, HTTP outcome, durations — no account data) is kept at `~/.claude/statusbar/usage.log` (capped at 128KB) to diagnose rate-limit behavior. It never leaves your machine.
- Two more local files, written on each successful fetch and never read back over the network: `usage-latest.json` (the current percentages, for your own scripts/status bars) and `usage-history.jsonl` (past percentages, capped ~1000 entries, for the ~24h change chips). Both live in `~/.claude/statusbar/` and contain only labels, percentages, and reset times.

---
Back to the [README](README.md).
