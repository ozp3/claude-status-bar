# Privacy

Claude Status Bar collects no data and has no servers. It runs entirely on your Mac.

It makes two kinds of network call, both to third parties, never to the developer.

**1. Update check** — a once-a-day request to GitHub's public API for the latest release tag, used only to show "Update available" in the menu.

**2. Usage** — a request to Anthropic's `/api/oauth/usage` endpoint, the same one the Claude UI uses, to read your plan's rate-limit utilization. This is what fills the **Usage** section of the dropdown. *(This fork only — upstream has no usage feature and makes only call #1.)*

- It sends your Claude Code OAuth token to Anthropic so they can identify your account. Nothing else is sent: no prompts, no files, no project paths, no conversation content.
- The token is read at request time from `CLAUDE_CODE_OAUTH_TOKEN`, `~/.claude/.credentials.json`, or your Keychain — the same credentials Claude Code itself uses. It is never copied elsewhere, cached to disk, or logged.
- Requests fire when the app launches and when you open the dropdown (at most one per 30 seconds), not on a background timer. Turning off **Show usage** in the menu stops them entirely.
- Anthropic sees these requests, as they do every Claude Code request. The developer never does.

---
Back to the [README](README.md).
