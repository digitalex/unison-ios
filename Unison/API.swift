import Foundation

/// A thin client for the Unison HTTP API. Every request is authenticated
/// with the account's `us_…` session token from the device flow.
struct API: Sendable {
    let base: URL

    static let defaultServer = URL(string: "https://unison.cloud.run")!

    /// The server: production, or `UNISON_SERVER` from the scheme in debug builds.
    static var server: URL {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["UNISON_SERVER"], let url = URL(string: s) {
            return url
        }
        #endif
        return defaultServer
    }

    /// GETs are cached on disk under their path; see `cached(_:)`.
    func get<T: Decodable>(_ path: String, token: String?) async throws -> T {
        try await send("GET", path, token: token, body: Optional<Empty>.none, cacheKey: path)
    }

    /// `cacheKey` keeps the response on disk, for `cached(_:)`.
    func post<T: Decodable>(_ path: String, token: String?, body: some Encodable = Empty(), cacheKey: String? = nil) async throws -> T {
        try await send("POST", path, token: token, body: body, cacheKey: cacheKey)
    }

    /// The last response stored under `key` (a GET's path), so a screen can
    /// show it at once while it refetches.
    func cached<T: Decodable>(_ key: String) -> T? {
        ResponseCache.read(key)
    }

    func patch<T: Decodable>(_ path: String, token: String?, body: some Encodable) async throws -> T {
        try await send("PATCH", path, token: token, body: body)
    }

    func put<T: Decodable>(_ path: String, token: String?, body: some Encodable) async throws -> T {
        try await send("PUT", path, token: token, body: body)
    }

    func delete<T: Decodable>(_ path: String, token: String?) async throws -> T {
        try await send("DELETE", path, token: token, body: Optional<Empty>.none)
    }

    func delete<T: Decodable>(_ path: String, token: String?, body: some Encodable) async throws -> T {
        try await send("DELETE", path, token: token, body: body)
    }

    /// Follows the workspace's Server-Sent Events stream, calling `onEvent`
    /// for each event until the connection ends or the task is cancelled.
    @MainActor
    func followEvents(workspace: String, token: String, onEvent: (WorkspaceEvent) -> Void) async throws {
        var req = URLRequest(url: base.appending(path: "api/workspaces/\(workspace)/stream"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 60 // the server sends a heartbeat every 20s
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(status: status, code: nil, message: "The live connection failed (\(status)).")
        }
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            if let e = try? JSONDecoder.api.decode(WorkspaceEvent.self, from: Data(line.dropFirst(6).utf8)) {
                onEvent(e)
            }
        }
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, token: String?, body: B?,
                                                  cacheKey: String? = nil) async throws -> T {
        // `appending(path:)` would escape a query ("?status=done") into the path.
        guard let url = URL(string: path, relativeTo: base) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder.api.encode(body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let e = try? JSONDecoder.api.decode(ErrorBody.self, from: data)
            throw APIError(status: status, code: e?.code, message: e?.error ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        let value = try JSONDecoder.api.decode(T.self, from: data)
        if let cacheKey { ResponseCache.write(data, cacheKey) }
        return value
    }
}

/// Responses kept in the Caches directory (#82), so the app opens on the
/// last known data instead of spinners. Cleared on sign-out.
enum ResponseCache {
    private static let dir = URL.cachesDirectory.appending(path: "api", directoryHint: .isDirectory)

    private static func file(_ key: String) -> URL {
        dir.appending(path: (key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key) + ".json")
    }

    static func read<T: Decodable>(_ key: String) -> T? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? JSONDecoder.api.decode(T.self, from: data)
    }

    static func write(_ data: Data, _ key: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
    }
}

struct Empty: Codable, Sendable {}

struct APIError: LocalizedError {
    let status: Int
    let code: String?
    let message: String

    var errorDescription: String? { message }
}

private struct ErrorBody: Decodable {
    let error: String
    let code: String?
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
}

// MARK: - Models

struct Workspace: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var canvasUrl: String? = nil
    var repos: [Repo]? = nil

