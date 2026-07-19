import Cocoa
import UserNotifications

// Plan-limit utilization, read from the same /api/oauth/usage endpoint the Claude UI uses.
// Entirely separate from the hook-driven session state: hooks tell us what Claude is DOING,
// this tells us how much of the plan is LEFT. The only account data that leaves the machine
// is the OAuth token, sent to Anthropic (never to us) — see PRIVACY.md.

struct UsageLimit: Codable {
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

// Append-only forensics log for the rate limiter: every fetch attempt with its trigger
// (launch/menu/toggle), outcome (200/429/error), and every suppression with its reason
// (cooldown/hold). All triggers are human-scale (no timer calls refresh), so volume stays tiny.
// Local only, no account data beyond limit counts — see PRIVACY.md.
enum UsageLog {
    // Tests point this at a scratch file so runs don't pollute the real log.
    static var path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/usage.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func log(_ line: String) {
        let entry = "\(stamp.string(from: Date())) \(line)\n"
        let fm = FileManager.default
        // Rotate at 128KB: one .old generation, newest always in usage.log.
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 131072 {
            try? fm.removeItem(atPath: path + ".old")
            try? fm.moveItem(atPath: path, toPath: path + ".old")
        }
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: entry.data(using: .utf8)!)
        }
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

    // Tail (last 8 chars) of a token that answered 401 — never the whole token, and only ever of
    // an already-dead one. Persisted so a relaunch doesn't blindly retry the same dead token.
    private var badTokenTail: String? = UserDefaults.standard.string(forKey: "usageBadTokenTail")

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
        // The last good numbers survive too, so a process born under a rate-limit penalty still
        // shows bars (stale, and labelled as such) instead of a bare "Rate limited" note.
        if let data = UserDefaults.standard.data(forKey: "usageCache"),
           let cached = try? Self.cacheDecoder.decode([UsageLimit].self, from: data), !cached.isEmpty {
            limits = cached
            dataAt = UserDefaults.standard.double(forKey: "usageCacheAt")
        }
        if let rem = retryRemaining {
            UsageLog.log("init: restored 429 hold (\(rem)s left), cache: \(limits.isEmpty ? "none" : "\(limits.count) limits, \(dataAgeText ?? "fresh")")")
        }
        history = Self.loadHistory()
    }

    // Clears a token-related error when a genuinely fresh token has appeared on disk — called
    // from a purely LOCAL check (file + Keychain read, no network) so the "Token expired" note
    // heals itself after a `claude` login without needing a ⟳ press. The badTokenTail guard
    // keeps a still-unexpired-but-401ing token from clearing the note it caused.
    func clearTokenErrorIfFresh(_ token: String) {
        if let bad = badTokenTail, token.hasSuffix(bad) { return }
        if lastError?.hasPrefix("Token") == true || lastError?.hasPrefix("Not signed in") == true {
            lastError = nil
        }
    }

    // When the shown numbers were actually fetched (now for live data, the stored stamp for a
    // restored cache). 0 = never had data.
    private(set) var dataAt: Double = 0

    // "3h old" etc. for the note row — only when the data is old enough that pretending it's
    // current would mislead (past one cooldown-ish window).
    var dataAgeText: String? {
        guard dataAt > 0, hasData else { return nil }
        let age = Int(Date().timeIntervalSince1970 - dataAt)
        guard age > 900 else { return nil }
        if age >= 86400 { return "\(age / 86400)d old" }
        if age >= 3600 { return "\(age / 3600)h old" }
        return "\(age / 60)m old"
    }

    private static let cacheEncoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()
    private static let cacheDecoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()

    var hasData: Bool { !limits.isEmpty }

    // Highest utilization across every limit — drives the menu bar warning badge. Computed from
    // whatever is cached; never triggers a request.
    var worstPercent: Int? { limits.map(\.percent).max() }

    // MARK: history (local only)

    // One line per successful fetch: {"ts": epoch, "p": {"Session": 36, ...}}. Feeds the ~24h
    // delta chips in the rows. Sparse by design — fetches are manual — so deltas are best-effort.
    static var historyPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/usage-history.jsonl")
    private(set) var history: [(ts: Double, percents: [String: Int])] = []

    static func loadHistory() -> [(ts: Double, percents: [String: Int])] {
        guard let raw = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = (obj["ts"] as? NSNumber)?.doubleValue,
                  let p = obj["p"] as? [String: NSNumber] else { return nil }
            return (ts, p.mapValues { $0.intValue })
        }
    }

    private func recordHistory(_ parsed: [UsageLimit], at ts: Double) {
        let entry: [String: Any] = ["ts": ts, "p": Dictionary(uniqueKeysWithValues: parsed.map { ($0.label, $0.percent) })]
        history.append((ts, entry["p"] as! [String: Int]))
        guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        // Append; rewrite keeping the newest 500 once past 1000 so the file can't grow unbounded.
        if history.count > 1000 {
            history = Array(history.suffix(500))
            let lines = history.compactMap { h -> String? in
                guard let d = try? JSONSerialization.data(withJSONObject: ["ts": h.ts, "p": h.percents]) else { return nil }
                return String(data: d, encoding: .utf8)
            }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: Self.historyPath, atomically: true, encoding: .utf8)
        } else if let fh = FileHandle(forWritingAtPath: Self.historyPath) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data + Data("\n".utf8))
        } else {
            try? (String(data: data, encoding: .utf8)! + "\n").write(toFile: Self.historyPath, atomically: true, encoding: .utf8)
        }
    }

    // Change vs ~24h ago (nearest snapshot 20–28h back). Nil when history doesn't reach that far,
    // or the label wasn't recorded then (e.g. a model-scoped cap that appeared today).
    func dayDelta(for label: String, percent: Int, now: Double = Date().timeIntervalSince1970) -> Int? {
        let candidates = history.filter { now - $0.ts >= 20 * 3600 && now - $0.ts <= 28 * 3600 }
        guard let best = candidates.min(by: { abs(now - $0.ts - 86400) < abs(now - $1.ts - 86400) }),
              let old = best.percents[label] else { return nil }
        let d = percent - old
        return d == 0 ? nil : d
    }

    // MARK: export (local only)

    // Machine-readable snapshot for tmux/sketchybar/scripts — written on every successful fetch,
    // never read by the app itself. Consumers poll the FILE, so they cost zero requests.
    static var exportPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/usage-latest.json")

    private static let isoOut: ISO8601DateFormatter = ISO8601DateFormatter()

    private func writeExport(_ parsed: [UsageLimit], at ts: Double) {
        let obj: [String: Any] = [
            "fetched_at": Self.isoOut.string(from: Date(timeIntervalSince1970: ts)),
            "limits": parsed.map { l -> [String: Any] in
                var row: [String: Any] = ["label": l.label, "percent": l.percent, "severity": l.severity]
                if let r = l.resetsAt { row["resets_at"] = Self.isoOut.string(from: r) }
                return row
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.exportPath), options: .atomic)
    }

    // Poll cadence is generous: utilization moves in percent points over minutes, and the
    // dropdown refreshes on open anyway, so anything tighter is wasted requests.
    func refreshIfStale(maxAge: Double = 120, trigger: String = "?") {
        let age = Date().timeIntervalSince1970 - lastFetch
        if age < maxAge {
            UsageLog.log("\(trigger): skip (cooldown, \(Int(maxAge - age))s left)")
            return
        }
        refresh(trigger: trigger)
    }

    func refresh(trigger: String = "?") {
        if inFlight { return }
        if let rem = retryRemaining {
            UsageLog.log("\(trigger): skip (429 hold, \(rem)s left)")
            return
        }
        // Re-read the token on every fetch instead of caching it: Claude Code rotates the OAuth
        // token and may rewrite its stored credentials at any time.
        //
        // Resolution MUST leave the main thread first. The Keychain read can block on the
        // system permission dialog (SecurityAgent), and the ⟳ press arrives mid menu-tracking:
        // with the main thread stuck inside SecItemCopyMatching, both the menu and the dialog
        // freeze and the password field can't take keystrokes (observed). Off the main thread,
        // the dialog activating dismisses the menu normally and types fine.
        inFlight = true
        DispatchQueue.global().async { [weak self] in
            let state = Self.loadToken()
            DispatchQueue.main.async { self?.continueRefresh(with: state, trigger: trigger) }
        }
    }

    // Main-thread continuation once credentials are resolved. Every path that does NOT start a
    // network request must clear inFlight — it was set optimistically before the async hop.
    private func continueRefresh(with tokenState: TokenState, trigger: String) {
        let token: String
        switch tokenState {
        case .valid(let t):
            token = t
        case .expired:
            // Every stored token is past its expiresAt. Do NOT fire: the 401 would feed the
            // auth-failure throttle (one 401 earned the next request a 60-minute 429). Keep the
            // cache — the account is still signed in, credentials just haven't rotated yet.
            // lastFetch is left alone so the next menu open re-checks immediately; recovery is
            // automatic the moment Claude Code writes a fresh token.
            UsageLog.log("\(trigger): skip (stored tokens expired; waiting for Claude Code to rotate)")
            inFlight = false
            lastError = "Token expired — start a Claude Code session to refresh it"
            onUpdate?()
            return
        case .missing:
            UsageLog.log("\(trigger): no token (not signed in)")
            inFlight = false
            limits = []
            dataAt = 0
            lastError = "Not signed in to Claude Code"
            lastFetch = Date().timeIntervalSince1970
            // Signed out: drop the persisted snapshot too, or a later sign-in under a different
            // account would resurrect the previous account's numbers.
            UserDefaults.standard.removeObject(forKey: "usageCache")
            UserDefaults.standard.removeObject(forKey: "usageCacheAt")
            onUpdate?()
            return
        }
        // Belt-and-braces for tokens that die BEFORE their expiresAt (revocation, clock skew):
        // after a 401, never retry the exact token that failed — wait for a different one.
        if let bad = badTokenTail, token.hasSuffix(bad) {
            UsageLog.log("\(trigger): skip (token unchanged since last 401)")
            inFlight = false
            lastError = "Token expired — start a Claude Code session to refresh it"
            onUpdate?()
            return
        }
        guard let url = URL(string: endpoint) else { inFlight = false; return }
        let started = Date()
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
                // The token died before its expiresAt (revoked/rotated server-side). Recover when
                // a fresh one appears; the badTokenTail gate stops repeats meanwhile. The advice
                // depends on where the dead token came from.
                // A 403 on a well-formed setup-token file means that token CLASS can't read this
                // endpoint (observed) — retrying or recreating it won't help; the file must go.
                failure = Self.lastTokenSource == "token file"
                    ? "Token file not accepted here — delete ~/.claude/statusbar/token"
                    : "Token expired — start a Claude Code session to refresh it"
            } else if code != 200 {
                failure = "Usage unavailable (HTTP \(code))"
            } else if let data = data {
                parsed = Self.parse(data)
                if parsed == nil { failure = "Unexpected usage response" }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if let err = err {
                UsageLog.log("\(trigger): request FAILED in \(ms)ms — \(err.localizedDescription)")
            } else if code == 429 {
                UsageLog.log("\(trigger): 429 in \(ms)ms, retry-after=\(Int(holdFor))s")
            } else if code == 200 {
                UsageLog.log("\(trigger): 200 in \(ms)ms (\(parsed?.count ?? 0) limits\(parsed == nil ? ", PARSE FAILED" : ""))")
            } else {
                UsageLog.log("\(trigger): HTTP \(code) in \(ms)ms")
            }
            DispatchQueue.main.async {
                self.inFlight = false
                self.lastFetch = Date().timeIntervalSince1970
                if holdFor > 0 {
                    self.retryAfter = self.lastFetch + holdFor
                    UserDefaults.standard.set(self.retryAfter, forKey: "usageRetryUntil")
                }
                if code == 401 || code == 403 {
                    self.badTokenTail = String(token.suffix(8))
                    UserDefaults.standard.set(self.badTokenTail, forKey: "usageBadTokenTail")
                }
                if let parsed = parsed {
                    self.limits = parsed
                    self.lastError = nil
                    self.dataAt = self.lastFetch
                    self.badTokenTail = nil
                    UserDefaults.standard.removeObject(forKey: "usageRetryUntil")
                    UserDefaults.standard.removeObject(forKey: "usageBadTokenTail")
                    if let enc = try? Self.cacheEncoder.encode(parsed) {
                        UserDefaults.standard.set(enc, forKey: "usageCache")
                        UserDefaults.standard.set(self.dataAt, forKey: "usageCacheAt")
                    }
                    self.recordHistory(parsed, at: self.dataAt)
                    self.writeExport(parsed, at: self.dataAt)
                    if UserDefaults.standard.object(forKey: "alertHighUsage") as? Bool ?? true {
                        UsageAlerts.check(parsed)
                    }
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

    // Expired and absent are DIFFERENT states: absent means signed out (drop the cache), expired
    // means Claude Code just hasn't rotated its stored credentials yet (keep everything, fire no
    // request, recover the moment a fresh token appears).
    enum TokenState {
        case valid(String)
        case expired
        case missing
    }

    // Opt-in long-lived token file (from `claude setup-token`). Checked before the shared
    // credentials, so once it exists the Keychain is never touched — which is the whole point:
    // Claude Code recreates its Keychain item on every login, wiping the "Always Allow" grant,
    // so the permission dialog otherwise returns after each re-auth. A plain token file has no
    // ACL to lose. Same protection model as ~/.claude/.credentials.json (0600, plaintext).
    static var tokenFilePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/token")

    // Which source produced the current token — lets a 401 say the right thing ("re-run
    // claude setup-token" vs "start a Claude Code session").
    private(set) static var lastTokenSource = ""

    // Same resolution order Claude Code itself uses, cheapest first — but expiry-checked. Firing
    // a request with an expired token is worse than useless: the 401 feeds an auth-failure
    // throttle that answered our very next request with a 60-minute 429 (see usage.log).
    static func loadToken() -> TokenState {
        if let t = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !t.isEmpty {
            lastTokenSource = "env"
            return .valid(t)
        }
        if let raw = try? String(contentsOfFile: tokenFilePath, encoding: .utf8) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                lastTokenSource = "token file"
                return .valid(t)
            }
        }
        var sawExpired = false
        for (source, data) in [("credentials file", credentialsFileData()), ("keychain", keychainData())] {
            guard let data = data else { continue }
            switch token(fromCredentialsJSON: data) {
            case .valid(let t):
                lastTokenSource = source
                return .valid(t)
            case .expired: sawExpired = true
            case .missing: break
            }
        }
        return sawExpired ? .expired : .missing
    }

    private static func credentialsFileData() -> Data? {
        FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/.credentials.json")
    }

    // Claude Code stores the same JSON blob as a generic keychain item on macOS when the
    // credentials file isn't used.
    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    // Internal (not private) so the expiry logic is testable with synthetic JSON.
    static func token(fromCredentialsJSON data: Data) -> TokenState {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return .missing }
        if let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            // Observed in milliseconds (1.78e12); tolerate seconds (1.78e9) in case that changes.
            let expSecs = exp > 1e11 ? exp / 1000 : exp
            if expSecs < Date().timeIntervalSince1970 { return .expired }
        }
        return .valid(tok)
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

    func configure(_ limit: UsageLimit, dayDelta: Int? = nil) {
        // Label in the normal color, the reset countdown dimmed after it — same treatment the
        // session rows give "name · branch", so the two sections read as one list.
        let font = NSFont.menuFont(ofSize: 0)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.allowsDefaultTighteningForTruncation = false
        let text = NSMutableAttributedString(string: limit.label, attributes: [
            .font: font, .paragraphStyle: para, .foregroundColor: NSColor.labelColor,
        ])
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: font.pointSize - 2),
            .paragraphStyle: para, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let reset = limit.resetText
        if !reset.isEmpty { text.append(NSAttributedString(string: " · " + reset, attributes: small)) }
        // ~24h change, when history reaches that far: "▲12" = twelve points more used than
        // yesterday. Same dimmed style as the reset — informational, not an alarm.
        if let d = dayDelta {
            text.append(NSAttributedString(string: " · \(d > 0 ? "▲" : "▼")\(abs(d))", attributes: small))
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

// High-usage alerts, piggybacked on user-triggered fetches — this file never initiates a
// request. One notification per (limit, reset window): the same limit re-crossing 90% inside
// the same window stays quiet, but fires again after its reset.
enum UsageAlerts {
    static let threshold = 90

    // Pure dedupe logic, separated so it's testable without touching UNUserNotificationCenter.
    static func dueAlerts(_ limits: [UsageLimit], seen: [String: Double]) -> (due: [UsageLimit], seen: [String: Double]) {
        var seen = seen, due: [UsageLimit] = []
        for l in limits where l.percent >= threshold {
            let window = l.resetsAt?.timeIntervalSince1970 ?? 0
            if seen[l.label] == window { continue }
            seen[l.label] = window
            due.append(l)
        }
        return (due, seen)
    }

    static func check(_ limits: [UsageLimit]) {
        let d = UserDefaults.standard
        let prior = (d.dictionary(forKey: "usageAlerted") as? [String: Double]) ?? [:]
        let (due, seen) = dueAlerts(limits, seen: prior)
        guard !due.isEmpty else { return }
        d.set(seen, forKey: "usageAlerted")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err { UsageLog.log("alert: authorization error — \(err.localizedDescription)"); return }
            guard granted else { UsageLog.log("alert: notifications not authorized"); return }
            for l in due {
                let content = UNMutableNotificationContent()
                content.title = "Claude usage at \(l.percent)%"
                content.body = "\(l.label) — \(l.resetText)"
                center.add(UNNotificationRequest(identifier: "usage-\(l.label)", content: content, trigger: nil)) { e in
                    UsageLog.log("alert: \(l.label) \(l.percent)% \(e == nil ? "delivered" : "FAILED — \(e!.localizedDescription)")")
                }
            }
        }
    }
}

