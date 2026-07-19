import Cocoa

// Plan-limit utilization, read from the same /api/oauth/usage endpoint the Claude UI uses.
// Entirely separate from the hook-driven session state: hooks tell us what Claude is DOING,
// this tells us how much of the plan is LEFT. The only account data that leaves the machine
// is the OAuth token, sent to Anthropic (never to us) — see PRIVACY.md.

struct UsageLimit {
    let label: String
    let percent: Int
    let resetsAt: Date?
    let severity: String   // "normal" | "warning" | "critical" (API-supplied)

    // Bar/percentage color. The API's severity wins when it flags something, so a plan whose
    // thresholds differ from ours still lights up correctly; otherwise fall back to percent.
    var color: NSColor {
        switch severity {
        case "critical": return .systemRed
        case "warning": return .systemOrange
        default: break
        }
        if percent >= 90 { return .systemRed }
        if percent >= 75 { return .systemOrange }
        return .systemGreen
    }

    // "resets in 2h 14m" / "resets in 3d" — relative, because the absolute timestamp means
    // nothing at a glance and the reset is always the thing you actually want to know.
    var resetText: String {
        guard let r = resetsAt else { return "" }
        let secs = Int(r.timeIntervalSinceNow)
        if secs <= 0 { return "resetting…" }
        let m = secs / 60, h = m / 60, d = h / 24
        if d >= 1 { return "resets in \(d)d \(h % 24)h" }
        if h >= 1 { return "resets in \(h)h \(m % 60)m" }
        return "resets in \(m)m"
    }
}

final class UsageMonitor {
    private(set) var limits: [UsageLimit] = []
    private(set) var lastError: String?
    private(set) var lastFetch: Double = 0
    private var inFlight = false
    // The endpoint is rate limited and answers 429 with a Retry-After. The penalty ESCALATES:
    // observed 161s on a first offense, 1671s after requests kept arriving during the window. So
    // honouring the deadline isn't just politeness — retrying into the penalty makes it longer.
    // Hold every request until the server's own deadline passes.
    private var retryAfter: Double = 0

    // Seconds left on the 429 hold, or nil when not held. The UI renders the countdown from this
    // at menu-open time rather than from a stored message, so the number is live, and its
    // disappearance (rather than a stale error string) is what ends the note.
    var retryRemaining: Int? {
        let r = Int((retryAfter - Date().timeIntervalSince1970).rounded())
        return r > 0 ? r : nil
    }

    // Called on the main thread whenever a fetch lands, so an open menu can redraw in place.
    var onUpdate: (() -> Void)?

    private let endpoint: String

    // The override exists for tests (point it at a local mock and exercise the 429 path without
    // touching — and escalating — the real endpoint's rate limit).
    init(endpoint: String = "https://api.anthropic.com/api/oauth/usage") {
        self.endpoint = endpoint
        // The hold MUST survive the process: the penalty escalates server-side, and app relaunches
        // are exactly when a blind launch fetch would fire into it. Without persistence, every
        // quit-and-revive cycle extended the penalty (observed climbing 161s → 1671s → 60m).
        retryAfter = UserDefaults.standard.double(forKey: "usageRetryUntil")
    }

    var hasData: Bool { !limits.isEmpty }

    // Poll cadence is generous: utilization moves in percent points over minutes, and the
    // dropdown refreshes on open anyway, so anything tighter is wasted requests.
    func refreshIfStale(maxAge: Double = 120) {
        if Date().timeIntervalSince1970 - lastFetch < maxAge { return }
        refresh()
    }

