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
- Anything scoped to "a section of the day" must key off the day as well as the label. The feed stacks every day in one scroll view and most days own a Work and a Personal group, so a label-only key (`group:work`) folded all of them from one click, resized the history above the viewport, and threw the scroll position — measured at −141pt under the cursor. `SectionKey.group(_:on:)` carries the day; `AppStore.pruningCollapsedSections` keeps the per-day keys from accumulating and drops the dayless legacy ones.
- A locally built copy of the app reads the *installed* app's keychain: `KeychainStore`'s service name is a fixed string, not scoped by bundle id, so a scratch build signs in as the real user and pushes its seed data to the live Supabase. Launch verification builds with `MANAS_DISABLE_SYNC=1` (with `MANAS_STATE_FILE` and `MANAS_DISABLE_AUTO_CHECKS=1`). The seam swaps in `SignedOutSyncAuth` at `SyncController.init` rather than just ignoring the session, because `StytchSyncAuth.init` reads the keychain synchronously on the main thread before any window exists — an ad-hoc-signed rebuild blocks there in `SecItemCopyMatching` and launches windowless.
- A group's identity is `TodoDestination` (label + optional `shareID`), not the label. A shared "Manas" and a private "Manas" are two buckets and must never pour into each other, so `todoGroups(on:)`, the drag targets, and the fold keys all key on `TodoDestination.key`. `SectionKey.group(_:on:)` keeps its old string form for private groups so existing folds survive. The judge only ever sets `group`, never `shareID` — auto-grouping guesses labels, and a guess must not publish private work to somebody else.
- Supabase RLS is checkable locally without the hosted project or the full Supabase stack: `docker run postgres:15-alpine`, a ~20-line stub of `auth.jwt()`/`auth.uid()`/`auth.users` and an `authenticated` role, then replay `supabase/migrations/*.sql` in order and drive scenarios with `set local role authenticated` + `set local request.jwt.claims`. That is how the sharing policies were verified — and how the hole where an outsider holding a share id could insert todos into it was found.
- PostgREST upserts with `on conflict do update`, and Postgres applies the INSERT policy's `with check` to the *final* row. So a write policy on a collaborative table cannot be keyed on the row's author: it would block a member from ever ticking a box on somebody else's row. It also means a client must never push a row it lacks rights to — one rejected row fails the whole batch and wedges every later sync, which is what `SyncMerge`'s `isWritable` and `ShareMerge`'s drop-unpushable-tombstones rule exist to prevent.
- The contact *picker* needs no Contacts permission but reading names does, and
  they are different features. The picker is out-of-process and hands back only
  what the user tapped; naming a member nobody picked — somebody who shared a
  group with *you* — means `CNContactStore`, which needs
  `NSContactsUsageDescription` in both bundles (ios/project.yml and the plist
  scripts/make-app.sh writes). Resolved names are drawn and forgotten: they are
  never written to a member record and never pushed to Supabase, so no contact
  data is "collected" for the App Store privacy label. `CNContact
  .predicateForContacts(matching:)` does work — verified on a simulator with a
  seeded address book, matching a contact saved as "(309) 826-4765" to a member
  stored as `13098264765` — but `ContactNames` re-checks every hit through
  `PhoneIdentity` and keeps a full-enumeration fallback anyway, because the
  predicate's rules are undocumented and a Contacts predicate has been silently
  ignored in this app before. Which path answered is in the unified log under
  `subsystem == "Manas"`, category `ContactNames` (debug level: `log stream`
  catches it, `log show` after the fact does not).
- UI geometry claims are checkable without touching the user's screen: drive a scratch bundle through the accessibility API (`AXUIElementPerformAction` presses buttons in a background window; `screencapture -x -o -l <id>` captures it un-raised) and compare element `AXPosition` before and after. That is how the scroll jump was quantified, and how the fix was confirmed at exactly +0.0pt. Note `kAXWindowsAttribute` on this app hands back the application element — walk the app element's children for the `AXWindow` instead, and guard the walk against cycles.

## Execute: Dead-ends tried

- SwiftUI `scrollPosition(id:anchor:)` was tried with both lazy and eager variable-height vertical day stacks, plus `defaultScrollAnchor`; live checks showed the binding and the actual top page could disagree by one or more days. The current vertical feed uses `ScrollViewReader` only for explicit Today jumps and derives Today visibility from measured geometry.
- A single `proxy.scrollTo(today, anchor: .top)` — whether at launch or on ⌘L — is not reliable in this feed for the same reason: a LazyVStack has realized only a handful of its ~127 sections on the first pass and the rest are height estimates, so a scroll aimed across unbuilt days lands short (observed opening on a day six back in history). Both paths now nudge, measure Today's frame against the viewport, and re-nudge until it lands; each pass realizes more of the feed, so it converges in a few frames. Do not replace this with a single call.

## Deploy Configuration

Manas ships two artifacts from one repo. Neither goes through a web deploy, and
neither has a staging environment.

