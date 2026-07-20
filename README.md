<a href="https://github.com/ozp3/claude-status-bar/releases/latest/download/ClaudeStatusBar.dmg"><img src="assets/download.png" alt="Download ClaudeStatusBar.dmg for macOS" width="220"></a>
<br>
**Apple Silicon · ad-hoc signed** — see [Install](#install)

> ### This is a fork
> Forked from **[m1ckc3s/claude-status-bar](https://github.com/m1ckc3s/claude-status-bar)** (MIT, © Mick Cesanek), which is the original and the one most people want.
>
> It adds one thing: a **Usage** section in the dropdown showing your Claude plan's rate-limit utilization. Upstream deliberately excludes usage meters ([CONTRIBUTING](https://github.com/m1ckc3s/claude-status-bar/blob/main/CONTRIBUTING.md)), so this lives here rather than as a pull request.
>
> Unlike upstream, this fork is **Apple Silicon only** and **not notarized**. All credit for the app itself goes upstream; please report bugs in the status logic there, and only usage-related bugs here.

## Claude Status Bar

A tiny macOS menu bar app that shows **Claude Code's live status**: an animated Claude icon while it's thinking or running a tool, a yellow dot when it's awaiting your permission, and the elapsed time of the current turn. Lightweight, no window, no dock icon.

> Built so you can tab away during a long "thinking" stretch and still see, at a glance, whether Claude is working, waiting on you, or done.

<img width="600" height="479" alt="Screen Recording 2026-07-10 at 12 32 23 AM" src="https://github.com/user-attachments/assets/f5d77b7c-f41d-4276-b28f-e1cf655fd323" />

---

## What it shows

- **Thinking / working** — the icon animates, with a live `1m 1s` timer.
- **Running a tool** — a short label (`Editing`, `Reading`, `Running command`, `Using tool`, …).
- **Awaiting permission** — a paused yellow dot, in both the CLI and the Desktop app.
- **Idle / done** — rests on the Claude logo.

**Usage** *(this fork)* — the dropdown also lists your plan's rate-limit utilization: the 5-hour session window, the weekly cap, and any model-scoped weekly caps, each with a bar, a percentage, when it resets, and (once a day of history exists) a small ▲/▼ chip showing the change vs ~24h ago. The colour turns amber past 75% and red past 90%. When any limit is at 90%+ the menu bar icon gains a small red dot; opening the menu shows which one.

Each successful refresh also writes `~/.claude/statusbar/usage-latest.json` — point your tmux/sketchybar/script at that file for zero extra requests.

Fetched from Anthropic's `/api/oauth/usage` — the same endpoint the Claude UI reads — only when you press the ⟳ button in the Usage header (30s cooldown). Nothing else fires a request: not launch, not opening the menu, no background timer ([privacy details](PRIVACY.md)). Between presses the bars show the last snapshot, labelled with its age.

> [!TIP]
> **Recommended: Sign in with Claude.** The dropdown offers **Sign in with Claude…** — one browser approval, and the app holds its own token pair (stored in a 0600 file, self-refreshing). After that there are **no Keychain permission dialogs, ever**, and no dependence on Claude Code's login state. Without signing in, the app borrows Claude Code's stored credentials, which works but brings the occasional Keychain dialog (after full re-logins and app updates).

Everything is controlled from the menu:

- **Always show** *(this fork, on by default)*: keep the icon in the menu bar permanently, so usage is always a glance away. Turn it off to restore upstream's behavior (launches with Claude Code, quits when nothing's running).
- **Start at login** *(this fork, on by default)*: bring the app back automatically after a reboot (macOS 13+; shows up in System Settings → Login Items).
- **Show usage:** toggle the usage section (off = no usage requests at all).
- **Open usage log:** one click to the local fetch/rate-limit log.
- **Show timer:** toggle the elapsed `1m 1s` clock.
- **Thinking words:** rotate a playful verb (`Manifesting…`, `Percolating…`) in place of `Thinking…`, like Claude Code (on by default).
- **Animation style:**
  - **Claude Spark**, the web/chat "morph" spark
  - **Claude Code**, the terminal glyph spinner
  - **Crab Walking**, a pixel-art Clawd crab that scuttles while Claude works
- **Icon color:** **Orange** or **System** (adaptive black/white). All three styles follow this setting: in System mode Crab Walking renders as a shaded monochrome silhouette that matches the menu bar.
- **Version and update:** the menu shows your current version, with a one-click "Update available" when a newer release exists.

**Multi-session support.** When several Claude Code sessions run at once (multiple terminals, or a terminal plus the desktop app), the menu bar surfaces the highest-priority one: a session awaiting your permission is never hidden behind one that's thinking. The dropdown lists every live session. Precise per-tab focus is in progress: **[issue #19 →](https://github.com/m1ckc3s/claude-status-bar/issues/19)**.

## Where it works

| Surface | Tracked? |
|---|---|
| Claude Code CLI (terminal) | ✅ |
| Claude Code Desktop — **Code** tab | ✅ |
| Cursor (Claude Code extension) | ✅ |
| Claude Desktop — **Chat/Cowork** tab | ❌ |

## Install

### DMG

1. Download the latest `ClaudeStatusBar.dmg` from [Releases](../../releases).
2. Open it and drag **Claude Status Bar** into Applications.
3. **Right-click the app → Open → Open.** Double-clicking will fail the first time (see below).
4. On first launch it wires up the Claude Code hooks for you automatically.
5. Start a new Claude Code session, the icon appears whenever Claude Code is running.

> [!IMPORTANT]
> **"Apple could not verify..." on first open.** This build is ad-hoc signed, not notarized —
> notarizing requires a paid Apple Developer account. macOS quarantines anything downloaded
> from the internet, so Gatekeeper blocks it until you approve it once via **right-click → Open**
> (double-click gives you no "Open anyway" button; right-click does). After that it launches
> normally forever. Upstream's builds *are* notarized and open with a double-click.

> **Apple Silicon only.** This fork builds arm64 only; it will not run on Intel Macs.
> Upstream ships a universal binary.

### Updating

> [!IMPORTANT]
> **Updated mid-session?** Sessions already open won't show up until they do something (send a prompt) or you start a new `claude` session.

Download the latest DMG and drag it into Applications (choose **Replace**). That's it: it refreshes its own hooks the next time it starts up (on a version change it re-runs its installer automatically), so there's nothing to run by hand. Your next Claude Code session picks them up.

## Requirements

- macOS 12+ on **Apple Silicon** (this fork is arm64-only)
- [Claude Code](https://claude.com/claude-code) (CLI or the Desktop app), signed in — the usage
  section reads the same credentials Claude Code uses
- Node.js

## How it works

The app is stateless. Claude Code fires hooks as it works; the app polls those updates and aggregates them across every live session into a single icon, a permission dot if one needs you, animating if any session is working, resting when all are idle. By default it stays in the menu bar permanently (see **Always show**); toggled off, it launches itself when Claude Code opens and quits when nothing's running.

The installer merges its hooks into `~/.claude/settings.json` (backing it up first). Its network calls are a once-a-day GitHub release check and, for the usage section, a read of Anthropic's usage endpoint on the ⟳ button only ([details](PRIVACY.md)).

## Troubleshooting

Icon quitting right after you open it, not showing, or not moving in Cursor? See [Troubleshooting](TROUBLESHOOTING.md), most of it is expected behavior, not a bug.

## Uninstall

```bash
node "/Applications/ClaudeStatusBar.app/Contents/Resources/uninstall.js"   # removes only our hooks
```
Then drag the app to the Trash.

## Acknowledgements

Claude Status Bar was built and open-sourced by **[Mick Cesanek](https://github.com/m1ckc3s)** — the app, its design, and everything it does apart from the usage section are their work, and this fork exists only because the original is good enough to want one more thing from. Thanks also to everyone who contributed code, fixes, and ideas upstream.

**[See the upstream contributors →](ACKNOWLEDGEMENTS.md)**

## Trademark / Not Affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or sponsored by Anthropic.** "Claude" and the Claude spark logo are trademarks of Anthropic, used here nominatively. This project is MIT licensed, but that covers the source code only and conveys no rights to Anthropic's trademarks or brand.

This is a free side project; it is not monetized. For trademark concerns about **this fork**, open an issue here. For the original app, contact its author on X ([@mickces](https://x.com/mickces)).

## License

MIT