    struct Repo: Decodable, Identifiable, Hashable, Sendable {
        let id: Int64
        let url: String
    }
}

/// `GET api/me/user`: the signed-in account.
struct User: Decodable, Sendable {
    let displayName: String
    let avatarUrl: String?
}

struct NewWorkspace: Encodable, Sendable {
    let name: String
}

struct InviteRequest: Encodable, Sendable {
    let link = true
}

struct InviteLink: Decodable, Sendable {
    let url: String
}

/// `POST …/passes`: a single-use pass for an agent, and the prompt to paste into it.
struct AgentPass: Decodable, Sendable {
    let invitePrompt: String
    let expiresAt: Int64

    var expires: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000) }
}

struct NewRepo: Encodable, Sendable {
    let url: String
}

struct Participant: Decodable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let emoji: String
    let sponsor: Sponsor?

    struct Sponsor: Decodable, Sendable {
        let displayName: String
    }
}

struct Message: Decodable, Identifiable, Sendable {
    let id: Int64
    let authorId: Int64
    let parentId: Int64?
    let body: String
    let createdAt: Int64
    let item: Item?
    var reactions: [Reaction]?
    /// Set when the message asks the members it @mentions to act.
    var actionRequired: Bool? = nil

    struct Item: Decodable, Sendable {
        let id: Int64
        let title: String
        let status: String
    }

    struct Reaction: Decodable, Sendable {
        let emoji: String
        var count: Int
        /// Who reacted, first first.
        var by: [Int64]? = nil
    }

    /// The emoji anyone can put on a message; the server accepts exactly
    /// these (the web's REACTIONS).
    static let reactionChoices: [(emoji: String, label: String)] = [
        ("👍", "Thumbs up"), ("👎", "Thumbs down"), ("❤️", "Heart"), ("💪", "Muscle"), ("💯", "100"),
    ]

    func reacted(_ emoji: String, by id: Int64) -> Bool {
        reactions?.contains { $0.emoji == emoji && ($0.by ?? []).contains(id) } ?? false
    }

    /// The reactions with `id`'s `emoji` on or off. A new emoji goes last,
    /// as the server orders them.
    func withReaction(_ emoji: String, by id: Int64, on: Bool) -> [Reaction] {
        var list = reactions ?? []
        if let i = list.firstIndex(where: { $0.emoji == emoji }) {
            var by = list[i].by ?? []
            guard by.contains(id) != on else { return list }
            if on { by.append(id) } else { by.removeAll { $0 == id } }
            list[i].by = by
            list[i].count += on ? 1 : -1
            if list[i].count <= 0 { list.remove(at: i) }
        } else if on {
            list.append(Reaction(emoji: emoji, count: 1, by: [id]))
        }
        return list
    }

    /// When it was sent, never in the future (the server's clock may be ahead).
    var date: Date { min(Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000), .now) }
}

struct NewMessage: Encodable, Sendable {
    let body: String
    let parentId: Int64?
}

struct Device: Decodable, Sendable {
    let id: Int64
}

struct NewDevice: Encodable, Sendable {
    let apnsToken: String
    let label: String
    /// "sandbox" or "production" (#137); nil leaves it to the server.
    var environment: String? = nil
}

/// An event from the workspace stream; only its type matters to the app.
struct WorkspaceEvent: Decodable, Sendable {
    let seq: Int64
    let type: String
}

struct JoinResponse: Decodable, Sendable {
    let participant: Participant
}

struct AppTokenRequest: Encodable, Sendable {
    let code: String
    let codeVerifier: String
    let label: String
}

/// `POST api/auth/apple/native`: a code from the Sign in with Apple button
/// (#136), and the name Apple gives only the app, only the first time.
struct AppleSignIn: Encodable, Sendable {
    let code: String
    let givenName: String?
    let familyName: String?
    let label: String
}

struct AppToken: Decodable, Sendable {
    let token: String
}

extension Data {
    /// Base64url without padding, as PKCE uses.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
