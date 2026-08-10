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
- **A phone identity is always full E.164 digits, country code included.** The
  server derives a row's owner from the JWT with `regexp_replace(phone,
  '[^0-9]', '', 'g')` and a JWT phone is always international, so
  `(309) 826-4765` is the account `13098264765` — never `3098264765`.
  `is_share_member()` compares with `=`, so a roster row written from the bare
  national digits matched nothing, and RLS did exactly its job: the group and
  every todo in it were hidden from the person it had been shared with, while
  looking complete to its owner. Every entry point that takes a number from a
  human goes through `PhoneIdentity.canonical(_:signedInAs:)` (and
  `AppStore.canonicalPhone`), which borrows the country code from the number the
  inviter is signed in as — by length, then checked against
  `PhoneRegion.dialCodes`, so an unrecognizable prefix asks for a `+` rather
  than storing digits that reach nobody. `PhoneIdentity.normalized` is the
  *already-international* form and must never be used on typed input.
  The server enforces the same rule independently
  (`shared_group_members_canonical_phone`, migration
  `20260807060000_canonical_member_phones.sql`), because shipped clients keep
  writing the old shape until everybody updates. Do not "simplify" either half
  away, and do not compare a typed number to an identity with `==`.
- **Contacts are read on device and never leave it.** Member avatars draw
  initials from `CNContactStore` via `ContactNames`, whose resolved names are
  held in memory, drawn, and forgotten — never written onto a
  `SharedGroupMemberRecord`, never pushed to Supabase. `displayName` is the only
  name that syncs. This is what keeps the feature outside the App Store privacy
  label's definition of collection, so anyone tempted to cache a resolved name
  into the store or send it with a share is changing a privacy commitment, not
  an implementation detail. It also means the same group correctly reads "KR" on
  a phone that has Krithik in its contacts and stays unnamed on one that
  doesn't. `MemberBadge.initials` returns `String?` and the old
  `digits.suffix(2)` fallback is gone for good: digits in a circle read as
  initials, which is how a shared list came to show "65" and "44" for people it
  had never heard of. No name means the neutral `person.fill` glyph.
- **The avatar and the label are two code paths, and both have to ask.**
  `MemberBadge.initials` resolved contacts from the start; `AppStore.memberLabel`
  did not, so the share panel drew "KR" in the circle and the raw digits in the
  text beside it, with a "Name" button offering to fix a name the phone already
  knew. Both now run the same precedence — you, then the address book, then a
  `displayName` set in the group, then the number — and `AppStore.hasName` is
  what any "name this person" affordance keys on, so nobody is asked to type a
  name their device already has. `memberLabel` reads `store.contactNames`
  (injectable, defaulting to `ContactNames.shared`) rather than the singleton,
  because the naming rules cannot be tested against the real Contacts framework
  and untested is how the label drifted from the avatar in the first place.
  Anything new that renders a member — a header, a tooltip, a share sheet on a
  third platform — goes through `memberLabel`, never `displayName ?? digits`.
- **A members-list row is `AppStore.presentation(of:in:)`, both platforms.**
  The two views each computed their own second line and drifted again: iOS drew
  the number unconditionally and macOS drew it for any owner, so a member with
  no name rendered the same digits on both lines — the number as the title
  (memberLabel's fallback) and the number again underneath. `detail` is now
  derived from `title` (`title == number ? ownerTag : …`) rather than guessed
  in parallel, so it cannot repeat it whatever `memberLabel` later decides to
  say. Do not reintroduce a per-platform caption expression.
- **Say which names sync.** `nameSource` distinguishes `.contacts` (local, never
  pushed, only this device sees it) from `.group` (a `displayName`, pushed to
  everyone) from `.you`. Both share panels mark a `.contacts` name with a
  `person.crop.circle` and state the rule in a footer, because the two are
  otherwise identical on the row and there is no way to tell whether naming
  somebody did anything for anyone but you.
- **Naming yourself is `setMyDisplayName`, never `setMemberName`.** They look
  interchangeable on your own row and are not: `setMemberName` writes one
  membership row, so the name was missing from your other groups and Settings
  still showed an empty field — indistinguishable from a name that failed to
  sync. `setMyDisplayName` sets it and carries it to every group at once.
  `ShareMerge.pushable` lets a device write its own membership row in any
  group, so the name does reach everyone.
- **"No contacts permission" and "nobody here is in your contacts" look
  identical, and only one is fixable.** The development Mac had no
  `kTCCServiceAddressBook` row for `dev.viraat.manas` at all, so every member
  rendered as digits under a footer promising names from Contacts — the
  feature was inert with nothing on screen admitting it. Both share panels now
  key an explanation off `ContactNames.canReadContacts` and offer either the
  prompt (`canAskForContacts`) or a jump to Settings. Check TCC directly when
  a permission-shaped feature "just doesn't work":
  `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "select client,
  auth_value from access where service='kTCCServiceAddressBook';"` — no row
  means never asked, which is not the same as denied.