- **Platform:** macOS Developer ID (direct distribution, not the Mac App Store) + iOS TestFlight/App Store.
- **Mac distribution:** notarized DMG on GitHub Releases, auto-update via Sparkle appcast at https://manas.viraat.dev/appcast.xml.
- **Production URL:** https://manas.viraat.dev (marketing site + the appcast; deployed from `site/` to Vercel).
- **iOS:** App Store Connect app `dev.viraat.manas.ios` (id 6794079354), TestFlight internal + external groups.
- **Backend:** Supabase project `gdnknuiqxmosuwoytrzc`. Migrations in `supabase/migrations/` are applied with `supabase db push`.
- **Version source of truth:** `VERSION`/`BUILD` in `scripts/make-app.sh` (mac) and `CURRENT_PROJECT_VERSION` in `ios/project.yml` (iOS). Bump both together.
- **Release notes:** `release-notes-<x.y.z>.md` is required by `scripts/release.sh` and fails the release if missing.

### The release sequence

Run in this order. Do not skip a step because the previous one "obviously" worked.

1. `~/.agent-skills/release-gate/scripts/preflight.sh` — must exit 0, or every
   blocker it prints must be reported to the user and explicitly overridden by them.
2. `bash scripts/e2e.sh` — macOS build, unit suite, live backend contract, the
   two-account shared-group RLS boundary, live client integration, iOS build.
3. Apply any pending migration **before** shipping the client that needs it
   (`supabase db push`). A client that sends a column the server lacks 400s on
   every sync, for every existing user.
4. Bump `scripts/make-app.sh` + `ios/project.yml`, write the release notes, commit, push.
5. `bash scripts/make-app.sh && bash scripts/release.sh <x.y.z>` — notarize,
   GitHub release, mirror the DMG, regenerate and sign the appcast, deploy the site.
6. `~/.agent-skills/release-gate/scripts/postflight.sh --version <x.y.z>`, then
   confirm the **live** appcast advertises the new version. Postflight passing is
   not sufficient: it does not check the feed.
7. `bash scripts/ios-testflight.sh`, then confirm on App Store Connect that the
   build reached `processingState=VALID` and `internalBuildState=IN_BETA_TESTING`.
   For external testers the build must also be added to the external group and
   submitted for beta review, or it silently reaches nobody.

### Rules learned the hard way

- **Never pipe a release command into `tail`.** `release.sh 0.4.2 | tail -3`
  returns `tail`'s exit status, so a failed release reports success and the
  steps after it are skipped. That is how 0.4.2 shipped with a GitHub release
  but no appcast entry — published, and auto-updating to nobody.
- **A published release is not a shipped release until the appcast carries it.**
  Check `curl https://manas.viraat.dev/appcast.xml` for the version and an
  `edSignature`, every time.
- **Never verify UI by reading the diff.** The contacts picker shipped twice
  without being run, and both times it was broken for a reason no amount of
  reading would have surfaced (a SwiftUI-sheet-wrapped remote view controller,
  then a CNUI predicate silently ignored). Run it: iOS via the simulator with a
  `-manasProbe…` launch argument and `xcrun simctl launch --console-pty`, macOS
  by driving the accessibility API.
- **`strings` does not find Swift string literals in these binaries.** Do not
  use it to decide whether a build contains a change; run the build and look at
  its behaviour.
- **`find -name Manas.app -print -quit` is non-deterministic** — xcodegen
  changes the project identity hash, so several DerivedData folders exist and
  the oldest can win. Always build simulator artifacts with an explicit
  `-derivedDataPath`.
- **Never launch an unbundled scratch build** (`.build/debug/Manas`). Sparkle is
  compiled in, fails to start outside a bundle, and puts a modal error on the
  user's screen. Copy `dist/Manas.app`, strip `SUFeedURL`, and run that instead.
- **Scratch builds must use the offline seams** — `MANAS_DISABLE_SYNC=1`,
  `MANAS_STATE_FILE=<scratch>`, `MANAS_DISABLE_AUTO_CHECKS=1`. Without them a
  local build reads the installed app's keychain and writes to live data.
- **Screenshots must be window-scoped.** The bare form captures the user's
  entire screen, including whatever else they have open. `screencapture -x -o -l
  <windowid>` no longer does this on macOS 26: it goes through
  `CGWindowListCreateImage`, obsoleted in macOS 15, and fails with "could not
  create image from window" even with Screen Recording granted. Use
  ScreenCaptureKit instead — `SCContentFilter(desktopIndependentWindow:)` plus
  `SCScreenshotManager.captureImage` is still window-scoped and still does not
  raise the window. Two gotchas: that tool must touch `NSApplication.shared`
  first or it aborts in `CGS_REQUIRE_INIT`, and it fails with SCStream error
  −3811 while the display is asleep (`caffeinate -u -t 20` in the background is
  enough, and does not steal focus).
- **A scratch app launched as a bare executable has no accessibility tree.**
  `Manas.app/Contents/MacOS/Manas` run straight from the shell vends only its
  menu bar — `AXWindows`, `AXMainWindow`, and even
  `AXUIElementCopyElementAtPosition` all hand back the application element, so
  there is nothing to drive. Launch the bundle through LaunchServices instead:
  `open -g -n -a <app> --env KEY=VALUE …`, which keeps the user's focus. The
  window's AX subtree also stays empty while the display is asleep.
- **CI runs on `macos-26`** and asserts Swift 6.x. macos-15's Xcode 16.4 crashes
  in SILGen on `UsageAnalytics.shared`; a green local build proves nothing about
  a CI that compiles with a different toolchain.
