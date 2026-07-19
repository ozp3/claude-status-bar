# Changelog

All notable changes to Claude Status Bar are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## [0.4.10] - 2026-07-19

### Changed
- **"Start at login" is its own toggle.** Login-item registration used to piggyback on "Always
  show"; the two are separate promises (staying up this boot vs coming back after the next one),
  so they're separate switches now. Existing installs inherit their previous effective state —
  nobody's login items change under them.

## [0.4.9] - 2026-07-19

Quality-of-life batch. Nothing here adds a request path: everything below runs off the cache,
local files, or the fetches the user already triggers with ⟳.

### Added
- **Menu bar warning dot** when any cached limit is ≥90% — a small red dot on the icon, cleared
  when a fresh fetch shows the limit back under threshold. Adaptive icon colors are preserved.
- **Notification at 90%**, piggybacked on user-triggered refreshes: crossing the threshold posts
  one macOS notification per limit per reset window. Toggle: "Alert at 90%" (on by default).
- **The "Token expired" note heals itself.** Opening the menu re-checks stored credentials
  locally (file + Keychain, zero network); after a `claude` login the note flips to
  "Token OK — press ⟳" without waiting for a press.
- **"Open usage log" menu item** — one click instead of tailing the file in a terminal.
- **`usage-latest.json`** written on every successful fetch, for tmux/sketchybar/scripts:
  consumers read the file, so integrations cost zero requests.
- **~24h change chips** in the rows ("▲16"): each successful fetch is recorded to a local
  history file (capped ~1000 entries), and rows show the change against the snapshot nearest
  24h back once one exists.

## [0.4.8] - 2026-07-19

### Fixed
- **The Keychain permission dialog can now be typed into.** Credential resolution used to run on
  the main thread from inside the ⟳ press — mid menu-tracking — so when macOS raised its
  permission dialog, both the frozen menu and the dialog fought over input and the password field
  took no keystrokes. Token loading now hops off the main thread first; the dialog activating
  closes the menu normally and accepts input. The refresh spinner also waits up to 60s so it
  doesn't give up while you type your password.

## [0.4.7] - 2026-07-19

### Changed
- **The ⟳ button is now the ONLY usage request path.** The once-per-launch warm fetch and the
  "Show usage" toggle-on fetch are gone too: nothing contacts the usage endpoint until the user
  presses refresh. With a truly empty cache (first run, or right after signing out) the first
  press answers "updated — reopen", since the menu can't grow rows while open.

## [0.4.6] - 2026-07-19

### Added
- **Refresh button feedback.** Pressing ⟳ swaps it for the native spinner while the request runs,
  then shows a short verdict ("updated", "rate limited · 24m", "token expired"). A press inside
  the 30s cooldown answers "try again in 12s" instead of silently doing nothing; a press during
  a 429 hold answers with the remaining hold time. Every suppressed press is also logged.

## [0.4.5] - 2026-07-19

### Changed
- **Usage refresh is now manual.** Opening the dropdown no longer fires a request — you may be
  there for a toggle, not the quota. The Usage header gained a ⟳ button, which is the only
  request path from the menu (same 30s cooldown). The once-per-launch warm fetch stays.
- Stale cached numbers now carry a plain age note ("Data 3h old — press ⟳") even when nothing
  is failing, since with manual refresh the bars can legitimately be hours old.

## [0.4.4] - 2026-07-19

### Fixed
- **Expired tokens are never sent.** Stored credentials carry an `expiresAt`; both sources (file
  and Keychain) are now expiry-checked, and when everything on disk is expired the app fires no
  request at all — it shows "Token expired — start a Claude Code session to refresh it" over the
  cached bars and recovers automatically when Claude Code stores a fresh token. Firing with a dead
  token wasn't just useless: the resulting 401 fed an auth-failure throttle that answered the very
  next request with a 60-minute 429 (the log has the receipts: 401 at 14:16:04, 60m penalty for
  the single request at 14:16:25).
- **A token that 401s is never retried** (revoked before its expiresAt, clock skew): the failing
  token's tail is remembered — across relaunches — and requests stay suppressed until a different
  token appears. A successful fetch clears the gate.
- Expired-token state no longer masquerades as "Not signed in", and no longer wipes the cached
  usage snapshot.