- **The hardened runtime needs the entitlement, not just the usage string.**
  `scripts/make-app.sh` signs with `--options runtime`, and under it macOS
  refuses a Contacts request *before it becomes a prompt* unless the binary
  carries `com.apple.security.personal-information.addressbook`. The app had
  `NSContactsUsageDescription` and nothing else, so: no dialog, no denial, no
  row in the TCC database, nothing to switch on in Privacy & Security, and
  every member of a shared group reading as digits. Member names shipped inert
  in 0.4.6, 0.4.7 and 0.4.8 that way. `make-app.sh` now writes
  `dist/Manas.entitlements`, signs the app (not the Sparkle helpers) with it,
  and **fails the build** if the entitlement is missing from the finished
  bundle, because the symptom is silence. Do NOT add the App Sandbox while
  fixing something like this: Messages, Arc history and knowledgeC are reached
  through Full Disk Access and sandboxing would cut all three off.
  Diagnose with `codesign -d --entitlements - --xml <app>` — "(none)" against
  `flags=0x10000(runtime)` is the whole bug.
- **A probe seam proves the seam, not the feature.** Every verification run of
  member names used `MANAS_PROBE_CONTACTS`, which swaps in
  `ProbeContactDirectory` and never touches `CNContactStore` — so the naming
  logic was proven repeatedly while the real permission path had never once
  been exercised. When a feature depends on a system permission, one run has
  to go through the real framework on a real machine, or the only thing tested
  is the fake.
- **Don't mark a permission as asked until the system records a decision.**
  `requestAccessIfNeeded` set `hasAskedForAccess = true` before awaiting the
  request, so a prompt that never appeared — hidden app, no window to present
  from — burned the single ask for the whole process. It now sets the flag
  from `!directory.canAsk` *after* the await, so an unshown prompt is retried
  rather than silently swallowed.
- The offline verification seams (`MANAS_DISABLE_SYNC`, `MANAS_STATE_FILE`,
  `MANAS_DISABLE_AUTO_CHECKS`, `MANAS_PROBE_CONTACTS`,
  `MANAS_PROBE_SIGNED_IN_AS`) only work if the app lets `SyncController` pick
  its own auth. `ManasIOSApp` named `StytchSyncAuth()` explicitly, which
  bypassed `isDisabledByEnvironment` — so `MANAS_DISABLE_SYNC` was silently
  macOS-only and every simulator run reached the live backend. Construct the
  controller as `SyncController(stateURL:)` and let the default stand.
  `MANAS_PROBE_SIGNED_IN_AS=+1…` gives a scratch run an identity without a
  session (it is what an invite's missing country code resolves against);
  `bearerToken()` throws and `syncNow()` refuses to run while the seam is set,
  so nothing can leave the machine.

  **The same mistake was sitting one seam over.** `ManasIOSApp` also named
  `AppGroup.stateURL` explicitly, which computes exactly the path
  `AppStore.defaultStateURL` does minus the `MANAS_STATE_FILE` override — so
  the scratch-state seam was silently macOS-only too, and a simulator run read
  and wrote the *real* state file while looking like it honoured the override.
  It is now `AppStore()`, and `AppGroup` no longer vends a `stateURL` at all.
  The general rule: a seam that lives inside a type's own default is defeated
  by any caller that names the value instead. On both platforms, construct
  these with the default and let the type decide — and when a probe run shows
  an empty screen where you seeded data, suspect the seam before the data.
- **`AXUIElementSetAttributeValue` on a SwiftUI `TextField` does not commit the
  binding.** It sets `NSTextField.stringValue` without the editing-changed path,
  so `@State` stays empty, the Share button stays `.disabled`, and pressing it
  looks like a silent failure of the feature rather than of the harness. Post
  real key events with `CGEventPostToPid` instead — which also does not steal
  the user's focus. And when matching AX elements by label, prefer an exact
  match: "Share" is a substring of "Share this group with a phone number", and
  that one comes first in tree order.
- UI geometry claims are checkable without touching the user's screen: drive a scratch bundle through the accessibility API (`AXUIElementPerformAction` presses buttons in a background window; ScreenCaptureKit captures it un-raised — see the screenshot rule below, `screencapture -l` no longer works) and compare element `AXPosition` before and after. That is how the scroll jump was quantified, and how the fix was confirmed at exactly +0.0pt. Note `kAXWindowsAttribute` on this app hands back the application element — walk the app element's children for the `AXWindow` instead, and guard the walk against cycles.

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
7. `bash scripts/ios-testflight.sh` uploads and stops there. Finishing the
   delivery is four more commands, from `ios/` with `.asc.env` sourced:
   - `TF_BUILD_NUMBER=<n> fastlane tf_internal` — waits for `VALID`, clears
     export compliance, puts it in front of internal testers.
   - `TF_BUILD_NUMBER=<n> fastlane tf_external` — attaches it to the External
     Testers group. An external group is created `hasAccessToAllBuilds: false`,
     so unlike the internal one it does **not** inherit new builds.
   - `TF_BUILD_NUMBER=<n> ASC_REVIEW_PHONE=<+1…> fastlane submit_beta_review`.
   - `TF_BUILD_NUMBER=<n> fastlane tf_delivery_status` — the proof. Ship only
     when it reports `processing=VALID`, `internal=IN_BETA_TESTING`,
     `external=IN_BETA_TESTING`, `betaReview=APPROVED`.

   Skipping the middle two leaves a build that is `VALID`, live to internal
   testers, and sitting at `external=READY_FOR_BETA_SUBMISSION` — reaching
   every external tester exactly never, with nothing anywhere reporting a
   problem. `tf_external` deliberately picks the external group with the most
   testers: same-named empty twins have existed on this app, and attaching to
   one of those succeeds and still reaches nobody.

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
