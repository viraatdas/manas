# Manas agent notes

## Execute: Orphans

- None.

## Execute: Discoveries

- `ContentView.selectedDate` previously updated only `MainHeaderView`; the todo and timeline sections remained hard-wired to today, so the header navigation was visually active but functionally disconnected.
- The active Arc `Default/History` SQLite database can be locked while Arc is running; ingestion must query a temporary read-only snapshot of the database and its WAL sidecars rather than require Arc to quit.
- The requested local stores exist on the development Mac at Arc `User Data/*/History`, Messages `~/Library/Messages/chat.db`, and Screen Time/CoreDuet `~/Library/Application Support/Knowledge/knowledgeC.db`; Messages and Screen Time access may require Full Disk Access for the installed app.
- `/Applications/Manas.app` existed before this task but predates the current repository timeline changes; always rebuild, reinstall, and verify the installed bundle before reporting it as current.
- SwiftUI `LazyVStack` plus `ScrollViewReader.scrollTo` mispositions the initial day when page heights differ (today is taller because it contains discoveries); the snap pager uses a bounded eager `VStack` so programmatic Today/chevron targets have exact offsets.
- On macOS, `ViewAlignedScrollTargetBehavior` can rewrite an exact `ScrollViewReader.scrollTo` boundary to an adjacent day. Keep alignment enabled for wheel gestures but bypass it briefly for chevron/Today jumps, then confirm the visible day from measured page positions.

## Execute: Dead-ends tried

- SwiftUI `scrollPosition(id:anchor:)` was tried with both lazy and eager variable-height day stacks, plus `defaultScrollAnchor` and `ScrollViewReader`; live checks showed the binding and the actual top page could disagree by one or more days. Do not reintroduce competing `scrollPosition` and proxy authorities; track the visible day from measured page positions.
