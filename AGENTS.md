# Manas agent notes

## Execute: Orphans

- None.

## Execute: Discoveries

- `ContentView.selectedDate` previously updated only `MainHeaderView`; the todo and timeline sections remained hard-wired to today, so the header navigation was visually active but functionally disconnected.
- The active Arc `Default/History` SQLite database can be locked while Arc is running; ingestion must query a temporary read-only snapshot of the database and its WAL sidecars rather than require Arc to quit.
- The requested local stores exist on the development Mac at Arc `User Data/*/History`, Messages `~/Library/Messages/chat.db`, and Screen Time/CoreDuet `~/Library/Application Support/Knowledge/knowledgeC.db`; Messages and Screen Time access may require Full Disk Access for the installed app.
- `/Applications/Manas.app` existed before this task but predates the current repository timeline changes; always rebuild, reinstall, and verify the installed bundle before reporting it as current.
- The day timeline is a continuous vertical `LazyVStack`: saved past days sit above Today and a rolling future horizon extends below it. Future days render a lightweight add button and only the active future day owns a live text field, avoiding the layout/focus loop captured in the 0.1.2 hang report.
- Todo sections are optional strings on `Todo`, normalized through `TodoSectionName`. Built-in Work/Personal/Projects choices are always available; custom names remain available while any saved todo uses them, and legacy todos decode with no section.
- First launch defers the token-spending auto check until onboarding finishes. The source setup page calls `refreshSourceHealth` instead, which probes all local readers and updates permission state without invoking Claude; finishing or skipping then starts the normal hourly cadence.

- The iOS companion (ios/) compiles the mac app's Models, AppStore, Design, and Sync sources by path — Theme and Haptics are `#if os(macOS)` conditional, so both platforms share one design system and one store. Regenerate with `cd ios && xcodegen generate`; Manas.xcodeproj is never committed.
- Xcode cloud signing (`-allowProvisioningUpdates` + ASC API key) is rejected for this team key ("Authentication failed: bearer token"), and no Xcode account session exists. Release signing goes through `fastlane prep_signing` (cert + sigh via the API key) with per-target manual `PROVISIONING_PROFILE_SPECIFIER` in the Release config only; Debug/simulator stays automatic-unsigned.
- App Groups cannot be registered from the CLI (no public ASC API resource, and the portal needs a web session), so the app ↔ widget channel is a shared keychain access group (`3C4383262W.dev.viraat.manas.shared`) — allowed by every profile via the team wildcard with zero portal setup. See ios/Shared/WidgetSharedState.swift.
- App Store Connect app records cannot be created with a team API key (`apps` forbids CREATE); bundle ids and uploads work fine. The record needs one Apple ID web-session action (fastlane bootstrap_app after `fastlane spaceauth`, or the ASC website).
- Supabase free plan: the account is at its 2-active-project cap, so scripts/backend-up.sh is staged but blocked until a slot frees; supabase/config.toml + migrations define the whole backend (phone test-OTP auth + todos table with RLS).

## Execute: Dead-ends tried

- SwiftUI `scrollPosition(id:anchor:)` was tried with both lazy and eager variable-height vertical day stacks, plus `defaultScrollAnchor`; live checks showed the binding and the actual top page could disagree by one or more days. The current vertical feed uses `ScrollViewReader` only for explicit Today jumps and derives Today visibility from measured geometry.
