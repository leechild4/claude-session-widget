// SessionWidget — a tiny floating desktop widget that shows the current
// Claude Code 5-hour usage window and a live "resets in" countdown.
//
// Fully standalone: it reconstructs the 5-hour usage window directly
// from ~/.claude/projects/**/*.jsonl transcript timestamps. No external
// server or dependency needed — it works straight from transcript data.
//
// Build:  bash build.sh   ->  SessionWidget.app
// Run:    open SessionWidget.app   (or the LaunchAgent for start-at-login)

import Cocoa

// MARK: - Colour helpers

extension NSColor {
    /// Build an NSColor from a 6-digit hex string, e.g. "#CC785C" or "CC785C".
    static func fromHex(_ hex: String) -> NSColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        let v = UInt64(s, radix: 16) ?? 0
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8)  & 0xFF) / 255
        let b = CGFloat(v         & 0xFF) / 255
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}

// Anthropic / Claude palette
enum Palette {
    static let ivory    = NSColor.fromHex("#F0EEE6") // card background
    static let progressGreen = NSColor.fromHex("#4F8F5B") // progress <=50%
    static let clay     = NSColor.fromHex("#CC785C") // primary accent (normal)
    static let nearBlack = NSColor.fromHex("#141413") // primary text
    static let muted    = NSColor.fromHex("#73706B") // secondary text / idle mascot
    static let amber    = NSColor.fromHex("#C2703D") // urgency <1h
    static let urgentRed = NSColor.fromHex("#BF4D43") // urgency <15m
}

// MARK: - Session computation
//
// Anthropic's usage limit is ONE rolling 5-hour window shared across every
// conversation, NOT a per-file window. The window opens at your first message
// and runs for 5h; the first message sent after it expires opens the next
// window. So we must chain blocks across the UNION of all activity timestamps,
// not per JSONL file — otherwise opening a fresh conversation (a new file)
// makes the countdown jump back up to ~5h even though the real billing window
// opened earlier. The current block is simply the last one in the chain.
//
// This mirrors how claude.ai reports "Current session resets in …". Caveat:
// we only see local Claude Code transcripts. If you also use claude.ai web or
// the mobile app, those messages can open the window earlier than anything
// here, so the reconstruction can slightly over-estimate the time remaining.

struct SessionState {
    var active: Bool
    var startMs: Int64?
    var endMs: Int64?
    var lastActivityMs: Int64?
    var util5h: Double? = nil      // 0…1, authoritative token utilisation (matches claude.ai "% used")
    var util7d: Double? = nil      // 0…1, weekly utilisation
    var reset7dMs: Int64? = nil
    var source: String = "transcript"   // "api" = authoritative header; "transcript" = local estimate
}

// MARK: - Authoritative usage cache
//
// session_usage_poll.py (launchd, every 10 min) writes the exact 5h reset and
// "% used" from Anthropic's rate-limit headers to ~/.claude/session-usage.json.
// Reading that file means the widget shows the SAME numbers as claude.ai and as
// other Claude Code tooling. We fall back to the transcript reconstruction below only
// when the cache is missing/expired (e.g. before the poller's first run).
enum UsageCache {
    static func url() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/session-usage.json")
    }

    /// Returns a state from the cache file, or nil if the file is absent/unreadable.
    /// active=false is a valid (idle) result, distinct from nil (no cache).
    static func load(now: Date) -> SessionState? {
        guard let data = try? Data(contentsOf: url()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let util5 = (obj["util5h"] as? NSNumber)?.doubleValue
        let util7 = (obj["util7d"] as? NSNumber)?.doubleValue
        let reset7 = (obj["reset7d_ms"] as? NSNumber)?.int64Value
        let src = (obj["source"] as? String) ?? "api"
        if let reset = (obj["reset5h_ms"] as? NSNumber)?.int64Value, reset > nowMs {
            return SessionState(active: true, startMs: reset - Sessions.windowMs, endMs: reset,
                                lastActivityMs: nil, util5h: util5, util7d: util7,
                                reset7dMs: reset7, source: src)
        }
        // Reset has passed (or is null): idle, but keep the utilisation figures.
        return SessionState(active: false, startMs: nil, endMs: nil, lastActivityMs: nil,
                            util5h: util5, util7d: util7, reset7dMs: reset7, source: src)
    }
}

