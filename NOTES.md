# Claudex: session handoff (2026-10-16)

## Goal
A macOS widget under the camera notch that shows live Claude and Codex usage (% used, when each limit resets, plan, model per live session) with animated pixel mascots. The repo is https://github.com/Wasif-Karim03/Claudex_Widget (private, branch `main`).

## Done so far
- The 4 Codex-inspection findings are fixed, with regression tests: limits picked by report time; freshness from reset or later use; metadata kept for every existing log; headline model from the newest rollout only.
- CPU: mascot ticks share an absolute 8/4/2 fps grid (working/idle/sleepy), which took CPU from about 15% to about 11% while a session works.
- Expanded card redesigned as "Rings", direction A from the design page https://claude.ai/artifact/XUTXW1pEQ5Qv2fivxEe13G. Concentric rings are filled by **% used**, with a legend showing each limit's % and reset. It uses SF Pro and SF Mono, and has no glass, glows or chips.
- Claude usage now also parses the response's `limits` list, so per-model weekly limits (e.g. "Fable week") get their own ring (up to 3).

## Decisions
- The card shows % used to match Claude's `/usage`. The user reported a mismatch, and the API data was correct but inverted in the UI.
- The collapsed strip is unchanged at the user's request. Its mini rings still show % **left**, which disagrees with the card.
- The Codex head-of-file fallback for model and cwd is deliberate, because real rollouts record them only near the start.

## Current state
- `swift build` passes and all 76 tests pass. The latest commit is pushed. The app works.
- Known gap: the collapsed ring is % left while the card is % used.

## Next steps
1. Ask the user whether the collapsed ring should switch to % used (look unchanged).
2. If the user still sees a mismatch, get a screenshot saved outside /var/folders (macOS blocks reading that folder).
3. Manual checks still to do: click-through, Reduce Motion, and a display without a notch.

## Key files and commands
- Data: `Sources/ClaudexCore/Claude/ClaudeUsage.swift` (API decode, `limits`), `ClaudeUsageClient.swift`, `Codex/CodexSessionReader.swift`, `LiveSessions.swift`.
- UI: `Sources/Claudex/Views/ProviderCard.swift` (`RingDial`, `RingLegendRow`), `RootView.swift`, `Theme.swift`, `PixelMascots.swift`. Card height: `NotchGeometry.swift` `cardBaseHeight` (220).
- Install (the default way to run it): `./scripts/install.sh` builds, copies to /Applications and launches. The first run from /Applications adds the app to Login Items (once only, via the `didAutoEnableLaunchAtLogin` default). It is installed and enabled as of 2026-10-16.
- Dev run: `./scripts/bundle.sh && open build/Claudex.app`. Test: `swift test`.
- Render the card without screen permission: `CLAUDEX_PIN_EXPANDED=1 CLAUDEX_SNAPSHOT=/path.png .build/debug/Claudex` (the gear shows as a placeholder in renders).