    func refresh() {
        if inFlight { return }
        if Date().timeIntervalSince1970 < retryAfter { return }
        // Re-read the token on every fetch instead of caching it: Claude Code rotates the OAuth
        // token roughly hourly and rewrites the credentials file, so a cached copy goes 401 stale.
        guard let token = Self.loadToken() else {
            limits = []
            lastError = "Not signed in to Claude Code"
            lastFetch = Date().timeIntervalSince1970
            onUpdate?()
            return
        }
        guard let url = URL(string: endpoint) else { return }
        inFlight = true
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("ClaudeStatusBar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            var parsed: [UsageLimit]?
            var failure: String?
            var holdFor: Double = 0
            if let err = err {
                failure = err.localizedDescription
            } else if code == 429 {
                // Fall back to a minute if the header is missing/unparseable, so a 429 without
                // Retry-After still backs off instead of retrying on the very next open.
                // No failure string: the hold note is rendered live from retryRemaining, so it
                // counts down and vanishes on its own instead of lingering frozen.
                holdFor = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            } else if code == 401 || code == 403 {
                // Expired/rotated token — the next poll re-reads the file, which Claude Code
                // will have refreshed by then, so this is transient rather than fatal.
                failure = "Token expired — reopen Claude Code"
            } else if code != 200 {
                failure = "Usage unavailable (HTTP \(code))"
            } else if let data = data {
                parsed = Self.parse(data)
                if parsed == nil { failure = "Unexpected usage response" }
            }
            DispatchQueue.main.async {
                self.inFlight = false
                self.lastFetch = Date().timeIntervalSince1970
                if holdFor > 0 {
                    self.retryAfter = self.lastFetch + holdFor
                    UserDefaults.standard.set(self.retryAfter, forKey: "usageRetryUntil")
                }
                if let parsed = parsed {
                    self.limits = parsed
                    self.lastError = nil
                    UserDefaults.standard.removeObject(forKey: "usageRetryUntil")
                } else if holdFor > 0 {
                    self.lastError = nil   // 429: retryRemaining carries the note instead
                } else {
                    self.lastError = failure ?? "Usage unavailable"
                    // Keep the last good numbers on screen rather than blanking the section;
                    // they're still roughly true and a flicker to empty reads as a bug.
                }
                self.onUpdate?()
            }
        }.resume()
    }