enum Sessions {
    static let windowMs: Int64 = 5 * 3600 * 1000
    static let lookbackS: Double = 36 * 3600

    static func projectsDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects")
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parse(_ ts: String) -> Date? {
        isoFrac.date(from: ts) ?? isoPlain.date(from: ts)
    }

    // Every message timestamp (ms) across all conversation files touched in the
    // lookback, sorted ascending. We need the full set — not just per-file
    // first/last — so the block chain in compute() is correct even when
    // conversations interleave or a single file spans a >5h gap.
    private static func activityTimestamps(now: Date) -> [Int64] {
        let sinceMs = Int64((now.timeIntervalSince1970 - lookbackS) * 1000)
        let dir = projectsDir()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var stamps: [Int64] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip sub-agent files — they inherit the parent session's billing window.
            guard !url.lastPathComponent.hasPrefix("agent-") else { continue }
            let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let m = vals?.contentModificationDate,
               Int64(m.timeIntervalSince1970 * 1000) < sinceMs { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text.enumerateLines { line, _ in
                guard line.contains("\"timestamp\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ts = obj["timestamp"] as? String,
                      let d = parse(ts) else { return }
                let ms = Int64(d.timeIntervalSince1970 * 1000)
                // Ignore stray old timestamps (e.g. a resumed months-old file);
                // the current 5h block always starts within the lookback window
                // because daily sleep gaps (>5h) reset the chain.
                if ms >= sinceMs { stamps.append(ms) }
            }
        }
        stamps.sort()
        return stamps
    }

    static func compute(now: Date = Date()) -> SessionState {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let stamps = activityTimestamps(now: now)
        guard let first = stamps.first else {
            return SessionState(active: false, startMs: nil, endMs: nil, lastActivityMs: nil)
        }
        let lastActivity = stamps.last

        // Chain rolling 5h windows across all activity. A block opens at its
        // first message and runs 5h; the first message after it expires opens
        // the next block. The current block is the last one in the chain.
        var start = first
        var end = start + windowMs
        for ms in stamps where ms > end {
            start = ms
            end = ms + windowMs
        }

        return SessionState(active: nowMs < end, startMs: start, endMs: end, lastActivityMs: lastActivity)
    }
}

// MARK: - Clawd mascot view

/// Draws Clawd — the Claude Code mascot — holding a stopwatch, replicating the
/// reference art. Authored in a 136×100 *top-down* design grid (x → right,
/// y → down) and aspect-fit (letterboxed) into the view bounds, so it never
/// distorts however the cell is sized. Body / side-arms / legs / paw take
/// `tint` (recoloured for urgency); the stopwatch dial stays black-and-white;
/// the squinting ">  <" eyes are near-black.
final class ClawdView: NSView {

