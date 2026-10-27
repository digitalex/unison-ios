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
    @State private var actions = ActionsModel()
    @State private var tab = MainView.initialTab
    @State private var chatPath: [Int64] = []
    @State private var backlogPath: [Int64] = MainView.initialItem

    /// Debug builds can open on a tab with `UNISON_TAB` (chat, backlog),
    /// and on a backlog item with `UNISON_ITEM`, for screenshots.
    private static var initialTab: String {
        #if DEBUG
        return ProcessInfo.processInfo.environment["UNISON_TAB"] ?? "chat"
        #else
        return "chat"
        #endif
    }

    private static var initialItem: [Int64] {
        #if DEBUG
        return ProcessInfo.processInfo.environment["UNISON_ITEM"].flatMap { Int64($0) }.map { [$0] } ?? []
        #else
        return []
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: "chat") {
                screen("Chat", path: $chatPath) { ChatView(actions: actions) }
            }
            .badge(actions.count)
            Tab("Backlog", systemImage: "list.number", value: "backlog") {
                screen("Backlog", path: $backlogPath) { BacklogView() }
            }
        }
        .task {
            await model.load()
            await model.enablePush()
        }
        // Follow a tapped notification or a link, once the workspaces are loaded.
        .task(id: RouteTrigger(route: model.route, ready: model.participant != nil)) {
            guard let route = model.route, model.participant != nil else { return }
            await follow(route)
        }
        .task(id: "\(model.participant?.id ?? 0)-\(model.revision("message"))") {
            if model.participant != nil { await actions.load(model) }
        }
        // Follow live events while the app is in the foreground.
        // Keyed on the joined participant: the stream needs the workspace
        // list loaded and joined, which happens after launch.
        .task(id: scenePhase == .active ? model.participant?.id : nil) {
            if scenePhase == .active, model.participant != nil { await model.followEvents() }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    private func follow(_ route: Route) async {
        model.route = nil
        if let ws = route.workspaceID, ws != model.selectedID, model.workspaces.contains(where: { $0.id == ws }) {
            await model.select(ws)
        }
        if let thread = route.thread {
            tab = "chat"
            chatPath = [thread]
        } else if let item = route.itemID {
            tab = "backlog"
            backlogPath = [item]
        }
        log.info("route: opened \(tab, privacy: .public) \(route.thread ?? route.itemID ?? 0)")
    }

    private func screen(_ title: String, path: Binding<[Int64]>, @ViewBuilder content: () -> some View) -> some View {
        NavigationStack(path: path) {
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

private struct RouteTrigger: Equatable {
    let route: Route?
    let ready: Bool
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
