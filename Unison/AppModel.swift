import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UserNotifications
import OSLog
import UIKit

let log = Logger(subsystem: "com.digitalex.Unison", category: "app")

/// The app's state: the session, the user's workspaces and the selected one.
@MainActor
@Observable
final class AppModel {
    private(set) var token: String?
    private(set) var workspaces: [Workspace] = []
    private(set) var participant: Participant?
    /// True while the GitHub sign-in sheet is up.
    private(set) var signingIn = false
    var error: String?
    /// Where a tapped notification or a link asks to go; the tab view
    /// follows it and clears it.
    var route: Route?
    /// Bumped per event kind ("message", "inbox", …) as the stream delivers
    /// events, so screens can refetch with `.task(id: model.revision(…))`.
    private(set) var revisions: [String: Int] = [:]

    var selectedID: Workspace.ID? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "workspace") }
    }

    var selected: Workspace? { workspaces.first { $0.id == selectedID } }

    let api = API(base: API.server)
    /// How far chat is read, per workspace, as far as this app knows (#122).
    var readUpTo: [String: Int64] = [:]
    private let presenter = AuthPresenter()
    private var signInTask: Task<Void, Never>?

    init() {
        token = Keychain.read()
        selectedID = UserDefaults.standard.string(forKey: "workspace")
        #if DEBUG
        // Testing against a local open-mode server (`UNISON_AUTH=off`) with a
        // participant token instead of an account session.
        if let t = ProcessInfo.processInfo.environment["UNISON_TOKEN"] {
            token = t
            selectedID = ProcessInfo.processInfo.environment["UNISON_WORKSPACE"] ?? selectedID
        }
        #endif
        // Open on the last known workspaces while they reload.
        if token != nil {
            workspaces = api.cached("api/workspaces") ?? []
            participant = cachedParticipant()
        }
    }

    // MARK: Sign in

    /// Signs in with GitHub in a browser sheet. The server's app flow
    /// (`/auth/github/start?app=1`) redirects back to `unison://auth?code=…`
    /// with a one-time code, which only this app can redeem: it's bound to
    /// the PKCE challenge of a verifier that never leaves the app.
    func signIn() {
        signInTask?.cancel()
        error = nil
        signingIn = true
        signInTask = Task {
            defer { signingIn = false }
            do {
                let verifier = Self.randomVerifier()
                let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
                var start = URLComponents(url: api.base.appending(path: "auth/github/start"), resolvingAgainstBaseURL: false)!
                start.queryItems = [URLQueryItem(name: "app", value: "1"), URLQueryItem(name: "code_challenge", value: challenge)]
                let callback = try await authenticate(start.url!)
                guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "code" })?.value else {
                    throw APIError(status: 0, code: nil, message: "Sign-in didn't complete. Try again.")
                }
                let res: AppToken = try await api.post("api/auth/app/token", token: nil,
                                                       body: AppTokenRequest(code: code, codeVerifier: verifier, label: "iPhone"))
                Keychain.save(res.token)
                token = res.token // the tab view then loads and enables push
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Runs the browser sheet until the server redirects to `unison://…`.
    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("unison")) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    /// A PKCE verifier: 32 random bytes, base64url (43 characters).
    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    // MARK: Workspaces

    /// Loads the user's workspaces and joins the selected one (joining
    /// returns the existing participant if there is one).
    func load() async {
        guard let token else { return }
        do {
            workspaces = try await api.get("api/workspaces", token: token)
            if selected == nil {
                selectedID = workspaces.first?.id
            }
            try await join()
        } catch {
            handle(error)
        }
    }

    /// Creates a workspace (you become its first member) and switches to it.
    func createWorkspace(named name: String) async {
        guard let token else { return }
        do {
            let ws: Workspace = try await api.post("api/workspaces", token: token, body: NewWorkspace(name: name))
            workspaces.append(ws)
            await select(ws.id)
        } catch {
            handle(error)
        }
    }

    func select(_ id: Workspace.ID) async {
        selectedID = id
        participant = cachedParticipant()
        do {
            try await join()
        } catch {
            handle(error)
        }
    }

    private func join() async throws {
        guard let token, let ws = selected else { return }
        #if DEBUG
        if !token.hasPrefix("us_") { // a participant token is already joined
            participant = try await api.get("api/workspaces/\(ws.id)/me", token: token)
            return
        }
        #endif
        let res: JoinResponse = try await api.post("api/workspaces/\(ws.id)/join", token: token, cacheKey: Self.joinKey(ws.id))
        participant = res.participant
    }

    private static func joinKey(_ workspace: Workspace.ID) -> String { "join/\(workspace)" }

    /// The participant from the last join of the selected workspace.
    private func cachedParticipant() -> Participant? {
        guard let id = selectedID else { return nil }
        let res: JoinResponse? = api.cached(Self.joinKey(id))
        return res?.participant
    }

    // MARK: Live updates

    func revision(_ kind: String) -> Int { revisions[kind, default: 0] + catchUps }

    /// Bumped to make every screen refetch, after events may have been missed.
    private var catchUps = 0
    /// The workspace whose stream was followed last.
    private var streamedWorkspace: Workspace.ID?

    /// Follows the selected workspace's event stream until cancelled,
    /// reconnecting with backoff. Each event bumps its kind's revision.
    func followEvents() async {
        guard let token, let ws = selected else { return }
        // Following again (back in the foreground): catch up on what came
        // while the stream was down, such as the message of a tapped push.
        if streamedWorkspace == ws.id { catchUps += 1 }
        streamedWorkspace = ws.id
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            log.info("stream: connecting to \(ws.id, privacy: .public)")
            do {
                try await api.followEvents(workspace: ws.id, token: token) { event in
                    backoff = .seconds(1)
                    let kind = String(event.type.prefix { $0 != "." })
                    log.info("stream: \(event.type, privacy: .public)")
                    revisions[kind, default: 0] += 1
                }
            } catch is CancellationError {
                return
            } catch {
                log.error("stream: \(error.localizedDescription, privacy: .public)")
                if let e = error as? APIError, e.status == 401 {
                    handle(e)
                    return
                }
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
            // Catch up on anything missed while disconnected.
            catchUps += 1
        }
    }

    // MARK: Push notifications

    /// Registers for remote notifications (the delegate then posts the device
    /// token with `registerDevice`) and asks for permission to show them.
    /// Registering doesn't need the permission, so the server knows the device
    /// either way; iOS only shows pushes once the user allows them.
    func enablePush() async {
        guard token?.hasPrefix("us_") == true else { return } // devices belong to accounts
        #if DEBUG
        if ProcessInfo.processInfo.environment["UNISON_NO_PUSH"] != nil { return } // no prompt over screenshots
        #endif
        UIApplication.shared.registerForRemoteNotifications()
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            log.info("push: permission \(granted ? "granted" : "denied", privacy: .public)")
        } catch {
            log.error("push: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Registers this device's APNs token with the account (`POST /api/me/devices`).
    /// Signing out removes it on the server.
    func registerDevice(_ apnsToken: String) async {
        guard let token, token.hasPrefix("us_") else { return }
        do {
            let _: Device = try await api.post("api/me/devices", token: token,
                                               body: NewDevice(apnsToken: apnsToken, label: "iPhone",
                                                               environment: PushEnvironment.current))
            log.info("push: device registered")
        } catch {
            log.error("push: device registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Sign out

    func signOut() async {
        if let token {
            let _: Empty? = try? await api.post("api/auth/logout", token: token)
        }
        clearSession()
    }

    /// Deletes the account for good (#135; App Store guideline 5.1.1(v)),
    /// then signs out. Returns whether it was deleted.
    func deleteAccount() async -> Bool {
        guard let token else { return false }
        do {
            let _: AccountDeletion = try await api.delete("api/me/user", token: token, body: ConfirmDeletion())
            clearSession()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func clearSession() {
        Keychain.delete()
        ResponseCache.clear()
        token = nil
        workspaces = []
        participant = nil
    }

    /// Shows the error; a 401 means the session is gone, so sign out.
    func handle(_ error: Error) {
        // A restarted `.task` cancels its request; that's not an error.
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return
        }
        if let e = error as? APIError, e.status == 401 {
            clearSession()
            self.error = "You were signed out. Sign in again."
            return
        }
        self.error = error.localizedDescription
    }
}

/// Presents the sign-in sheet over the app's key window.
final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
        }
    }
}

struct ConfirmDeletion: Encodable, Sendable {
    var confirm = true
}

struct AccountDeletion: Decodable, Sendable {
    let deletedWorkspaces: [String]
    let leftWorkspaces: [String]
}
