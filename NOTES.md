# Claudex: session handoff (2026-10-16, second session)

## Goal
A macOS widget that sits under the camera notch and shows live Claude and Codex usage: % left, reset countdown and plan for each window, which model is in use per live session, and cute animated pixel mascots. The look should be compact, polished and animated. Push work to https://github.com/Wasif-Karim03/Claudex_Widget (a private repo, branch `main`).

## Current state
- Pushed to `main`, latest commit `6147241`.
- `swift build` passes and all 71 tests pass. `./scripts/bundle.sh` produces a signed `build/Claudex.app`.
- To run it: `./scripts/bundle.sh && open build/Claudex.app`.
- The collapsed pill blends into the notch. Hovering expands it into a card for each of Claude and Codex.
- The /team pipeline run log is at `~/.claude/team-runs/Claudex_Widget-20261016-022212/` (`log.md`, `plan.md`, `fixes-*.md`, plus `artifacts/` holding the Codex review and inspection results).

## Data sources
- **Claude usage:** `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20`. The token comes from `security find-generic-password -s "Claude Code-credentials" -w` (JSON at `.claudeAiOauth.accessToken`). The app never refreshes, logs or stores the token.
- **Claude model and live sessions:** tails of `~/.claude/projects/*/*.jsonl`, plus `*/subagents/agent-*.jsonl` for subagents.
- **Codex:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Usage comes from the nested `rate_limits` object; model and cwd come from `turn_context`.

## Decisions
- Swift package layout: a `ClaudexCore` library (pure Foundation, holds all the tests), the `Claudex` app (AppKit + SwiftUI), and `scripts/bundle.sh` (ad-hoc signed).
- Polling: Claude at most once every 60s, with backoff and Retry-After honoured. Local log files are checked every 3s by modification time, and only the tail of each file is read.
- Codex model and cwd fall back to the first 64KB of the file, because real rollouts record them only near the start. This is deliberate: the inspector flagged it and we rejected that finding.
- Within a single JSON line the search uses sorted-key order. "Last wins" applies only across lines.

## Done this session
- The 4 Codex-inspection findings are fixed, with regression tests (75 tests pass): limits picked by report time; freshness from reset or later use; metadata kept for every existing log; Codex headline from the newest rollout only.
- CPU: mascot ticks now share an absolute 8/4/2 fps grid (working/idle/sleepy), so there is one SwiftUI pass per tick. About 15% went down to about 11% while a session is working. Unmounting the hidden card only saved about 1.8 points, so that was not kept.
- Redesign: one black surface with a hairline between the columns, no glass tiles, glows, gradients or chips. Big tabular % numbers sit over thin flat bars. SF Pro is used for words and SF Mono for model, plan and countdowns. The mini rings are solid colour.
- Dev aids: `CLAUDEX_PIN_EXPANDED=1` keeps the card open. `CLAUDEX_PIN_EXPANDED=1 CLAUDEX_SNAPSHOT=/path.png .build/debug/Claudex` renders the card to a PNG and quits (`ImageRenderer`, needs no screen-recording permission; the gear menu shows as a placeholder there).

## Next steps
- Get the user's reaction to the redesign. The collapsed pill was only touched for ring colour.
- Manual checks still to do: click-through, Reduce Motion, Launch at Login (needs /Applications), and a display without a notch.

## Key files
- `Sources/ClaudexCore/Claude/ClaudeUsageClient.swift`: token, HTTP, throttle and backoff.
- `Sources/ClaudexCore/Claude/ClaudeSessionReader.swift` and `Sources/ClaudexCore/Codex/CodexSessionReader.swift`: log parsing.
- `Sources/ClaudexCore/LiveSessions.swift`: live-session discovery and `ParseCache`.
- `Sources/Claudex/AppModel.swift`: state and polling loops.
- `Sources/Claudex/AppDelegate.swift`, `Sources/Claudex/NotchPanel.swift`, `Sources/Claudex/NotchGeometry.swift`: panel, hit-testing, notch geometry.
- `Sources/Claudex/Views/` (`PixelMascots.swift`, `ProviderCard.swift`, `RootView.swift`): the UI.
