# Claudex

A tiny macOS widget that lives under the camera notch and shows how much **Claude** and **Codex** usage you have left.

Collapsed, it is a notch-black pill with two little pixel mascots and progress rings either side of the camera. Hover it and it springs open into a card showing, for each tool:

- **% left** in each rate-limit window (Claude: 5-hour and weekly; Codex: whatever windows the CLI reports), as animated capsule bars
- **reset countdown** for each window
- **plan** (e.g. Max, Pro)
- **current model**: the model of the most recently active session (e.g. Opus 5.5, GPT-6.1 Sol)
- **Live now**: every session whose log changed in the last ~2 minutes, with its model and project, including Claude Code subagents (marked *subagent*). The top three are listed, then "+N more".

### The mascots

Claude is the blocky orange pixel critter from Claude Code; Codex is a mint pixel robot with an antenna and a `>_` screen face. They react to what is happening:

- **working** (a session is writing): they bounce, step their legs, tap their arms, throw little typing sparkles, and Codex's antenna light blinks
- **idle**: slow breathing and the occasional blink
- **asleep** (nothing for over 10 minutes): eyes closed, floating "z"
- **worried** (any window over 80% used): sweat drop, redder tint and a nervous wiggle

They animate in the collapsed pill too. With *Reduce Motion* on, they hold still.

## Screenshots

Collapsed:

![Collapsed pill](docs/screenshots/collapsed.png)

Expanded:

![Expanded card](docs/screenshots/expanded.png)

## Requirements

- macOS 14 or later (Apple silicon)
- Swift 6 toolchain (Xcode 16 or later)
- [Claude Code](https://claude.com/claude-code) installed and signed in (Claudex reads its login from the keychain)
- The Codex CLI used at least once, so `~/.codex/sessions` has a session log

## Build and run

```sh
# Run straight from the package
swift run Claudex

# Or build a signed app bundle
scripts/bundle.sh && open build/Claudex.app
```

`scripts/bundle.sh` builds a release binary and wraps it in `build/Claudex.app` (ad-hoc signed, `LSUIElement`, so there is no Dock icon).

**Launch at Login**: move `Claudex.app` to `/Applications` first, then turn on *Launch at Login* from the gear menu (or right-click the widget). macOS may ask you to approve it in System Settings › General › Login Items. The toggle is disabled when running via `swift run`.

The gear menu and the right-click menu also have **Refresh** and **Quit**.

## Where the data comes from

| | Source |
| --- | --- |
| Claude usage | `GET https://api.anthropic.com/api/oauth/usage` with Claude Code's OAuth token |
| Claude plan | `subscriptionType` in Claude Code's keychain entry, if present |
| Claude sessions, models, activity | transcripts at `~/.claude/projects/<project>/*.jsonl` and subagent logs at `~/.claude/projects/<project>/<session>/subagents/agent-*.jsonl`; project name from the transcript's `cwd` (or, failing that, the decoded folder name) |
| Codex usage, plan, sessions, models | rollouts at `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`; project name from the session's `cwd` |

Both log directories are only ever read, never written.

## Privacy

- The Claude OAuth token is read with `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` **fresh on every poll**. It is held in memory only for that request, sent only to `api.anthropic.com`, and never stored, cached, logged or written to disk or UserDefaults.
- The first read may show a one-time keychain prompt asking to let `security` access the item; choose *Always Allow* to avoid repeats.
- Claudex never refreshes the token. If it has expired, the card shows *Sign in to Claude Code*; using Claude Code once refreshes it.
- Nothing is sent anywhere else. There are no analytics.
- When decoding project folder names, Claudex never lists privacy-protected folders (Desktop, Documents, Downloads, media folders, Library, external volumes), so it does not trigger macOS folder-access prompts.

## Polling

- **Claude usage**: every 60 seconds. On rate limiting (429), server errors or network failures it backs off, doubling up to 15 minutes (and honours `Retry-After`); it drops back to 60 seconds after a success. When sign-in is needed it checks every 5 minutes. Manual refresh never polls more often than once a minute.
- **Local session logs**: every 3 seconds, Claudex checks file dates only (no reading) to find live sessions. It parses only the live logs and the newest one, only when they have changed, and reads only their last 64 KB. For a Codex log whose model or folder isn't in that tail, it also reads the first 64 KB.
- If a fetch fails after a success, the last numbers stay on screen marked *stale*.

## Development

```sh
swift build
swift test
```

`ClaudexCore` (models, parsing, the usage client) is Foundation-only and covered by tests; the `Claudex` executable holds the AppKit panel and SwiftUI views.