// Section header with a refresh button: "Usage" on the left, ⟳ on the right. The button is the
// ONLY thing that fires a usage request from the menu — opening the dropdown alone never does,
// so opening it to flip a setting costs nothing. Same 30s cooldown as before, enforced by the
// monitor, so mashing the button can't burst.
final class UsageHeaderView: NSView {
    var onRefresh: (() -> Void)?
    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusField = NSTextField(labelWithString: "")
    private var statusGeneration = 0   // invalidates a pending auto-clear when new text arrives

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        autoresizingMask = [.width]
        let label = NSTextField(labelWithString: "Usage")
        label.font = NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: 14, y: (22 - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        addSubview(label)

        // Transient feedback ("try again in 12s", "updated") pinned just left of the button —
        // the note ROW can't be added mid-tracking, but text inside this view can change freely.
        statusField.font = NSFont.systemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 3)
        statusField.textColor = .secondaryLabelColor
        statusField.alignment = .right
        statusField.lineBreakMode = .byClipping
        statusField.frame = NSRect(x: width - 14 - 20 - 6 - 170, y: 3, width: 170, height: 15)
        statusField.autoresizingMask = [.minXMargin]
        addSubview(statusField)

        button.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh usage")
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(clicked)
        button.frame = NSRect(x: width - 14 - 20, y: 1, width: 20, height: 20)
        button.autoresizingMask = [.minXMargin]
        addSubview(button)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: width - 14 - 18, y: 3, width: 16, height: 16)
        spinner.autoresizingMask = [.minXMargin]
        addSubview(spinner)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clicked() { onRefresh?() }

    func showStatus(_ text: String) {
        statusGeneration += 1
        let gen = statusGeneration
        statusField.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.statusGeneration == gen else { return }
            self.statusField.stringValue = ""
        }
    }

    // Press feedback: the arrow swaps for the native small spinner while the request runs.
    // The safety timeout covers a completion that never fires (it shouldn't, but a stuck
    // spinner reads as a hang). Generous because the fetch may legitimately sit waiting on the
    // Keychain permission dialog while the user types their password.
    func beginSpin() {
        button.isHidden = true
        spinner.startAnimation(nil)
        statusGeneration += 1
        statusField.stringValue = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.endSpin(status: nil) }
    }

    func endSpin(status: String?) {
        spinner.stopAnimation(nil)
        button.isHidden = false
        if let status = status { showStatus(status) }
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
