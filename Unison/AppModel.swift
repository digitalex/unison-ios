import AuthenticationServices
import Foundation
import Observation
import UIKit

/// The app's state: the session, the user's workspaces and the selected one.
@MainActor
@Observable
final class AppModel {
    private(set) var token: String?
    private(set) var workspaces: [Workspace] = []
    private(set) var participant: Participant?
    /// The code shown while the user approves the sign-in in the browser.
    private(set) var pendingCode: String?
    var error: String?
    /// Bumped per event kind ("message", "inbox", …) as the stream delivers
    /// events, so screens can refetch with `.task(id: model.revision(…))`.
    private(set) var revisions: [String: Int] = [:]

    var selectedID: Workspace.ID? {
        didSet { UserDefaults.standard.set(selectedID, forKey: "workspace") }
    }

    var selected: Workspace? { workspaces.first { $0.id == selectedID } }

    let api = API(base: API.server)
    private var authSession: ASWebAuthenticationSession?
    private let presenter = AuthPresenter()
    private var signInTask: Task<Void, Never>?

    init() {
        token = Keychain.read()
        selectedID = UserDefaults.standard.string(forKey: "workspace")
    }

    // MARK: Sign in (device flow)

    /// Signs in with the device flow `unison login` uses: the user approves
    /// the code in a browser sheet (signing in with GitHub there) while the
    /// app polls for the session token.
    func signIn() {
        signInTask?.cancel()
        error = nil
        signInTask = Task {
            do {
                let start: DeviceStart = try await api.post("api/auth/device", token: nil)
                pendingCode = start.userCode
                presentBrowser(start.verificationUrlComplete)
                let token = try await poll(start)
                Keychain.save(token)
                self.token = token
                await load()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            finishSignIn()
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        finishSignIn()
    }

    private func finishSignIn() {
        pendingCode = nil
        authSession?.cancel()
        authSession = nil
    }

    private func poll(_ start: DeviceStart) async throws -> String {
        var interval = max(start.interval, 1)
        let deadline = Date.now.addingTimeInterval(TimeInterval(start.expiresIn))
        let req = DeviceTokenRequest(deviceCode: start.deviceCode, label: "iPhone")
        while Date.now < deadline {
            try await Task.sleep(for: .seconds(interval))
            let res: DevicePoll = try await api.post("api/auth/device/token", token: nil, body: req)
            switch res.status {
            case "pending":
                continue
            case "slow_down":
                interval += 5
            case "denied":
                throw APIError(status: 0, code: nil, message: "Sign-in was denied.")
            default:
                if let token = res.token {
                    return token
                }
                if res.status == "expired" {
                    throw APIError(status: 0, code: nil, message: "The sign-in code expired. Try again.")
                }
            }
        }
        throw APIError(status: 0, code: nil, message: "The sign-in code expired. Try again.")
    }

    private func presentBrowser(_ url: URL) {
        // No callback ever arrives: the app closes the sheet itself once the
        // poll returns a token. The completion only fires early when the
        // user closes the sheet, which cancels the sign-in.
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("unison")) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.authSession != nil, self.token == nil else { return }
                self.cancelSignIn()
            }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
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

    func select(_ id: Workspace.ID) async {
        selectedID = id
        participant = nil
        do {
            try await join()
        } catch {
            handle(error)
        }
    }

    private func join() async throws {
        guard let token, let ws = selected else { return }
        let res: JoinResponse = try await api.post("api/workspaces/\(ws.id)/join", token: token)
        participant = res.participant
    }

    // MARK: Live updates

    func revision(_ kind: String) -> Int { revisions[kind, default: 0] }

    /// Follows the selected workspace's event stream until cancelled,
    /// reconnecting with backoff. Each event bumps its kind's revision.
    func followEvents() async {
        guard let token, let ws = selected else { return }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                try await api.followEvents(workspace: ws.id, token: token) { event in
                    backoff = .seconds(1)
                    let kind = String(event.type.prefix { $0 != "." })
                    revisions[kind, default: 0] += 1
                }
            } catch is CancellationError {
                return
            } catch {
                if let e = error as? APIError, e.status == 401 {
                    handle(e)
                    return
                }
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
            // Catch up on anything missed while disconnected.
            for kind in revisions.keys { revisions[kind, default: 0] += 1 }
        }
    }

    // MARK: Sign out

    func signOut() async {
        if let token {
            let _: Empty? = try? await api.post("api/auth/logout", token: token)
        }
        clearSession()
    }

    private func clearSession() {
        Keychain.delete()
        token = nil
        workspaces = []
        participant = nil
    }

    /// Shows the error; a 401 means the session is gone, so sign out.
    func handle(_ error: Error) {
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
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
