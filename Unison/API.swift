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

struct Participant: Decodable, Sendable {
    let id: Int64
    let name: String
    let emoji: String
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