## [0.4.3] - 2026-07-19

### Added
- **Usage fetch log** at `~/.claude/statusbar/usage.log` (local only, 128KB cap, one `.old`
  generation): every fetch attempt with its trigger (launch/menu/toggle), outcome (HTTP status,
  duration, limit count, Retry-After on a 429), every suppression with its reason (cooldown /
  429 hold), and the hold/cache state restored at process start. Answers "when and under what
  circumstances did we get rate limited" without guesswork.

## [0.4.2] - 2026-07-19

### Added
- **Stale usage stays visible while rate-limited.** The last good numbers are persisted locally,
  so a process that starts under a 429 penalty (or any fetch failure) still shows the bars from
  the previous successful fetch, with the rate-limit note beneath them. When the data is more
  than 15 minutes old the note says so ("· data 3h old"). Signing out clears the snapshot.

## [0.4.1] - 2026-07-19

### Added
- **"Always show" toggle** (on by default): the icon stays in the menu bar permanently and the app
  registers as a login item, instead of launching with Claude Code and self-quitting when idle.
  With the usage section the icon is useful even with no session running. Toggling it off restores
  upstream's launch/quit lifecycle and removes the login item.

### Fixed
- **Quit now sticks.** The SessionStart hook used to revive the app on the next Claude Code event,
  making the menu-bar Quit effectively impossible. Quit now writes a marker the hook respects;
  launching the app any other way (login, Spotlight, Finder) clears it.
- **The 429 hold survives relaunches.** The endpoint's rate-limit penalty escalates when requests
  keep arriving (observed climbing 161s → 1671s → 60m), and every relaunch used to fire a blind
  launch fetch into it — so quit-and-reopen cycles kept extending the penalty. The hold deadline is
  now persisted and honoured from the first moment of a fresh process.
- The rate-limit note counts down live and clears itself; previously it showed the seconds frozen
  at the moment of the 429.
- Menu-open fetch cooldown raised 10s → 30s, for the same escalation reason.

## [0.4.0] - 2026-07-18

First release of this fork. Versions from 0.3.4 down are upstream's.

### Added
- **Usage section in the dropdown.** Shows the Claude plan's rate-limit utilization: the 5-hour
  session window, the weekly cap, and any model-scoped weekly caps, each as a labelled bar with a
  percentage and a relative reset time. Amber past 75%, red past 90%, or whenever the API flags the
  limit itself. Read from Anthropic's `/api/oauth/usage`, the endpoint the Claude UI uses.
- **"Show usage" toggle** in Options. Off means no usage requests are made at all.

### Notes
- Usage is fetched on launch and on menu open (max once per 10s), never on a background timer:
  the numbers are only read while the menu is up. A 429 is honoured for its full `Retry-After`.
- The OAuth token is re-read per request from `CLAUDE_CODE_OAUTH_TOKEN`, `~/.claude/.credentials.json`,
  or the Keychain, since Claude Code rotates it. It is never cached to disk or logged.
- The in-app update check now points at this fork's releases, not upstream's — otherwise it would
  offer upstream's DMG, which has no usage section, as an "update".

### Changed from upstream
- **Apple Silicon only.** The x86_64 slice needs Swift compatibility libs the standalone Command
  Line Tools don't ship; `build.sh` builds arm64 only.
- **Not notarized.** Builds are ad-hoc signed, so a downloaded copy needs one right-click > Open.

## [0.3.4] - 2026-07-09