    // MARK: parsing

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        if let d = isoParser.date(from: s) { return d }
        // Same string without fractional seconds — the field isn't guaranteed to carry them.
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    static func parse(_ data: Data) -> [UsageLimit]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Preferred shape: the `limits` array. It's the only place model-scoped caps (e.g. a
        // separate weekly Fable limit) appear with a display name, and it grows server-side
        // without a client change.
        if let rows = obj["limits"] as? [[String: Any]], !rows.isEmpty {
            let out: [UsageLimit] = rows.compactMap { row in
                guard let percent = (row["percent"] as? NSNumber)?.intValue else { return nil }
                let kind = row["kind"] as? String ?? ""
                var label: String
                switch kind {
                case "session":     label = "Session"
                case "weekly_all":  label = "Weekly"
                case "weekly_scoped": label = "Weekly"
                default:            label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                // Scoped rows carry the model (and sometimes surface) the cap applies to.
                if let scope = row["scope"] as? [String: Any] {
                    if let model = scope["model"] as? [String: Any],
                       let name = model["display_name"] as? String, !name.isEmpty {
                        label += " · \(name)"
                    }
                    if let surface = scope["surface"] as? [String: Any],
                       let name = surface["display_name"] as? String, !name.isEmpty {
                        label += " · \(name)"
                    }
                }
                return UsageLimit(label: label, percent: percent, resetsAt: date(row["resets_at"]),
                                  severity: row["severity"] as? String ?? "normal")
            }
            if !out.isEmpty { return out }
        }

        // Fallback for older/leaner responses that only carry the two flat blocks.
        var out: [UsageLimit] = []
        for (key, label) in [("five_hour", "Session"), ("seven_day", "Weekly")] {
            guard let blk = obj[key] as? [String: Any],
                  let util = (blk["utilization"] as? NSNumber)?.doubleValue else { continue }
            out.append(UsageLimit(label: label, percent: Int(util.rounded()),
                                  resetsAt: date(blk["resets_at"]), severity: "normal"))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: token

    // Same resolution order Claude Code itself uses, cheapest first.
    static func loadToken() -> String? {
        if let t = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !t.isEmpty { return t }
        if let t = tokenFromCredentialsFile() { return t }
        return tokenFromKeychain()
    }

    private static func tokenFromCredentialsFile() -> String? {
        let path = NSHomeDirectory() + "/.claude/.credentials.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return token(fromCredentialsJSON: data)
    }

    // Claude Code stores the same JSON blob as a generic keychain item on macOS when the
    // credentials file isn't used.
    private static func tokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return token(fromCredentialsJSON: data)
    }

    private static func token(fromCredentialsJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
        return tok
    }
}

// A usage row: label on the left, percent on the right, thin capsule bar underneath spanning
// the row. Non-interactive (nothing to click), so unlike SessionRowView it draws no hover state.
final class UsageRowView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private let barTrack = NSView()
    private let barFill = NSView()
    private let pad: CGFloat = 14, rowH: CGFloat = 34, barH: CGFloat = 4

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]

        let font = NSFont.menuFont(ofSize: 0)
        labelField.font = font
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = NSRect(x: pad, y: rowH - 18, width: width - pad * 2 - 46, height: 16)
        labelField.autoresizingMask = [.width]
        addSubview(labelField)

        // Mono so the digits don't shuffle horizontally as the number ticks between widths.
        percentField.font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .medium)
        percentField.alignment = .right
        percentField.frame = NSRect(x: width - pad - 44, y: rowH - 18, width: 44, height: 16)
        percentField.autoresizingMask = [.minXMargin]
        addSubview(percentField)

        barTrack.wantsLayer = true
        barTrack.layer?.cornerRadius = barH / 2
        barTrack.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        barTrack.frame = NSRect(x: pad, y: 8, width: width - pad * 2, height: barH)
        barTrack.autoresizingMask = [.width]
        addSubview(barTrack)

        barFill.wantsLayer = true
        barFill.layer?.cornerRadius = barH / 2
        barFill.frame = NSRect(x: 0, y: 0, width: 0, height: barH)
        barTrack.addSubview(barFill)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ limit: UsageLimit) {
        // Label in the normal color, the reset countdown dimmed after it — same treatment the
        // session rows give "name · branch", so the two sections read as one list.
        let font = NSFont.menuFont(ofSize: 0)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.allowsDefaultTighteningForTruncation = false
        let text = NSMutableAttributedString(string: limit.label, attributes: [
            .font: font, .paragraphStyle: para, .foregroundColor: NSColor.labelColor,
        ])
        let reset = limit.resetText
        if !reset.isEmpty {
            text.append(NSAttributedString(string: " · " + reset, attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize - 2),
                .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        labelField.attributedStringValue = text
        percentField.stringValue = "\(limit.percent)%"
        percentField.textColor = limit.percent >= 75 ? limit.color : .secondaryLabelColor
        barFill.layer?.backgroundColor = limit.color.cgColor
        needsLayout = true
        layoutBar(percent: limit.percent)
    }

    private var lastPercent = 0
    private func layoutBar(percent: Int) {
        lastPercent = percent
        let w = barTrack.bounds.width
        let frac = min(1.0, max(0.0, Double(percent) / 100.0))
        // Floor at the bar height so a 1% sliver still renders as a dot rather than nothing.
        let fillW = frac == 0 ? 0 : max(barH, w * CGFloat(frac))
        barFill.frame = NSRect(x: 0, y: 0, width: fillW, height: barH)
    }

    override func layout() {
        super.layout()
        layoutBar(percent: lastPercent)   // the track autoresizes with the menu; the fill doesn't
    }
}

// One-line rows for the section's non-bar states (loading / error), styled like a disabled
// menu item so they read as status rather than as something clickable.
func usageNoteRow(_ text: String, width: CGFloat) -> NSMenuItem {
    let h: CGFloat = 22
    let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
    row.autoresizingMask = [.width]
    let f = NSTextField(labelWithString: text)
    f.font = .menuFont(ofSize: 0)
    f.textColor = .secondaryLabelColor
    f.lineBreakMode = .byTruncatingTail
    f.frame = NSRect(x: 14, y: (h - 16) / 2, width: width - 28, height: 16)
    f.autoresizingMask = [.width]
    row.addSubview(f)
    let item = NSMenuItem()
    item.view = row
    return item
}
