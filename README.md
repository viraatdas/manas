# Manas

The control panel for your day. Manas is a native macOS app: you write your
todo list, and it quietly checks in on your day by itself — reading your
local Claude Code and Codex sessions, Arc history, Screen Time, and Messages, having Claude judge how
each todo is actually going, and surfacing work you did but never wrote
down. Every token a check-in costs is on display in the usage strip.

No API key and no third-party dependencies: judging shells out to your
installed `claude` CLI (subscription auth), and everything else is SwiftUI,
Swift Charts, and SF Symbols.

## What it does

- **A real first-run setup** — a three-step, skippable welcome flow shows how
  evidence changes a todo, checks all five local sources without spending any
  Claude tokens, and lets you add a real first todo before the automatic judge
  starts. Reopen it any time with **⌘/** or **Help → Welcome to Manas**.
- **Automatic check-ins** — one on a fresh install, then at most one every
  hour across relaunches, plus a refresh button in the header for an on-demand
  pass (it spins while a check runs). The header's "Last checked 2:14 pm · 2
  sources synced" line is the heartbeat; failures appear as a quiet caption
  in the footer.
- **Five local activity sources** — Claude Code and Codex sessions, Arc page
  titles, Screen Time app usage, and same-day iMessage text. Sources sync
  independently, so a permission problem never hides the activity that is
  still available.
- **Todos with verdicts** — each todo gets a chip (Done / In progress /
  Not started / Unknown) plus one line of evidence pulled from your real
  coding sessions, with accept/dismiss controls.
- **Automatic grouping** — the judge clusters related todos under a short
  project/theme label (for example "Manas" or "Exla infra") with no manual
  management. Ungrouped one-offs stay in a plain cluster at the top, labeled
  groups follow, and labels are reused across the day's re-checks so clusters
  stay stable. Anything you add from a discovered activity inherits its group.
- **Discovered activities** — "You might have also done this": feature-level
  work found in your sessions that wasn't on the list. Add it (arrives
  checked off) or dismiss it (it stays dismissed on future checks).
- **A continuous day feed** — one vertical scroll with Today anchored at the
  top and primary. Scroll up into past days (read-only history with
  "Move to today" for unfinished work, gently dimmed); scroll down into future
  days, where one click opens the inline composer without keeping dozens of
  text fields alive off-screen. Day headers pin as their section scrolls, and a
  floating **Today** pill (also ⌘T) reappears to bring you back whenever Today
  is off-screen. Future days are planning lists and are never sent to the
  judge.
- **Usage strip** — a compact footer line with a 5-dot soft-budget gauge and
  today's tokens · cost · checks. Click it for a slide-down panel with
  today's total, a per-check-in table (including which model ran), a
  "Coding sessions today" card showing how many tokens each observed Claude
  Code and Codex session spent (their subscription usage, kept separate from
  Manas's own check-in cost), and a 7-day sparkline.
- **Persistence** — todos, discoveries, and the full usage history survive
  relaunch (`~/Library/Application Support/Manas/state.json`).

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16+)
- The [claude CLI](https://docs.anthropic.com/en/docs/claude-code) installed
  and logged in — Manas finds it in the usual places (`~/.local/bin`,
  `~/.claude/local`, Homebrew) or via your login shell's PATH
- Codex CLI optional — its sessions are ingested when present; Claude Code
  alone works fine

## Build and run

```sh
swift build
swift test
swift run Manas
```

A check-in reads local transcript files under `~/.claude/projects` and
`~/.codex/sessions`, Arc's Chromium history database, the local Screen Time
store, and the local Messages database, then makes one `claude -p` call (always Sonnet — there
is no model setting). A completely empty day —
no todos, no sessions — skips the call entirely. On a busy day a pass can
take a minute or two; the prompt carries your whole day.

Messages and Screen Time normally require enabling `/Applications/Manas.app`
in **System Settings → Privacy & Security → Full Disk Access**, followed by a
full quit and relaunch. Access is read-only. Manas never joins Messages to
contact names or addresses; it redacts emails, phone numbers, and links, and
reduces Arc URLs to page titles and host names. The resulting same-day snippets
are sent through the installed Claude CLI for todo judging. Raw source rows are
never written to `state.json` or application logs.

## Layout

- `Sources/Manas/Models` — todos, verdicts, activities, usage records
- `Sources/Manas/Ingestion` — Claude Code, Codex, Arc, Screen Time, and
  Messages readers plus the concurrent, permission-aware aggregator
- `Sources/Manas/Judge` — the `claude` CLI judge: locator, process runner,
  prompt, and strict-JSON output parsing
- `Sources/Manas/Store` — `AppStore`: observable state, debounced atomic
  JSON persistence, and the automatic check-in engine
- `Sources/Manas/UI` — Screen 1 (day view), Screens 2+3 (usage strip and
  expanded panel), and the first-run onboarding flow

Tests run without the CLI. A few opt-in live tests spend real tokens:
`MANAS_CLAUDE_INTEGRATION=1 swift test --filter Integration`.