    var tint: NSColor = Palette.clay {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    private let WD: CGFloat = 136   // design width  (incl. side arms + stopwatch)
    private let HD: CGFloat = 100   // design height (body top → leg tips)

    override func draw(_ dirtyRect: NSRect) {
        guard NSGraphicsContext.current != nil else { return }

        // Aspect-fit the design grid into bounds, centred.
        let scale = min(bounds.width / WD, bounds.height / HD)
        let ox = (bounds.width  - WD * scale) / 2
        let oy = (bounds.height - HD * scale) / 2

        // top-down design point → view point (flip y; the view is y-up)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: ox + x * scale, y: oy + (HD - y) * scale)
        }
        // rounded rect from a top-down (x, yTop, w, h) box
        func rrect(_ x: CGFloat, _ yTop: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
            let rect = NSRect(x: ox + x * scale,
                              y: oy + (HD - (yTop + h)) * scale,
                              width: w * scale, height: h * scale)
            return NSBezierPath(roundedRect: rect, xRadius: r * scale, yRadius: r * scale)
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
            let c = p(cx, cy)
            return NSBezierPath(ovalIn: NSRect(x: c.x - r * scale, y: c.y - r * scale,
                                               width: 2 * r * scale, height: 2 * r * scale))
        }
        func stroke(_ a: NSPoint, _ b: NSPoint, _ w: CGFloat) {
            let t = NSBezierPath(); t.move(to: a); t.line(to: b)
            t.lineWidth = w * scale; t.lineCapStyle = .round; t.stroke()
        }

        // ── Body + side arms (tint) ───────────────────────────────────────────
        tint.setFill()
        rrect(22, 0, 94, 100, 8).fill()      // full torso block (legs cut below)
        rrect(0,  20, 24, 24, 5).fill()      // left  arm stub
        rrect(112, 20, 24, 24, 5).fill()     // right arm stub

        // ── Foot slots: punch ivory gaps to leave four stubby legs ────────────
        Palette.ivory.setFill()
        for sx0 in [37.5, 63.7, 89.9] as [CGFloat] {
            rrect(sx0, 76, 10.7, 26, 3.5).fill()
        }

        // ── Eyes: ">  <" squint (near-black) ──────────────────────────────────
        Palette.nearBlack.setStroke()
        let eyeW = 6.5 * scale
        func chevron(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) {
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b); path.line(to: c)
            path.lineWidth = eyeW
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            path.stroke()
        }
        chevron(p(38, 10),  p(52, 19.5), p(38, 29.5))     // left  ">"
        chevron(p(100, 10), p(86, 19.5), p(100, 29.5))    // right "<"

        // ── Stopwatch (held at the bottom-right) ──────────────────────────────
        let cx: CGFloat = 111.4, cy: CGFloat = 59.3, R: CGFloat = 16.1

        // Paw first, so the dial overlaps its upper-left edge.
        tint.setFill()
        rrect(120.5, 59, 12, 14, 6).fill()

        // Dial: black ring + white face.
        Palette.nearBlack.setFill(); circle(cx, cy, R).fill()
        NSColor.white.setFill();      circle(cx, cy, R - 3.8).fill()

        // Tick marks at 12 / 3 / 6 / 9.
        Palette.nearBlack.setStroke()
        stroke(p(cx, cy - 14.5), p(cx, cy - 12), 1.6)   // 12
        stroke(p(cx + 14.5, cy), p(cx + 12, cy), 1.6)   // 3
        stroke(p(cx, cy + 14.5), p(cx, cy + 12), 1.6)   // 6
        stroke(p(cx - 14.5, cy), p(cx - 12, cy), 1.6)   // 9

        // Hands (pointing to ~1 o'clock) + centre pivot.
        stroke(p(cx, cy), p(cx + 7, cy - 8.5), 2.0)     // long hand → up-right
        stroke(p(cx, cy), p(cx - 0.5, cy - 6.5), 2.0)   // short hand → up
        Palette.nearBlack.setFill()
        circle(cx, cy, 1.7).fill()                      // pivot

        // Crown / top button.
        rrect(107.4, 34, 8.5, 9.5, 2).fill()            // crown on top (~12 o'clock)
    }
}

// MARK: - Card view

final class DisclosureButton: NSButton {
    var expanded = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let stroke = Palette.nearBlack.withAlphaComponent(isHighlighted ? 0.55 : 0.95)
        stroke.setStroke()

        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.2
        outline.stroke()

        let chevron = NSBezierPath()
        let midX = bounds.midX
        let midY = bounds.midY
        let half: CGFloat = 4
        let offset: CGFloat = 2.5

        if expanded {
            chevron.move(to: NSPoint(x: midX - half, y: midY - 1.5))
            chevron.line(to: NSPoint(x: midX, y: midY + offset))
            chevron.line(to: NSPoint(x: midX + half, y: midY - 1.5))
        } else {
            chevron.move(to: NSPoint(x: midX - half, y: midY + 1.5))
            chevron.line(to: NSPoint(x: midX, y: midY - offset))
            chevron.line(to: NSPoint(x: midX + half, y: midY + 1.5))
        }

        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }
}

