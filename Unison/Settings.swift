import SwiftUI

/// The Settings tab's data: the workspace in full (with its repositories),
/// the account you're signed in with, and the invites you made here.
@Observable @MainActor
final class SettingsModel {
    private(set) var workspace: Workspace?
    private(set) var user: User?
    private(set) var inviteURL: URL?
    private(set) var agentPass: AgentPass?
    private(set) var inviting = false

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        let detailPath = "api/workspaces/\(ws.id)"
        if workspace?.id != ws.id {
            workspace = app.api.cached(detailPath)
            user = app.api.cached("api/me/user")
            inviteURL = nil
            agentPass = nil
        }
        do {
            workspace = try await app.api.get(detailPath, token: token)
            // Only account sessions have a user; a debug agent token gets a 401
            // here, which must not sign it out.
            user = try? await app.api.get("api/me/user", token: token)
        } catch {
            app.handle(error)
        }
    }

    /// An invite link for people (48 hours, any number of people).
    func invitePerson(_ app: AppModel) async {
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

    /// A single-use pass for an agent (15 minutes), with the prompt to give it.
    func inviteAgent(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        inviting = true
        defer { inviting = false }
        do {
            agentPass = try await app.api.post("api/workspaces/\(ws.id)/passes", token: token)
        } catch {
            app.handle(error)
        }
    }

    /// Adds a repository. Returns whether it was added.
    func addRepo(_ app: AppModel, url: String) async -> Bool {
        guard let token = app.token, let ws = app.selected else { return false }
        do {
            let _: Workspace.Repo = try await app.api.post("api/workspaces/\(ws.id)/repos", token: token, body: NewRepo(url: url))
            await load(app)
            return true
        } catch {
            app.handle(error)
            return false
        }
    }

    func removeRepo(_ app: AppModel, _ repo: Workspace.Repo) async {
        guard let token = app.token, let ws = app.selected else { return }
        do {
            let _: Empty = try await app.api.delete("api/workspaces/\(ws.id)/repos/\(repo.id)", token: token)
            await load(app)
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
                    ReposView(settings: settings)
                } label: {
                    LabeledContent("Repositories", value: "\(settings.workspace?.repos?.count ?? 0)")
                }
                if let s = settings.workspace?.canvasUrl, let url = URL(string: s) {
                    Link(destination: url) {
                        LabeledContent("Canvas", value: url.host() ?? s)
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section {
                if let url = settings.inviteURL {
                    ShareLink("Share invite link", item: url)
                } else {
                    Button("Invite a person…") {
                        Task { await settings.invitePerson(model) }
                    }
                    .disabled(settings.inviting)
                }
                if let pass = settings.agentPass {
                    AgentPassRow(pass: pass)
                } else {
                    Button("Invite an agent…") {
                        Task { await settings.inviteAgent(model) }
                    }
                    .disabled(settings.inviting)
                }
            } header: {
                Text("Invite")
            } footer: {
                Text("People get a link that works for 48 hours. An agent gets a prompt to paste into it, with a pass that works once, for 15 minutes.")
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
        .task(id: "\(model.selectedID ?? "")-\(model.revision("participant"))-\(model.revision("workspace"))-\(model.revision("repo"))") {
            await settings.load(model)
        }
    }
}

/// The workspace's repositories: open one, swipe to remove, or add another.
private struct ReposView: View {
    @Environment(AppModel.self) private var model
    let settings: SettingsModel
    @State private var adding = false
    @State private var newURL = ""

    var body: some View {
        List {
            ForEach(settings.workspace?.repos ?? []) { repo in
                if let url = URL(string: repo.url) {
                    Link(url.path().trimmingCharacters(in: ["/"]), destination: url)
                } else {
                    Text(repo.url)
                }
            }
            .onDelete { offsets in
                let repos = offsets.compactMap { settings.workspace?.repos?[$0] }
                Task { for repo in repos { await settings.removeRepo(model, repo) } }
            }
            Button("Add repository", systemImage: "plus") {
                newURL = ""
                adding = true
            }
        }
        .navigationTitle("Repositories")
        .alert("Add repository", isPresented: $adding) {
            TextField("https://github.com/owner/repo", text: $newURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let url = newURL.trimmingCharacters(in: .whitespaces)
                Task { _ = await settings.addRepo(model, url: url) }
            }
            .disabled(URL(string: newURL.trimmingCharacters(in: .whitespaces))?.host() == nil)
        } message: {
            Text("Its web URL, so agents know where the code is.")
        }
    }
}

/// A minted agent pass: the prompt to give the agent, to copy or share.
private struct AgentPassRow: View {
    let pass: AgentPass
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pass.invitePrompt)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(6)
            if pass.expires > .now {
                Text("Expires \(pass.expires, style: .relative)").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Expired: invite again for a new pass.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = pass.invitePrompt
                    copied = true
                }
                Spacer()
                ShareLink(item: pass.invitePrompt) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}
