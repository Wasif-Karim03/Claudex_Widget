# Claudex: session handoff (2026-10-16)

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

## Open findings (Codex inspection, `artifacts/claudex-vjuoo5d7/result.json`)
1. **Codex fallback ignores report time.** When the newest rollout has no limits, the fallback takes the first older candidate that has retained limits without comparing when each was reported. It should compare report times.
2. **Codex freshness.** A report that is still in the tail never goes stale. Freshness should come from when the report was made and whether its reset time has passed. `codexObservedAt` is renewed on every scan and shouldn't be.
3. **Claude retained metadata is evicted.** The model and cwd we keep for a session are dropped once it's idle for more than 2 minutes, so a resumed session loses its model. Keep that lightweight metadata separately from the parse cache.
4. **Codex headline.** The headline uses the first live session that has a model. It should come only from the newest rollout, as the Claude side already does.

## Next steps
- Get the user's feedback on the look after they run the app.
- Optionally fix the 4 open findings above.
- Bring CPU down from about 10% while both mascots are animating, for example with a lower frame rate or by pausing when collapsed and idle.
- Manual checks still to do: click-through, Reduce Motion, Launch at Login (needs the app in /Applications), and a display without a notch.

## Key files
- `Sources/ClaudexCore/Claude/ClaudeUsageClient.swift`: token, HTTP, throttle and backoff.
- `Sources/ClaudexCore/Claude/ClaudeSessionReader.swift` and `Sources/ClaudexCore/Codex/CodexSessionReader.swift`: log parsing.
- `Sources/ClaudexCore/LiveSessions.swift`: live-session discovery and `ParseCache`.
- `Sources/Claudex/AppModel.swift`: state and polling loops.
- `Sources/Claudex/AppDelegate.swift`, `Sources/Claudex/NotchPanel.swift`, `Sources/Claudex/NotchGeometry.swift`: panel, hit-testing, notch geometry.
- `Sources/Claudex/Views/` (`PixelMascots.swift`, `ProviderCard.swift`, `RootView.swift`): the UI.