final class CardView: NSView {
    let mascot = ClawdView()
    let title = NSTextField(labelWithString: "Claude session")
    let big = NSTextField(labelWithString: "—")
    let sub = NSTextField(labelWithString: "")
    let track = NSView()
    let fill = NSView()
    let weeklyLabel = NSTextField(labelWithString: "Weekly usage")
    let weeklyTrack = NSView()
    let weeklyFill = NSView()
    let disclosure = DisclosureButton(frame: .zero)
    var onToggleWeekly: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        // Solid ivory card — no visual effect view needed.
        layer?.backgroundColor = Palette.ivory.cgColor

        addSubview(mascot)

        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Palette.muted
        addSubview(title)

        big.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        big.textColor = Palette.clay
        addSubview(big)

        sub.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sub.textColor = Palette.muted
        addSubview(sub)

        track.wantsLayer = true
        track.layer?.cornerRadius = 4
        // Progress track: clay at ~12% alpha for a warm faint tint.
        track.layer?.backgroundColor = Palette.clay.withAlphaComponent(0.12).cgColor
        addSubview(track)

        fill.wantsLayer = true
        fill.layer?.cornerRadius = 4
        addSubview(fill)

        weeklyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        weeklyLabel.textColor = Palette.muted
        weeklyLabel.isHidden = true
        addSubview(weeklyLabel)

        weeklyTrack.wantsLayer = true
        weeklyTrack.layer?.cornerRadius = 4
        weeklyTrack.layer?.backgroundColor = Palette.clay.withAlphaComponent(0.12).cgColor
        weeklyTrack.isHidden = true
        addSubview(weeklyTrack)

        weeklyFill.wantsLayer = true
        weeklyFill.layer?.cornerRadius = 4
        weeklyFill.isHidden = true
        addSubview(weeklyFill)

