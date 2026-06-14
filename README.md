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

## How it works (and what to check before you trust it)

This tool touches your Claude credentials, so please read the ~250 lines of
`SessionWidget.swift` and `session_usage_poll.py` before running it.

The 5-hour usage window is a **server-side** counter that spans every surface
(Claude Code, claude.ai web, mobile). Your local Claude Code transcripts only
see Claude Code, so reconstructing the window from them drifts whenever you also
use the web/app. The only way to get the exact number is to read Anthropic's
rate-limit headers — and those only come back on a real API call. So:

- **`session_usage_poll.py`** (a launch agent, every 10 minutes):
  - Reads your existing **Claude Code OAuth token** from the login keychain
    (the `Claude Code-credentials` item that Claude Code itself created — the
    first run may pop a one-time keychain "allow" prompt).
  - Makes **one tiny 1-token `/v1/messages` call** and reads the
    `anthropic-ratelimit-unified-*` response headers.
  - Writes them to `~/.claude/session-usage.json`. That's it.
  - It **only calls when you've used Claude Code in the last ~12 minutes**, so
    an idle Mac never pings (a call after the window expired would itself *open*
    a new window). It clears `ANTHROPIC_API_KEY` so the call always bills to
    your subscription, never pay-as-you-go API credits. Cost is negligible.
- **`SessionWidget.swift`** just reads `~/.claude/session-usage.json` and draws
  the card. With `--widget-only` (no poller) it instead estimates the window by
  chaining 5-hour blocks across your transcript timestamps and labels it `est`.

Nothing is sent anywhere except that one call to `api.anthropic.com` with your
own token. No telemetry, no third-party servers, no analytics.

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
