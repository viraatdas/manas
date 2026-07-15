# Manas

The control panel for your day. Manas is a native macOS app: you write your
todo list, and it quietly checks in on your day by itself — reading your
local Claude Code and Codex session transcripts, having Claude judge how
each todo is actually going, and surfacing work you did but never wrote
down. Every token a check-in costs is on display in the usage strip.

No API key and no third-party dependencies: judging shells out to your
installed `claude` CLI (subscription auth), and everything else is SwiftUI,
Swift Charts, and SF Symbols.

## What it does

- **Automatic check-ins** — one when the app launches, then one every hour,
  plus a refresh button in the header for an on-demand pass (it spins while
  a check runs). The header's "Last checked 2:14 pm · 2 sources synced" line
  is the heartbeat; failures appear as a quiet caption in the footer.
- **Todos with verdicts** — each todo gets a chip (Done / In progress /
  Not started / Unknown) plus one line of evidence pulled from your real
  coding sessions, with accept/dismiss controls.
- **Discovered activities** — "You might have also done this": feature-level
  work found in your sessions that wasn't on the list. Add it (arrives
  checked off) or dismiss it (it stays dismissed on future checks).
- **Usage strip** — a compact footer line with a 5-dot soft-budget gauge and
  today's tokens · cost · checks. Click it for a slide-down panel with
  today's total, a per-check-in table (including which model ran), and a
  7-day sparkline.
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

A check-in reads only local transcript files under `~/.claude/projects` and
`~/.codex/sessions`, then makes one `claude -p` call (always Sonnet — there
is no model setting). A completely empty day —
no todos, no sessions — skips the call entirely. On a busy day a pass can
take a minute or two; the prompt carries your whole day.

## Layout

- `Sources/Manas/Models` — todos, verdicts, activities, usage records
- `Sources/Manas/Ingestion` — Claude Code + Codex transcript readers and the
  concurrent aggregator
- `Sources/Manas/Judge` — the `claude` CLI judge: locator, process runner,
  prompt, and strict-JSON output parsing
- `Sources/Manas/Store` — `AppStore`: observable state, debounced atomic
  JSON persistence, and the automatic check-in engine
- `Sources/Manas/UI` — Screen 1 (day view), Screens 2+3 (usage strip and
  expanded panel)

Tests run without the CLI. A few opt-in live tests spend real tokens:
`MANAS_CLAUDE_INTEGRATION=1 swift test --filter Integration`.
