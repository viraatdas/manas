# Manas agent notes

## Execute: Orphans

- None.

## Execute: Discoveries

- `ContentView.selectedDate` previously updated only `MainHeaderView`; the todo and timeline sections remained hard-wired to today, so the header navigation was visually active but functionally disconnected.
- The active Arc `Default/History` SQLite database can be locked while Arc is running; ingestion must query a temporary read-only snapshot of the database and its WAL sidecars rather than require Arc to quit.
- The requested local stores exist on the development Mac at Arc `User Data/*/History`, Messages `~/Library/Messages/chat.db`, and Screen Time/CoreDuet `~/Library/Application Support/Knowledge/knowledgeC.db`; Messages and Screen Time access may require Full Disk Access for the installed app.
- `/Applications/Manas.app` existed before this task but predates the current repository timeline changes; always rebuild, reinstall, and verify the installed bundle before reporting it as current.
- The day timeline is horizontal. Every carousel page has a fixed width and its own vertical `ScrollView`, so a `LazyHStack` can place off-screen dates exactly while long todo lists still scroll independently.
- The carousel deliberately leaves an 88pt width delta for neighboring-day peeks. Gesture snapping uses view alignment; chevron/Today jumps briefly bypass it and confirm the page nearest the viewport center from measured `midX` positions.
- Todo sections are optional strings on `Todo`, normalized through `TodoSectionName`. Built-in Work/Personal/Projects choices are always available; custom names remain available while any saved todo uses them, and legacy todos decode with no section.
- First launch defers the token-spending auto check until onboarding finishes. The source setup page calls `refreshSourceHealth` instead, which probes all local readers and updates permission state without invoking Claude; finishing or skipping then starts the normal hourly cadence.

## Execute: Dead-ends tried

- SwiftUI `scrollPosition(id:anchor:)` was tried with both lazy and eager variable-height vertical day stacks, plus `defaultScrollAnchor` and `ScrollViewReader`; live checks showed the binding and the actual top page could disagree by one or more days. The horizontal pager still keeps one proxy authority and derives the visible date from measured page centers.
