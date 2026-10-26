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

    func get<T: Decodable>(_ path: String, token: String?) async throws -> T {
        try await send("GET", path, token: token, body: Optional<Empty>.none)
    }

    func post<T: Decodable>(_ path: String, token: String?, body: some Encodable = Empty()) async throws -> T {
        try await send("POST", path, token: token, body: body)
    }

    func delete<T: Decodable>(_ path: String, token: String?) async throws -> T {
        try await send("DELETE", path, token: token, body: Optional<Empty>.none)
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

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, token: String?, body: B?) async throws -> T {
        var req = URLRequest(url: base.appending(path: path))
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
        return try JSONDecoder.api.decode(T.self, from: data)
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
    let reactions: [Reaction]?
    /// Set when the message asks the members it @mentions to act.
    var actionRequired: Bool? = nil

    struct Item: Decodable, Sendable {
        let id: Int64
        let title: String
        let status: String
    }

    struct Reaction: Decodable, Sendable {
        let emoji: String
        let count: Int
    }

    /// When it was sent, never in the future (the server's clock may be ahead).
    var date: Date { min(Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000), .now) }
}

struct NewMessage: Encodable, Sendable {
    let body: String
    let parentId: Int64?
    var actionRequired: Bool? = nil
}

/// An event from the workspace stream; only its type matters to the app.
struct WorkspaceEvent: Decodable, Sendable {
    let seq: Int64
    let type: String
}

struct JoinResponse: Decodable, Sendable {
    let participant: Participant
}

struct DeviceStart: Decodable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationUrlComplete: URL
    let interval: Int
    let expiresIn: Int
}

struct DevicePoll: Decodable, Sendable {
    let status: String
    let token: String?
}

struct DeviceTokenRequest: Encodable, Sendable {
    let deviceCode: String
    let label: String
}
