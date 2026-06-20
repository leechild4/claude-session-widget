#!/usr/bin/env python3
"""Poll Anthropic's authoritative usage limits and cache them for local UIs.

The SessionWidget desktop app reads the file this writes, so it shows the SAME
numbers as claude.ai (which is fed by the very same rate-limit headers). Any
other tool can read ~/.claude/session-usage.json too.

Why a header probe instead of reconstructing from transcripts:
  The 5h usage window is a server-side counter spanning every surface (Claude
  Code, claude.ai web, mobile). Local transcripts only see Claude Code, so a
  reconstruction drifts whenever you also use the web/app. The unified
  rate-limit headers returned on a real /v1/messages call are the source of
  truth, and they only come back on a 200 (not on 4xx), so we make one tiny
  1-token call.

Politeness / correctness:
  - We only probe when there has been local Claude Code activity in the last
    ~12 minutes. An idle Mac never pings — important because a probe sent after
    the window expired would itself OPEN a fresh window, making an idle session
    look perpetually active.
  - While idle we keep the last authoritative reset until it actually passes,
    so the countdown doesn't jump around when you pause.
  - Auth uses the Claude Code OAuth token from the login keychain, so it bills
    against your Claude subscription (Pro/Max), not pay-as-you-go API credits.
    (The launchd job clears ANTHROPIC_API_KEY so it can't fall back to an API
    key by accident.)

Run cadence: every 10 minutes via launchd (see install.sh).
Cache file: ~/.claude/session-usage.json
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
CACHE = os.path.join(HOME, ".claude", "session-usage.json")

WINDOW_MS = 5 * 3600 * 1000
ACTIVE_THRESHOLD_S = 12 * 60      # consider "active" if a transcript changed this recently
LOOKBACK_S = 36 * 3600            # transcript reconstruction fallback horizon
KEYCHAIN_SERVICE = "Claude Code-credentials"


# ---------- helpers ----------

def latest_activity_mtime() -> float:
    """Newest mtime among non-agent transcript files (cheap stat-only scan)."""
    newest = 0.0
    for f in glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True):
        if os.path.basename(f).startswith("agent-"):
            continue
        try:
            m = os.path.getmtime(f)
        except OSError:
            continue
        if m > newest:
            newest = m
    return newest


def transcript_block(now_s: float):
    """Fallback: reconstruct the rolling 5h block from transcript timestamps.

    Returns (start_ms, end_ms) for the current block, or None when idle.
    """
    since_ms = int((now_s - LOOKBACK_S) * 1000)
    stamps = []
    for f in glob.glob(os.path.join(PROJECTS, "**", "*.jsonl"), recursive=True):
        if os.path.basename(f).startswith("agent-"):
            continue
        try:
            if os.path.getmtime(f) < now_s - LOOKBACK_S:
                continue
        except OSError:
            continue
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if '"timestamp"' not in line:
                        continue
                    try:
                        ts = json.loads(line).get("timestamp")
                    except (json.JSONDecodeError, ValueError):
                        continue
                    if not ts:
                        continue
                    try:
                        import datetime as _dt
                        s = _dt.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                    except ValueError:
                        continue
                    ms = int(s * 1000)
                    if ms >= since_ms:
                        stamps.append(ms)
        except OSError:
            continue
    if not stamps:
        return None
    stamps.sort()
    start, end = stamps[0], stamps[0] + WINDOW_MS
    for ms in stamps:
        if ms > end:
            start, end = ms, ms + WINDOW_MS
    now_ms = int(now_s * 1000)
    return (start, end) if now_ms < end else None


def oauth_token() -> str | None:
    try:
        raw = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        creds = json.loads(raw)
    except Exception:
        return None

    def find(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k.lower() in ("accesstoken", "access_token") and isinstance(v, str):
                    return v
                r = find(v)
                if r:
                    return r
        return None

    return find(creds)


def probe_headers(token: str):
    """One tiny 1-token call; return the unified rate-limit headers or None."""
    body = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "hi"}],
    }).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST")
    req.add_header("authorization", f"Bearer {token}")
    req.add_header("anthropic-version", "2023-06-01")
    req.add_header("anthropic-beta", "oauth-2025-04-20")
    req.add_header("content-type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        return dict(resp.headers)
    except urllib.error.HTTPError as e:
        # 4xx/5xx that still passed auth won't carry the unified headers; bail.
        return dict(e.headers) if "anthropic-ratelimit-unified-5h-reset" in {k.lower() for k in e.headers} else None
    except Exception:
        return None


def parse_usage(h: dict | None) -> dict | None:
    if not h:
        return None
    g = {k.lower(): v for k, v in h.items()}
    reset5h = g.get("anthropic-ratelimit-unified-5h-reset")
    if not reset5h:
        return None

    def f(key):
        try:
            return float(g[key])
        except (KeyError, TypeError, ValueError):
            return None

    def ims(key):
        try:
            return int(float(g[key])) * 1000
        except (KeyError, TypeError, ValueError):
            return None

    return {
        "reset5h_ms": ims("anthropic-ratelimit-unified-5h-reset"),
        "util5h": f("anthropic-ratelimit-unified-5h-utilization"),
        "status5h": g.get("anthropic-ratelimit-unified-5h-status"),
        "reset7d_ms": ims("anthropic-ratelimit-unified-7d-reset"),
        "util7d": f("anthropic-ratelimit-unified-7d-utilization"),
        "status7d": g.get("anthropic-ratelimit-unified-7d-status"),
    }


def load_cache() -> dict:
    try:
        with open(CACHE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError, ValueError):
        return {}


def write_cache(d: dict):
    d["fetched_ms"] = int(time.time() * 1000)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh)
    os.replace(tmp, CACHE)
    # ponytail: heartbeat so a frozen error log isn't mistaken for a dead poller
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} ok source={d.get('source')} "
          f"active={d.get('active')} util5h={d.get('util5h')}", flush=True)


# ---------- main ----------

def main():
    now_s = time.time()
    now_ms = int(now_s * 1000)
    prev = load_cache()
    recent = (now_s - latest_activity_mtime()) < ACTIVE_THRESHOLD_S

    if recent:
        token = oauth_token()
        usage = parse_usage(probe_headers(token)) if token else None
        if usage and usage.get("reset5h_ms"):
            write_cache({"source": "api", "active": now_ms < usage["reset5h_ms"], **usage})
            return
        # Probe failed (stale token / network): keep a still-valid prior reading.
        if prev.get("reset5h_ms") and prev["reset5h_ms"] > now_ms:
            write_cache({**prev, "source": prev.get("source", "api"), "active": True})
            return
        # Last resort: transcript reconstruction.
        blk = transcript_block(now_s)
        if blk:
            write_cache({"source": "transcript", "active": True,
                         "reset5h_ms": blk[1], "current_start_ms": blk[0]})
        else:
            write_cache({"source": "transcript", "active": False, "reset5h_ms": None})
        return

    # Idle: never probe (would open a fresh window). Keep last reset until it passes.
    if prev.get("reset5h_ms") and prev["reset5h_ms"] > now_ms:
        write_cache({**prev, "active": True})
    else:
        write_cache({"source": prev.get("source", "idle"), "active": False, "reset5h_ms": None,
                     "util5h": prev.get("util5h"), "util7d": prev.get("util7d"),
                     "reset7d_ms": prev.get("reset7d_ms")})


if __name__ == "__main__":
    main()
