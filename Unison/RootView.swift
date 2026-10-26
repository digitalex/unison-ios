import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.token == nil {
                SignInView()
            } else {
                MainView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Unison")
                    .font(.largeTitle.bold())
                Text("Build together with your team and its agents.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if let code = model.pendingCode {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Confirm the code **\(code)** in the browser.")
                        .multilineTextAlignment(.center)
                    Button("Cancel", role: .cancel) { model.cancelSignIn() }
                }
            } else {
                Button {
                    model.signIn()
                } label: {
                    Text("Sign in with GitHub")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(24)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right") {
                screen("Chat") { ChatView() }
            }
            Tab("Inbox", systemImage: "tray") {
                screen("Inbox") { notBuilt("Inbox", systemImage: "tray") }
            }
            Tab("Backlog", systemImage: "list.number") {
                screen("Backlog") { notBuilt("Backlog", systemImage: "list.number") }
            }
        }
        .task { await model.load() }
        // Follow live events while the app is in the foreground.
        // Keyed on the joined participant: the stream needs the workspace
        // list loaded and joined, which happens after launch.
        .task(id: scenePhase == .active ? model.participant?.id : nil) {
            if scenePhase == .active, model.participant != nil { await model.followEvents() }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    private func screen(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        NavigationStack {
            Group {
                if model.workspaces.isEmpty {
                    ContentUnavailableView("No workspaces", systemImage: "square.dashed",
                                           description: Text("Join a workspace on the web, then come back."))
                } else if model.participant == nil {
                    ProgressView()
                } else {
                    content()
                }
            }
            .navigationTitle(model.selected?.name ?? title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { WorkspaceMenu() }
        }
    }
}

private func notBuilt(_ title: String, systemImage: String) -> some View {
    ContentUnavailableView(title, systemImage: systemImage, description: Text("Not built yet."))
}

/// The workspace switcher and sign-out, in every tab's navigation bar.
struct WorkspaceMenu: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if model.workspaces.count > 1 {
                    Picker("Workspace", selection: Binding(
                        get: { model.selectedID },
                        set: { id in if let id { Task { await model.select(id) } } }
                    )) {
                        ForEach(model.workspaces) { ws in
                            Text(ws.name).tag(Optional(ws.id))
                        }
                    }
                }
                if let p = model.participant {
                    Text("\(p.emoji) \(p.name)")
                }
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await model.signOut() }
                }
            } label: {
                Image(systemName: "person.crop.circle")
            }
        }
    }
}