### Added
- **Session rows show the git branch** next to the project name ("myrepo · fix-auth"), read straight from `.git/HEAD` (no `git` invocation), works for worktrees, shows a short SHA when detached, shows nothing outside a repo. Updates on session activity and on opening the menu, so a folder that becomes a repo mid-session (git init, first branch) is picked up live. Thanks to [@ethan0905](https://github.com/ethan0905) ([#37](https://github.com/m1ckc3s/claude-status-bar/pull/37)).
- **Same-named projects are told apart.** When two live sessions share a folder name (two clones or worktrees of one repo), rows qualify it with the parent folder: "work/myrepo" vs "tmp/myrepo". Hovering a row shows the full name, branch, and path.

### Fixed
- The dropdown timer now sits on the same text baseline as the session name instead of floating slightly high.
- Long session names keep constant letter spacing on every row; a name that does not fit truncates with an ellipsis instead of being subtly squished next to the timer.

## [0.3.3] - 2026-07-08

### Changed
- The working spinner in the dropdown is now the native macOS spinner. It is smoother and looks cleaner, especially in dark mode.
- Menu cleanup: Animation and Color are their own menu items now, instead of one combined Settings menu. Idle sessions hide after a fixed 15 minutes (the interval picker was removed).

### Removed
- The completion sound, and its toggle.

## [0.3.2] - 2026-07-02

### Added
- Thinking words: the menu bar now rotates through playful verbs while working, more like Claude Code. On by default; toggle it in the menu.

### Changed
- Condensed the settings into a single Settings menu.
- Completion sound now chimes only after turns longer than 5 minutes (was 1 minute).

### Known issues
- Upstream Claude Code bug: pressing Ctrl+C during the reasoning phase in the terminal can leave the icon stuck on a thinking word, since Claude Code emits no hook or transcript signal for that interrupt. Sending your next prompt clears it.

## [0.3.1] - 2026-06-28

### Fixed
- Idle sessions no longer vanish from the menu bar. The icon now follows the live session: it stays while Claude is running and clears when you close it.
- The session list never goes empty: there's always a session to click, or an "Open Claude" shortcut when only the desktop app is open.

### Changed
- Desktop conversations appear only once you work in them, so clicking through conversations no longer clutters the list. Terminal and editor sessions still show the moment they start.
- Menu polish: the session spinner matches the row text, a smaller timer, a tidier Options section, and a light-mode toggle you can actually see.

## [0.3.0] - 2026-06-26

### Added
- **Multi-session support.** The menu bar now tracks every running Claude Code session at once instead of one at a time. When several are active it surfaces the most important one in the bar (a session awaiting your permission outranks one that's working, which outranks idle) and lists them all in the dropdown.
- **Session dropdown.** Each running session gets its own row showing its project, a live status icon (a spinner while working, an amber dot when it needs your approval, a caret when resting), an elapsed timer, and a CLI or APP tag for where it's running.
- **Click a session to jump to it.** Clicking a desktop-app session brings the Claude app forward; clicking a terminal session brings its terminal app forward. Heads up: it raises the terminal app, not a specific window or tab, so if you have several terminal windows open it surfaces your most recent one, not necessarily the exact session you clicked. Precise per-tab focus is in progress: [issue #19](https://github.com/m1ckc3s/claude-status-bar/issues/19).
- **Hide idle sessions** after a delay you choose (5, 15, or 30 minutes, 1 hour, or never), so the list stays focused on what's active.
- **Intel Mac support.** The app now ships as a universal binary and runs natively on both Apple Silicon and Intel Macs.
- **Crab Walking adapts to the color theme.** In System mode the pixel-art crab now renders as a shaded monochrome silhouette that matches the menu bar; Orange mode keeps it full-color. Thanks to @florianheysen for the original implementation.

### Changed
- The menu is now organized around sessions: a Sessions list at the top, with Options, animation, and color settings below.

## [0.2.2] - 2026-06-25

### Fixed
- Fixed install for nvm/fnm users. The hook setup only looked for Node on the login shell's PATH, so the menu bar icon would show but never animate. It now checks the common Node locations and falls back to your interactive shell. Stuck installs heal on the next launch.

## [0.2.1] - 2026-06-25

### Fixed
- Edge case where closing the app (or the Claude desktop app) mid-animation left the menu bar stuck. On reopen it would still show the old "thinking" state with the timer climbing, because a force-quit fires no Stop hook. The status now resets to the idle resting icon when the owning session ends or resumes.
- The menu bar no longer parks on "Waiting for you" after a turn. Claude Code's CLI sends an idle notification ("Claude is waiting for your input") when a session sits idle, and the app was turning that into a persistent label. Now only permission notifications affect the icon, so it simply rests when idle.

## [0.2.0] - 2026-06-25

### Added
- **Awaiting-permission dot now works in the Claude desktop app**, not just the terminal CLI. Previously the yellow "awaiting permission" dot only appeared in the CLI, because the only signal we had (the `Notification` hook) never fires for permission prompts in the desktop app. The app now also listens to Claude Code's `PermissionRequest` hook, which fires the moment an approval dialog is shown in both the CLI and the desktop app, so the dot lights up the instant Claude is waiting on you to approve a tool.

## [0.1.0] - 2026-06-22

### Added
- **Crab Walking** animation style: a pixel-art Clawd crab that scuttles in the menu bar while Claude works. Pick it under Animation. It's always its orange pixel-art self (the Claude and Claude Code styles still follow the Orange/System color setting).
- Optional **completion sound**: a soft chime when a turn longer than a minute finishes. Off by default, toggle it under Options.
- **Version and update check** in the menu: shows your current version, plus a one-click "Update available" that opens the latest release when there's a newer one. The check is a once-a-day read of GitHub's public release tag; no data is collected and nothing is sent to the developer.
- Menu **section headers** (Options / Animation / Color) for easier navigation.

## [0.0.5] - 2026-06-22

### Fixed
- The app no longer quits while a session that was already running before you installed it is actively working. Such a session never fired its one-time `SessionStart` hook, so it wasn't being tracked, even though its other hooks fire normally. The status hooks now register the session on any activity, so any actively-working session keeps the icon alive. (Thanks to the bug report that pinned this down.)

## [0.0.4] - 2026-06-22

### Fixed
- The app now actually runs on macOS 12 (Monterey) and later, as the README states. Earlier builds were compiled without a pinned deployment target, so the binary inherited the build machine's OS (macOS 26) and refused to launch on anything older, despite the stated 12.0 requirement. The build now targets macOS 12.0 explicitly.

## [0.0.3] - 2026-06-22

### Changed
- Reworked how the icon appears on desktop-app launch. The app is now started by the existing session hook (which fires when the Claude desktop app opens, when `claude` runs in a terminal, or when a conversation is opened) and quits itself when Claude is closed and no session is active. This keeps the "icon appears when the desktop app opens" behavior from 0.0.2 with no background helper.

### Removed
- The background watcher (a `launchd` LaunchAgent running a shell script) introduced in 0.0.2. It showed up as a "bash" item under Login Items and Extensions, which was confusing. There is no longer any login item or background item. Upgrading from 0.0.2 removes the old LaunchAgent automatically.

### Fixed
- The menu bar icon now reliably disappears when you quit the Claude desktop app, detected directly rather than relying on the session-end hook (which is unreliable during app shutdown).
- Upgrades now self-heal: the app re-runs its installer when the version changes, so updating from an older version refreshes the hooks and removes the old background watcher without any manual step. Previously the installer only ran on a first-ever install.

## [0.0.2] - 2026-06-21

### Added
- Desktop app watcher: the menu bar icon now appears the moment the Claude desktop app opens, before you start a conversation, and disappears shortly after you quit it. Previously the icon only showed once a session began. Implemented as a lightweight `launchd` LaunchAgent that tracks the Claude desktop process (installed via `install.js`, removed via `uninstall.js`).

### Changed
- Ending a Claude Code session no longer hides the icon while the Claude desktop app is still open.

### Fixed
- Uninstall now removes all of the app's own hooks, including the `SessionStart` / `SessionEnd` lifecycle hooks that a previous version left behind. It only ever touches this app's hooks, never any others.

### Notes
- The desktop watcher is part of the DMG / standalone install path. The Claude Code plugin install path keeps the session-only behavior.

## [0.0.1] - 2026-06-21

### Added
- Initial release: macOS menu bar status indicator for Claude Code, driven entirely by Claude Code hooks.
- Animated Claude spark, elapsed turn timer, and an "awaiting permission" dot.
- Two animation styles (Claude, Claude Code) and two color modes (Orange, System), persisted in preferences.
- Refcounted session lifecycle: launches when Claude Code opens, quits when the last session ends.
- Signed and notarized DMG so it opens without a Gatekeeper warning.
- Claude Code plugin marketplace manifest for the plugin install path.

[0.3.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.4
[0.3.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.3
[0.3.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.2
[0.3.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.1
[0.3.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.3.0
[0.2.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.2
[0.2.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.1
[0.2.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.2.0
[0.1.0]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.1.0
[0.0.5]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.5
[0.0.4]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.4
[0.0.3]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.3
[0.0.2]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.2
[0.0.1]: https://github.com/m1ckc3s/claude-status-bar/releases/tag/v0.0.1
