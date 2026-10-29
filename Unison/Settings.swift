import SwiftUI

/// The Settings tab's data: the workspace in full, its members, and the
/// account you're signed in with.
@Observable @MainActor
final class SettingsModel {
    private(set) var workspace: Workspace?
    private(set) var members: [Participant] = []
    private(set) var user: User?
    private(set) var inviteURL: URL?
    private(set) var inviting = false

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        let detailPath = "api/workspaces/\(ws.id)", peoplePath = "api/workspaces/\(ws.id)/participants"
        if workspace?.id != ws.id {
            workspace = app.api.cached(detailPath)
            members = app.api.cached(peoplePath) ?? []
            user = app.api.cached("api/me/user")
        }
        do {
            async let detail: Workspace = app.api.get(detailPath, token: token)
            async let people: [Participant] = app.api.get(peoplePath, token: token)
            (workspace, members) = try await (detail, people)
            // Only account sessions have a user; a debug agent token gets a 401
            // here, which must not sign it out.
            user = try? await app.api.get("api/me/user", token: token)
            inviteURL = nil
        } catch {
            app.handle(error)
        }
    }

    func invite(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        inviting = true
        defer { inviting = false }
        do {
            let res: InviteLink = try await app.api.post("api/workspaces/\(ws.id)/invites", token: token, body: InviteRequest())
            inviteURL = URL(string: res.url)
        } catch {
            app.handle(error)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var settings = SettingsModel()

    var body: some View {
        List {
            Section("Workspace") {
                LabeledContent("Name", value: settings.workspace?.name ?? model.selected?.name ?? "")
                NavigationLink {
                    MembersView(members: settings.members)
                } label: {
                    LabeledContent("Members") {
                        Text(settings.members.prefix(5).map(\.emoji).joined())
                    }
                }
                if let repos = settings.workspace?.repos, !repos.isEmpty {
                    NavigationLink {
                        ReposView(repos: repos)
                    } label: {
                        LabeledContent("Repositories", value: "\(repos.count)")
                    }
                }
                if let s = settings.workspace?.canvasUrl, let url = URL(string: s) {
                    Link(destination: url) {
                        LabeledContent("Canvas", value: url.host() ?? s)
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section("Invite") {
                if let url = settings.inviteURL {
                    ShareLink("Share invite link", item: url)
                } else {
                    Button(settings.inviting ? "Creating link…" : "Invite someone…") {
                        Task { await settings.invite(model) }
                    }
                    .disabled(settings.inviting)
                }
            }

            Section {
                Button("Notifications") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("You're notified when something needs you and when you're mentioned.")
            }

            Section("Account") {
                if let user = settings.user {
                    HStack(spacing: 12) {
                        AsyncImage(url: user.avatarUrl.flatMap(URL.init(string:))) { image in
                            image.resizable()
                        } placeholder: {
                            Color.secondary.opacity(0.3)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(user.displayName).fontWeight(.semibold)
                            Text("Signed in with GitHub").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Sign out", role: .destructive) {
                    Task { await model.signOut() }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(model.selectedID ?? "")-\(model.revision("participant"))-\(model.revision("workspace"))") {
            await settings.load(model)
        }
    }
}

private struct MembersView: View {
    let members: [Participant]

    var body: some View {
        List(members) { p in
            HStack(spacing: 12) {
                Text(p.emoji).font(.title3)
                VStack(alignment: .leading) {
                    Text(p.name)
                    if let s = p.sponsor {
                        Text("agent of \(s.displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Members")
    }
}

private struct ReposView: View {
    let repos: [Workspace.Repo]

    var body: some View {
        List(repos) { repo in
            if let url = URL(string: repo.url) {
                Link(url.path().trimmingCharacters(in: ["/"]), destination: url)
            }
        }
        .navigationTitle("Repositories")
    }
}
