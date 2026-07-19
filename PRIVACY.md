# Privacy

Claude Status Bar collects no data and has no servers. It runs entirely on your Mac.

It makes two kinds of network call, both to third parties, never to the developer.

**1. Update check** — a once-a-day request to GitHub's public API for the latest release tag, used only to show "Update available" in the menu.

**2. Usage** — a request to Anthropic's `/api/oauth/usage` endpoint, the same one the Claude UI uses, to read your plan's rate-limit utilization. This is what fills the **Usage** section of the dropdown. *(This fork only — upstream has no usage feature and makes only call #1.)*

- It sends your Claude Code OAuth token to Anthropic so they can identify your account. Nothing else is sent: no prompts, no files, no project paths, no conversation content.
- With **Sign in with Claude** (recommended), the app performs a standard OAuth sign-in in your browser against the same public client Claude Code uses, and stores its OWN token pair in `~/.claude/statusbar/oauth.json` (0600). It refreshes that token itself (a request to Anthropic's token endpoint, only when you press ⟳ with an expired token, or during sign-in). Sign out from the menu deletes the file.
- Without signing in, the token is read at request time from `CLAUDE_CODE_OAUTH_TOKEN`, an optional `~/.claude/statusbar/token` file, `~/.claude/.credentials.json`, or your Keychain — the same credentials Claude Code itself uses. Borrowed tokens are never copied elsewhere or logged.
- Requests fire only when you press the refresh button in the dropdown's Usage header (at most one per 30 seconds). Nothing else — not launching the app, not opening the dropdown, no background timer. Turning off **Show usage** hides the section (and its button) entirely.
- Anthropic sees these requests, as they do every Claude Code request. The developer never does.
- The most recent utilization numbers (percentages and reset times, nothing else) are stored locally in the app's preferences so they can still be shown when a fetch fails. Signing out of Claude Code clears them.
- A small local log of usage-fetch attempts (timestamps, trigger, HTTP outcome, durations — no account data) is kept at `~/.claude/statusbar/usage.log` (capped at 128KB) to diagnose rate-limit behavior. It never leaves your machine.
- Two more local files, written on each successful fetch and never read back over the network: `usage-latest.json` (the current percentages, for your own scripts/status bars) and `usage-history.jsonl` (past percentages, capped ~1000 entries, for the ~24h change chips). Both live in `~/.claude/statusbar/` and contain only labels, percentages, and reset times.

---
Back to the [README](README.md).
