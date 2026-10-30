import AuthenticationServices
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
        .preferredColorScheme(.dark)
    }
}

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var reviewing = false
    @State private var reviewCode = ""

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
            if model.signingIn {
                ProgressView()
            } else {
                VStack(spacing: 12) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        model.signInWithApple(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 55)
                    .clipShape(.capsule)
                    Button {
                        model.signIn()
                    } label: {
                        Text("Sign in with GitHub")
                            .frame(maxWidth: .infinity, minHeight: 26)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("App Review sign-in") {
                        reviewCode = ""
                        reviewing = true
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .alert("App Review sign-in", isPresented: $reviewing) {
            SecureField("Access code", text: $reviewCode)
            Button("Cancel", role: .cancel) {}
            Button("Sign in") { model.signInForReview(code: reviewCode) }
                .disabled(reviewCode.isEmpty)
        } message: {
            Text("Enter the access code from the review notes.")
        }
        #if DEBUG
        .task { // UNISON_AUTO_SIGN_IN=1 starts sign-in at launch, for testing
            if ProcessInfo.processInfo.environment["UNISON_AUTO_SIGN_IN"] != nil {
                try? await Task.sleep(for: .seconds(1))
                model.signIn()
            }
        }
        #endif
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var actions = ActionsModel()
    @State private var tab = MainView.initialTab
    @State private var chatPath: [Int64] = []
    /// Counts taps on the Chat tab; each one scrolls the chat to the end (#80).
    @State private var chatJump = ChatJump()
    @State private var backlogPath: [Int64] = MainView.initialItem
    @State private var recurringPath: [Int64] = []
    @State private var settingsPath: [Int64] = []
    @State private var newWorkspace = false
    @State private var newWorkspaceName = ""

    /// Debug builds can open on a tab with `UNISON_TAB` (chat, backlog, recurring, settings),
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
        // A Binding of our own, since the setter also runs when the selected tab is tapped again.
        TabView(selection: Binding(get: { tab }, set: { new in
            // Tapping Chat goes to the oldest message asking you to act (its
            // thread, for a reply), or else to the newest message (#110).
            if new == "chat" {
                if let oldest = actions.oldest {
                    chatPath = oldest.thread == oldest.id ? [] : [oldest.thread]
                    chatJump = ChatJump(tap: chatJump.tap + 1, to: oldest.thread)
                } else {
                    if tab == "chat" { chatPath = [] }
                    chatJump = ChatJump(tap: chatJump.tap + 1, to: nil)
                }
            }
            tab = new
        })) {
            Tab("Chat", systemImage: "bubble.left.and.bubble.right", value: "chat") {
                screen("Chat", path: $chatPath) { ChatView(actions: actions, jump: chatJump) }
            }
            .badge(actions.count)
            Tab("Backlog", systemImage: "list.number", value: "backlog") {
                screen("Backlog", path: $backlogPath) { BacklogView() }
            }
            Tab("Recurring", systemImage: "repeat", value: "recurring") {
                screen("Recurring", path: $recurringPath) { RecurringView() }
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                screen("Settings", path: $settingsPath) { SettingsView() }
            }
        }
        .alert("New workspace", isPresented: $newWorkspace) {
            TextField("Name", text: $newWorkspaceName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
                Task { await model.createWorkspace(named: name) }
            }
            .disabled(newWorkspaceName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("You'll be its first member.")
        }
        // In-app links (`#N` in messages) route here rather than via the system.
        .environment(\.openURL, OpenURLAction { url in
            guard let route = Route(url: url) else { return .systemAction }
            model.route = route
            return .handled
        })
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
        // Clear notifications for chat you've read elsewhere since (#122).
        .task(id: scenePhase == .active && !model.workspaces.isEmpty) {
            if scenePhase == .active { await model.clearReadNotifications() }
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
            // One opaque row: the tab's title on the left, the workspace on the right.
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                TitleItem(title: title)
                WorkspaceMenu {
                    newWorkspaceName = ""
                    newWorkspace = true
                }
            }
            .toolbarBackground(Color(white: 0.07), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct RouteTrigger: Equatable {
    let route: Route?
    let ready: Bool
}

/// The tab's title, at the top left, without the iOS 26 glass bubble.
private struct TitleItem: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        if #available(iOS 26, *) {
            item.sharedBackgroundVisibility(.hidden)
        } else {
            item
        }
    }

    private var item: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text(title).font(.title3.bold()).fixedSize()
        }
    }
}

/// The workspace switcher, at the top right of every tab.
struct WorkspaceMenu: ToolbarContent {
    @Environment(AppModel.self) private var model
    let create: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Your workspaces", selection: Binding(
                    get: { model.selectedID },
                    set: { id in if let id { Task { await model.select(id) } } }
                )) {
                    ForEach(model.workspaces) { ws in
                        Text(ws.name).tag(Optional(ws.id))
                    }
                }
                Divider()
                Button("New workspace…", systemImage: "plus", action: create)
            } label: {
                let name = model.selected?.name ?? ""
                HStack(spacing: 6) {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.caption.bold())
                        .foregroundStyle(.black)
                        .frame(width: 20, height: 20)
                        .background(.tint, in: RoundedRectangle(cornerRadius: 6))
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
    }
}
