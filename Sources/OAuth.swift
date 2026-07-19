import Cocoa
import CryptoKit
import Network

// App-owned Claude sign-in: authorization-code + PKCE against the same public OAuth client
// Claude Code uses. The app holds ITS OWN token pair and refreshes it itself, so it never reads
// another app's Keychain item — which is what every permission dialog was about. Tokens live in
// a 0600 JSON file: the same protection model as ~/.claude/.credentials.json, and deliberately
// NOT the Keychain (an app-owned Keychain item would re-prompt whenever the ad-hoc signature
// changes; a file has no ACL to lose).
//
// NOTE: this mirrors Claude Code's own flow rather than a documented public API. If the flow
// changes upstream, this file is the whole blast radius.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeBase = "https://claude.ai/oauth/authorize"
    static var tokenURL = "https://console.anthropic.com/v1/oauth/token"   // var: tests aim it at a mock
    static var callbackPort: UInt16 = 54545                                // var: tests bind an ephemeral port
    // Mirror Claude Code's scope set exactly: those tokens are proven to satisfy /api/oauth/usage
    // (a narrower setup-token was answered with 403).
    static let scopes = "org:create_api_key user:profile user:inference"
    static var storePath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/oauth.json")

    struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
    }

    // MARK: store

    static func loadSession() -> Session? {
        guard let data = FileManager.default.contents(atPath: storePath),
              let s = try? JSONDecoder().decode(Session.self, from: data), !s.accessToken.isEmpty else { return nil }
        return s
    }

    static func save(_ s: Session) {
        let dir = (storePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storePath)
    }

    static func signOut() {
        try? FileManager.default.removeItem(atPath: storePath)
    }

    // Cheap, network-free: is there a session a ⟳ press could use (fresh, or refreshable)?
    static var hasUsableSession: Bool {
        guard let s = loadSession() else { return false }
        return s.expiresAt > Date().timeIntervalSince1970 + 60 || !s.refreshToken.isEmpty
    }

    // Force the next usableAccessToken() to refresh (used after a 401 on an own token: the
    // access token is dead server-side even if its clock says otherwise).
    static func forceExpire() {
        guard var s = loadSession() else { return }
        s.expiresAt = 0
        save(s)
    }

    // Ready-to-use access token, refreshing synchronously when needed. NETWORK on the refresh
    // path — call off the main thread, and only from a user-triggered fetch.
    static func usableAccessToken() -> String? {
        guard var s = loadSession() else { return nil }
        if s.expiresAt > Date().timeIntervalSince1970 + 60 { return s.accessToken }
        guard !s.refreshToken.isEmpty else { return nil }
        let started = Date()
        let result = postToken(["grant_type": "refresh_token", "client_id": clientID, "refresh_token": s.refreshToken])
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        switch result {
        case .success(let fresh):
            s = fresh
            save(s)
            UsageLog.log("oauth: refreshed own session in \(ms)ms")
            return s.accessToken
        case .rejected(let code):
            // The refresh token itself was refused — the session is dead, show "Sign in" again.
            UsageLog.log("oauth: refresh REJECTED (HTTP \(code)) in \(ms)ms — signing out")
            signOut()
            return nil
        case .transient(let why):
            // Network trouble: keep the session, fail this attempt, let the legacy chain try.
            UsageLog.log("oauth: refresh failed transiently in \(ms)ms — \(why)")
            return nil
        }
    }

    // MARK: token endpoint

    enum TokenResult {
        case success(Session)
        case rejected(Int)     // 4xx: the grant is bad — don't retry with the same material
        case transient(String) // network/5xx: try again later
    }

    static func postToken(_ body: [String: String]) -> TokenResult {
        guard let url = URL(string: tokenURL),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return .transient("bad request") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        var out: TokenResult = .transient("no response")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { out = .transient(err.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data = data else {
                out = (400...499).contains(code) ? .rejected(code) : .transient("HTTP \(code)")
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty else {
                out = .transient("unparseable token response")
                return
            }
            let refresh = obj["refresh_token"] as? String ?? ""
            let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            // 5-minute safety margin so we refresh before the server-side cliff, not after.
            out = .success(Session(accessToken: access, refreshToken: refresh,
                                   expiresAt: Date().timeIntervalSince1970 + max(600, expiresIn) - 300))
        }.resume()
        sem.wait()
        return out
    }

    // MARK: PKCE

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    // MARK: interactive sign-in flow

    // One sign-in attempt: local callback listener + PKCE material + the code exchange. The
    // browser does the actual authentication; this object just catches the redirect.
    final class Flow {
        private let verifier = ClaudeOAuth.makeVerifier()
        private let state = ClaudeOAuth.makeVerifier()
        private var listener: NWListener?
        private var finished = false
        var onDone: ((String?) -> Void)?   // main thread; nil = signed in

        var redirectURI: String { "http://localhost:\(ClaudeOAuth.callbackPort)/callback" }

        func authorizeURL() -> URL {
            var c = URLComponents(string: ClaudeOAuth.authorizeBase)!
            c.queryItems = [
                .init(name: "code", value: "true"),
                .init(name: "client_id", value: ClaudeOAuth.clientID),
                .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "scope", value: ClaudeOAuth.scopes),
                .init(name: "code_challenge", value: ClaudeOAuth.challenge(for: verifier)),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "state", value: state),
            ]
            return c.url!
        }

        func start() throws {
            let l = try NWListener(using: .init(tls: nil), on: NWEndpoint.Port(rawValue: ClaudeOAuth.callbackPort)!)
            listener = l
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    guard let self = self, let data = data,
                          let head = String(data: data, encoding: .utf8)?.split(separator: "\r\n").first else {
                        conn.cancel(); return
                    }
                    self.handle(requestLine: String(head), conn: conn)
                }
            }
            l.start(queue: .main)
            // Abandon a flow nobody completes; frees the port for a later attempt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in self?.finish("Sign-in timed out") }
            UsageLog.log("signin: waiting for browser callback on port \(ClaudeOAuth.callbackPort)")
        }

        private func handle(requestLine: String, conn: NWConnection) {
            // "GET /callback?code=...&state=... HTTP/1.1"
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else { conn.cancel(); return }
            guard comps.path == "/callback" else { respond(conn, body: "Not found", status: "404 Not Found"); return }
            let q = { (n: String) in comps.queryItems?.first(where: { $0.name == n })?.value }
            guard let code = q("code"), q("state") == state else {
                respond(conn, body: "<h3>Sign-in rejected (state mismatch or missing code).</h3>", status: "400 Bad Request")
                finish("Callback state mismatch")
                return
            }
            respond(conn, body: "<h3>Signed in — you can close this tab. 🎉</h3><p>Claude Status Bar is fetching your usage.</p>")
            let verifier = self.verifier, redirect = self.redirectURI, st = self.state
            DispatchQueue.global().async { [weak self] in
                let result = ClaudeOAuth.postToken([
                    "grant_type": "authorization_code", "client_id": ClaudeOAuth.clientID,
                    "code": code, "redirect_uri": redirect, "code_verifier": verifier, "state": st,
                ])
                DispatchQueue.main.async {
                    switch result {
                    case .success(let s):
                        ClaudeOAuth.save(s)
                        UsageLog.log("signin: success, own session stored")
                        self?.finish(nil)
                    case .rejected(let c):
                        UsageLog.log("signin: exchange REJECTED (HTTP \(c))")
                        self?.finish("Sign-in rejected (HTTP \(c))")
                    case .transient(let why):
                        UsageLog.log("signin: exchange failed — \(why)")
                        self?.finish("Sign-in failed: \(why)")
                    }
                }
            }
        }

        private func respond(_ conn: NWConnection, body: String, status: String = "200 OK") {
            let html = "<html><body style='font-family:sans-serif;margin:3em'>\(body)</body></html>"
            let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data((head + html).utf8), completion: .contentProcessed { _ in conn.cancel() })
        }

        private func finish(_ error: String?) {
            guard !finished else { return }
            finished = true
            listener?.cancel()
            listener = nil
            onDone?(error)
        }
    }
}
