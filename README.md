# Claude Session Widget

A tiny floating macOS desktop widget that shows your **Claude Code 5-hour usage
window**: a live "resets in" countdown and how much you've used — the same
numbers claude.ai shows, on your desktop at all times.

- Big countdown: time left in the current 5-hour window
- `31% used · resets 22:50` — real token utilisation + reset time
- Progress bar = % used (clay → amber ≥75% → red ≥90%)
- A little Clawd mascot holding a stopwatch 🙂

It reads the exact figures from Anthropic's own rate-limit headers, so it
matches claude.ai to the minute (including the weekly limit).

## Requirements

- macOS (Apple Silicon or Intel)
- **Xcode command line tools** (`xcode-select --install`) — for `swiftc`
- A Claude **Pro/Max** subscription used via **Claude Code** (this tracks the
  Claude Code/subscription 5-hour window)

## Install

```bash
unzip claude-session-widget.zip && cd claude-session-widget
./install.sh
```

That builds the widget from source, installs it to `~/Applications`, and sets up
two per-user launch agents that start at login. **No sudo, nothing system-wide.**

Prefer zero network calls? Install the widget only — it will estimate the window
from your local transcripts instead (see "How it works"):

```bash
./install.sh --widget-only
```

Uninstall any time:

```bash
./uninstall.sh
```

## How it works (and the one network call, explained)

The widget shows your Claude 5-hour usage window: time left and how much you've
used. The goal is to match what claude.ai shows, to the minute.

The catch: that 5-hour limit lives on Anthropic's servers and counts everything
(Claude Code, the web app, mobile). Your Mac can't see your web/app usage, so
guessing the number from local files drifts by up to an hour or two. The only
way to get the real figure is to read it from Anthropic directly.

So here's the deal:

- A small script runs every 10 minutes in the background.
- It grabs your existing Claude Code login token (the one Claude Code already
  saved in your Mac keychain) and makes **one tiny API call** to Anthropic.
  (macOS may show a one-time keychain "allow" prompt the first time.)
- That call sends a single word and asks for 1 token back. Its only purpose is
  to read the "usage limits" info Anthropic attaches to every reply. The reply
  is effectively free and bills to your Claude subscription, not pay-as-you-go
  API credits.
- It saves those numbers to a file on your Mac (`~/.claude/session-usage.json`).
  The widget just reads that file and draws the card.

What it does **not** do:

- It only calls when you've actually used Claude Code in the last ~12 minutes,
  so an idle Mac never pings.
- Nothing goes anywhere except that one call to `api.anthropic.com`, using your
  own token. No third-party servers, no analytics, no tracking.
- It's all here, about 250 lines across `SessionWidget.swift` and
  `session_usage_poll.py`. Please read it before you run it.

Don't want any network calls? Install with `./install.sh --widget-only` and it
estimates the window from your local Claude Code logs instead (less precise,
flagged `est`, zero calls).

## Files

| file | what it is |
|---|---|
| `SessionWidget.swift` | the widget (native AppKit, no dependencies) |
| `session_usage_poll.py` | the 10-min usage poller (Python stdlib only) |
| `build.sh` | compiles the `.app` with `swiftc` |
| `install.sh` / `uninstall.sh` | per-user launchd setup / teardown |

Logs: `/tmp/claude-session-widget.log`, `/tmp/claude-session-usage.log`.
Cache: `~/.claude/session-usage.json` (inspect it any time).

## Notes / FAQ

- **Does it work without the poller?** Yes — `--widget-only` gives a transcript
  estimate with no network calls. It can be off by up to ~1.5h if you also use
  claude.ai web/mobile, and it's flagged `est`.
- **Will the token expire?** Claude Code refreshes it in the keychain as you use
  it. If it's ever stale the poller just keeps the last known reset and the
  widget falls back to the estimate.
- **Apple Silicon vs Intel?** `install.sh` resolves your `python3` automatically.
- It's ad-hoc code-signed locally at build time, so there's no "unidentified
  developer" gate — you built it yourself.

MIT licensed. Built by a Claude Code user for Claude Code users — not affiliated
with Anthropic.