        disclosure.target = self
        disclosure.action = #selector(toggleWeekly)
        addSubview(disclosure)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        let w = bounds.width, h = bounds.height
        // Right half: large mascot. Left column: title, countdown, sub, progress.
        mascot.frame = NSRect(x: w - 98, y: h - 107, width: 90, height: 90)
        let colW = w - 122          // left column ends ~8pt before the mascot
        title.frame = NSRect(x: pad, y: h - 24, width: colW, height: 16)
        big.frame   = NSRect(x: pad, y: h - 64, width: colW, height: 38)
        sub.frame   = NSRect(x: pad, y: h - 86, width: colW + 6, height: 16)
        track.frame = NSRect(x: pad, y: h - 96, width: colW, height: 8)
        weeklyLabel.frame = NSRect(x: pad, y: 42, width: w - pad * 2, height: 16)
        weeklyTrack.frame = NSRect(x: pad, y: 32, width: w - pad * 2, height: 8)
        disclosure.frame = NSRect(x: (w - 17) / 2, y: 5, width: 17, height: 17)
        layoutFill()
        layoutWeeklyFill()
    }

    var progress: CGFloat = 0 {
        didSet {
            layoutFill()
            updateProgressFill()
        }
    }

    var weeklyProgress: CGFloat = 0 {
        didSet {
            layoutWeeklyFill()
            updateWeeklyFill()
        }
    }

    var weeklyExpanded = false {
        didSet {
            weeklyLabel.isHidden = !weeklyExpanded
            weeklyTrack.isHidden = !weeklyExpanded
            weeklyFill.isHidden = !weeklyExpanded
            disclosure.expanded = weeklyExpanded
            needsLayout = true
        }
    }

    /// Setting accent recolours the mascot and countdown text.
    var accent: NSColor = Palette.clay {
        didSet {
            mascot.tint = accent
            big.textColor = accent
        }
    }

    @objc private func toggleWeekly() {
        onToggleWeekly?()
    }

    private func layoutFill() {
        let p = max(0, min(1, progress))
        fill.frame = NSRect(x: track.frame.minX, y: track.frame.minY,
                            width: track.frame.width * p, height: track.frame.height)
    }

    private func layoutWeeklyFill() {
        let p = max(0, min(1, weeklyProgress))
        weeklyFill.frame = NSRect(x: weeklyTrack.frame.minX, y: weeklyTrack.frame.minY,
                                  width: weeklyTrack.frame.width * p,
                                  height: weeklyTrack.frame.height)
    }

    private func usageColor(for progress: CGFloat) -> NSColor {
        let p = max(0, min(1, progress))
        if p <= 0 {
            return .clear
        } else if p <= 0.50 {
            return Palette.progressGreen
        } else if p <= 0.80 {
            return Palette.clay
        }
        return Palette.urgentRed
    }

    private func updateProgressFill() {
        fill.layer?.backgroundColor = usageColor(for: progress).cgColor
    }

    private func updateWeeklyFill() {
        weeklyFill.layer?.backgroundColor = usageColor(for: weeklyProgress).cgColor
    }

    // Left-drag moves the window; right-click shows the menu.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let m = (NSApp.delegate as? AppDelegate)?.contextMenu {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var card: CardView!
    var tick: Timer?
    var poll: Timer?
    var state = SessionState(active: false, startMs: nil, endMs: nil, lastActivityMs: nil)
    var contextMenu: NSMenu!
    var onTop = true

    let defaultsKey = "widgetFrame"
    let weeklyExpandedKey = "weeklyExpanded"
    let collapsedSize = NSSize(width: 264, height: 124)
    let expandedSize = NSSize(width: 264, height: 166)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let weeklyExpanded = UserDefaults.standard.bool(forKey: weeklyExpandedKey)
        let size = weeklyExpanded ? expandedSize : collapsedSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24)

        window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.level = .floating

        card = CardView(frame: NSRect(origin: .zero, size: size))
        card.weeklyExpanded = weeklyExpanded
        card.onToggleWeekly = { [weak self] in self?.toggleWeeklyExpanded() }
        window.contentView = card

        // Restore saved position only — keep the new size so the layout applies.
        if let s = UserDefaults.standard.string(forKey: defaultsKey) {
            window.setFrameOrigin(NSRectFromString(s).origin)
        }
        window.orderFrontRegardless()

        buildMenu()
        refreshData()
        render()

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.render() }
        poll = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshData() }

        NotificationCenter.default.addObserver(self, selector: #selector(saveFrame),
                                               name: NSWindow.didMoveNotification, object: window)
    }

    @objc func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: defaultsKey)
    }

    func buildMenu() {
        contextMenu = NSMenu()
        let top = NSMenuItem(title: "Always on top", action: #selector(toggleTop), keyEquivalent: "")
        top.state = onTop ? .on : .off
        top.target = self
        contextMenu.addItem(top)
        let r = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        contextMenu.addItem(r)
        contextMenu.addItem(.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        contextMenu.addItem(q)
    }

    @objc func toggleTop() {
        onTop.toggle()
        // .floating = always visible above windows; desktop level = pinned to wallpaper.
        if onTop {
            window.level = .floating
        } else {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        }
        contextMenu.item(at: 0)?.state = onTop ? .on : .off
    }

    @objc func refreshNow() { refreshData(); render() }
    @objc func quit() { NSApp.terminate(nil) }

    func toggleWeeklyExpanded() {
        setWeeklyExpanded(!card.weeklyExpanded, animate: true)
    }

    func setWeeklyExpanded(_ expanded: Bool, animate: Bool) {
        guard card.weeklyExpanded != expanded else { return }
        card.weeklyExpanded = expanded
        UserDefaults.standard.set(expanded, forKey: weeklyExpandedKey)

        let targetSize = expanded ? expandedSize : collapsedSize
        var frame = window.frame
        frame.origin.y += frame.height - targetSize.height
        frame.size = targetSize
        window.setFrame(frame, display: true, animate: animate)
    }

    // Prefer the authoritative cache (matches claude.ai). While the poller
    // hasn't caught up yet — e.g. you just started a session — bridge the gap
    // with the transcript estimate so the widget doesn't read "Idle" mid-use.
    func refreshData() {
        let now = Date()
        let cached = UsageCache.load(now: now)
        if let c = cached, c.active { state = c; return }
        let t = Sessions.compute(now: now)
        if t.active { state = t; return }
        state = cached ?? t
    }

    func render() {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if state.active, let end = state.endMs {
            let rem = end - nowMs
            if rem <= 0 { refreshData(); render(); return }
            card.big.stringValue = fmtRemaining(rem)

            if let util = state.util5h {
                // Authoritative: bar + label mirror claude.ai's "% used".
                card.sub.stringValue = "\(pct(util)) used · resets \(fmtClock(end))"
                card.progress = CGFloat(max(0, min(1, util)))
                // Urgency tracks how close you are to the cap, not the clock.
                if util >= 0.90 { card.accent = Palette.urgentRed }
                else if util >= 0.75 { card.accent = Palette.amber }
                else { card.accent = Palette.clay }
            } else {
                // Transcript estimate: flag it, colour by time remaining.
                let start = state.startMs ?? (end - Sessions.windowMs)
                card.sub.stringValue = "resets \(fmtClock(end)) · est"
                card.progress = CGFloat(nowMs - start) / CGFloat(Sessions.windowMs)
                if rem < 15 * 60 * 1000 { card.accent = Palette.urgentRed }
                else if rem < 60 * 60 * 1000 { card.accent = Palette.amber }
                else { card.accent = Palette.clay }
            }
        } else {
            card.big.stringValue = "Idle"
            card.big.textColor = Palette.nearBlack
            card.sub.stringValue = state.util5h != nil
                ? "\(pct(state.util5h!)) used · opens on next message"
                : "opens on your next message"
            card.progress = 0
            // Mascot tinted muted grey in idle state; fill cleared.
            card.mascot.tint = Palette.muted
            fill(card.fill, with: .clear)
        }
        renderWeeklyUsage()
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func renderWeeklyUsage() {
        guard let util = state.util7d else {
            card.weeklyLabel.stringValue = "Weekly usage unavailable"
            card.weeklyProgress = 0
            return
        }
        let reset = state.reset7dMs.map { " · resets \(fmtDayClock($0))" } ?? ""
        card.weeklyLabel.stringValue = "Weekly \(pct(util)) used\(reset)"
        card.weeklyProgress = CGFloat(max(0, min(1, util)))
    }

    private func fill(_ v: NSView, with c: NSColor) {
        v.layer?.backgroundColor = c.cgColor
    }

    // Hh Mm normally; Mm Ss live in the final hour.
    func fmtRemaining(_ ms: Int64) -> String {
        let totalS = Int(ms / 1000)
        let h = totalS / 3600, m = (totalS % 3600) / 60, s = totalS % 60
        if h >= 1 { return "\(h)h \(m)m" }
        return "\(m)m \(String(format: "%02d", s))s"
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    func fmtClock(_ ms: Int64) -> String {
        AppDelegate.clock.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static let dayClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    func fmtDayClock(_ ms: Int64) -> String {
        AppDelegate.dayClock.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

func writeSnapshot(expanded: Bool, to path: String) {
    let size = expanded ? NSSize(width: 264, height: 166) : NSSize(width: 264, height: 124)
    let card = CardView(frame: NSRect(origin: .zero, size: size))
    card.weeklyExpanded = expanded
    card.big.stringValue = "1h 23m"
    card.sub.stringValue = "45% used · resets 22:50"
    card.progress = 0.45
    card.accent = Palette.clay
    card.weeklyLabel.stringValue = "Weekly 32% used · resets Thu 18:00"
    card.weeklyProgress = 0.32
    card.layoutSubtreeIfNeeded()

    guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { return }
    card.cacheDisplay(in: card.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

if CommandLine.arguments.contains("--snapshot") {
    let expanded = CommandLine.arguments.contains("--expanded")
    let path = CommandLine.arguments.last ?? "/tmp/session-widget-snapshot.png"
    writeSnapshot(expanded: expanded, to: path)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
