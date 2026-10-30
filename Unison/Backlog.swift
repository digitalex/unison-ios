import SwiftUI

struct BacklogItem: Decodable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let body: String
    let status: String
    let assigneeId: Int64?
    let closeNote: String?
    let prs: [PR]
    let commentCount: Int
    /// The recurring task that added this item, if any (#112).
    var scheduleId: Int64? = nil
    var leaseExpiresAt: Int64? = nil
    var updatedAt: Int64? = nil
    var closedAt: Int64? = nil

    /// Being worked on (#146): independent of who it's assigned to. Servers
    /// from before #146 call this "assigned".
    var inProgress: Bool { status == "in_progress" || status == "assigned" }

    /// The status for people.
    var statusLabel: String {
        if inProgress { return "In progress" }
        return status.capitalized
    }

    struct PR: Decodable, Identifiable, Sendable {
        let id: Int64
        let url: String
    }
}

struct Comment: Decodable, Identifiable, Sendable {
    let id: Int64
    let authorId: Int64
    let body: String
    let createdAt: Int64

    /// Comments render like chat messages.
    var asMessage: Message {
        Message(id: id, authorId: authorId, parentId: nil, body: body, createdAt: createdAt, item: nil, reactions: nil)
    }
}

/// The Backlog tab's data.
@MainActor
@Observable
final class BacklogModel {
    enum Filter: String, CaseIterable, Identifiable {
        case active = "Active", done = "Done"
        var id: Self { self }
    }

    var filter = Filter.active
    /// Filters titles on the device (#130).
    var search = ""
    private(set) var items: [BacklogItem] = []
    private(set) var people: [Int64: Participant] = [:]
    private(set) var loaded = false
    /// The list the items are from.
    private var shownPath: String?

    private func show(_ l: [BacklogItem], _ p: [Participant]) {
        items = l
        people = Dictionary(p.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        // No status means open and assigned items, in priority order.
        let path = "api/workspaces/\(ws.id)/backlog" + (filter == .done ? "?status=done" : "")
        let pplPath = "api/workspaces/\(ws.id)/participants"
        // On first load, a workspace switch or a new filter, show the cached copy while refetching.
        if shownPath != path {
            shownPath = path
            let l: [BacklogItem]? = app.api.cached(path), p: [Participant]? = app.api.cached(pplPath)
            show(l ?? [], p ?? [])
            loaded = l != nil
        }
        do {
            async let list: [BacklogItem] = app.api.get(path, token: token)
            async let ppl: [Participant] = app.api.get(pplPath, token: token)
            let (l, p) = try await (list, ppl)
            show(l, p)
            loaded = true
        } catch {
            app.handle(error)
        }
    }

    /// Adds an item at the bottom of the backlog. Returns whether it was added.
    func add(_ app: AppModel, title: String, body: String, assigneeId: Int64? = nil) async -> Bool {
        guard let token = app.token, let ws = app.selected else { return false }
        do {
            let _: BacklogItem = try await app.api.post("api/workspaces/\(ws.id)/backlog", token: token,
                                                        body: NewItem(title: title, body: body, assigneeId: assigneeId))
            await load(app)
            return true
        } catch {
            app.handle(error)
            return false
        }
    }

    /// The items shown: `items` narrowed by the search text.
    var shown: [BacklogItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return items.filter { item in
            q.isEmpty || item.title.localizedCaseInsensitiveContains(q) || "#\(item.id)" == q || "\(item.id)" == q
        }
    }

    /// Assigns an item to you (#130), leaving its progress as it is (#146).
    func take(_ app: AppModel, _ id: Int64) async {
        await act(app, "backlog/\(id)/assign", AssignItem())
    }

    /// Starts work on an item (#146); it's yours if it had no assignee.
    func start(_ app: AppModel, _ id: Int64) async {
        await act(app, "backlog/\(id)/start", Empty())
    }

    /// Moves an item back to Up next (#146); it keeps its assignee.
    func stop(_ app: AppModel, _ id: Int64) async {
        await act(app, "backlog/\(id)/stop", Empty())
    }

    /// Assigns an item to someone, or to nobody (nil), leaving its progress
    /// as it is (#146). Returns the saved item.
    func assign(_ app: AppModel, _ id: Int64, to: Int64?) async -> BacklogItem? {
        guard let token = app.token, let ws = app.selected else { return nil }
        do {
            let it: BacklogItem = try await app.api.post("api/workspaces/\(ws.id)/backlog/\(id)/assign", token: token,
                                                         body: AssignItem(assigneeId: to ?? 0))
            await load(app)
            return it
        } catch {
            app.handle(error)
            return nil
        }
    }

    /// Marks an item done (#130), with an optional note (#149).
    func close(_ app: AppModel, _ id: Int64, note: String = "") async {
        items.removeAll { $0.id == id }
        await act(app, "backlog/\(id)/close", CloseItem(note: note))
    }

    /// Reopens a done item (#149).
    func reopen(_ app: AppModel, _ id: Int64) async {
        items.removeAll { $0.id == id }
        await act(app, "backlog/\(id)/reopen", Empty())
    }

    /// Moves an open item within Up next. The order shows at once; the
    /// server's 1-based position counts open items only.
    func move(_ app: AppModel, open: [BacklogItem], from: IndexSet, to: Int) async {
        var ordered = open
        ordered.move(fromOffsets: from, toOffset: to)
        guard let i = from.first, let at = ordered.firstIndex(where: { $0.id == open[i].id }) else { return }
        let rest = items.filter { $0.status != "open" }
        items = rest + ordered
        await act(app, "backlog/\(open[i].id)/move", MoveItem(position: at + 1))
    }

    private func act(_ app: AppModel, _ path: String, _ body: some Encodable & Sendable) async {
        guard let token = app.token, let ws = app.selected else { return }
        do {
            let _: BacklogItem = try await app.api.post("api/workspaces/\(ws.id)/\(path)", token: token, body: body)
        } catch {
            app.handle(error)
        }
        await load(app)
    }

    /// Changes an item's title and details (#123). Returns the saved item.
    func update(_ app: AppModel, id: Int64, title: String, body: String) async -> BacklogItem? {
        guard let token = app.token, let ws = app.selected else { return nil }
        do {
            let it: BacklogItem = try await app.api.patch("api/workspaces/\(ws.id)/backlog/\(id)", token: token,
                                                          body: NewItem(title: title, body: body))
            await load(app)
            return it
        } catch {
            app.handle(error)
            return nil
        }
    }
}

/// No assignee means the caller; 0 means nobody.
struct AssignItem: Encodable, Sendable {
    var assigneeId: Int64? = nil
}

struct CloseItem: Encodable, Sendable {
    var note = ""
}

struct MoveItem: Encodable, Sendable {
    let position: Int
}

struct NewItem: Encodable, Sendable {
    let title: String
    let body: String
    /// For a new item (#146).
    var assigneeId: Int64? = nil
}

struct BacklogView: View {
    @Environment(AppModel.self) private var app
    @State private var backlog = BacklogModel()
    @State private var adding = false
    @State private var editing: BacklogItem?

    private var me: Int64? { app.participant?.id }

    var body: some View {
        @Bindable var backlog = backlog
        // The quiet list (#129): In progress, then Up next, in priority order.
        List {
            Picker("Show", selection: $backlog.filter) {
                ForEach(BacklogModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            let shown = backlog.shown
            if backlog.loaded && shown.isEmpty {
                if !backlog.search.isEmpty {
                    ContentUnavailableView.search(text: backlog.search)
                        .listRowSeparator(.hidden)
                } else {
                    ContentUnavailableView(empty, systemImage: "list.number")
                        .listRowSeparator(.hidden)
                }
            }
            if backlog.filter == .done {
                rows(shown)
            } else {
                section("In progress", shown.filter(\.inProgress))
                // Reordering only makes sense on the whole queue.
                section("Up next", shown.filter { $0.status == "open" },
                        movable: backlog.search.isEmpty)
            }
        }
        .searchable(text: $backlog.search, prompt: "Search titles")
        .listStyle(.plain)
        .overlay { if !backlog.loaded { ProgressView() } }
        .refreshable { await backlog.load(app) }
        .navigationDestination(for: Int64.self) { id in
            ItemDetailView(itemID: id, backlog: backlog)
        }
        .safeAreaInset(edge: .bottom) {
            Button("New item", systemImage: "plus") { adding = true }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $adding) {
            ItemSheet(backlog: backlog)
        }
        .sheet(item: $editing) { item in
            ItemSheet(backlog: backlog, item: item)
        }
        .task(id: "\(app.selectedID ?? "")-\(backlog.filter)-\(app.revision("backlog"))-\(app.revision("pr"))-\(app.revision("comment"))") {
            await backlog.load(app)
        }
    }

    private var empty: String {
        backlog.filter == .done ? "Nothing done yet" : "The backlog is empty"
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [BacklogItem], movable: Bool = false) -> some View {
        if !items.isEmpty {
            Section {
                rows(items).onMove(perform: movable ? { from, to in
                    Task { await backlog.move(app, open: items, from: from, to: to) }
                } : nil)
            } header: {
                Text("\(title) · \(items.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rows(_ items: [BacklogItem]) -> some DynamicViewContent {
        ForEach(items) { item in
            NavigationLink(value: item.id) {
                BacklogRow(item: item, assignee: item.assigneeId.flatMap { backlog.people[$0] })
            }
            .swipeActions(edge: .leading) {
                if item.status == "open" && (item.assigneeId == nil || item.assigneeId == me) {
                    Button("Start", systemImage: "play") {
                        Task { await backlog.start(app, item.id) }
                    }
                    .tint(.blue)
                } else if item.status != "done" && item.assigneeId != me {
                    Button("Take it", systemImage: "hand.raised") {
                        Task { await backlog.take(app, item.id) }
                    }
                    .tint(.blue)
                }
                if item.inProgress {
                    Button("Stop", systemImage: "pause") {
                        Task { await backlog.stop(app, item.id) }
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing) {
                if item.status == "done" {
                    Button("Reopen", systemImage: "arrow.uturn.backward") {
                        Task { await backlog.reopen(app, item.id) }
                    }
                } else {
                    Button("Done", systemImage: "checkmark") {
                        Task { await backlog.close(app, item.id) }
                    }
                    .tint(.green)
                }
            }
            .contextMenu {
                if let ws = app.selected {
                    Button("Copy link", systemImage: "link") {
                        UIPasteboard.general.url = link(ws.id, item.id)
                    }
                }
                Button("Edit", systemImage: "pencil") { editing = item }
                if item.status != "done" {
                    AssignMenu(item: item, backlog: backlog)
                }
            }
        }
    }

    /// The item on the web: the backlog with ?item=N open.
    private func link(_ ws: String, _ id: Int64) -> URL? {
        var c = URLComponents(url: API.server.appending(path: "w/\(ws)"), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "item", value: "\(id)")]
        return c?.url
    }
}

/// A quiet backlog row (#129): exactly two lines (the title, then the
/// number and when), with the counts and the assignee's avatar on the right.
struct BacklogRow: View {
    let item: BacklogItem
    let assignee: Participant?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("#\(item.id)").monospacedDigit()
                    if item.scheduleId != nil {
                        Image(systemName: "repeat").accessibilityLabel("Recurring")
                    }
                    if let when {
                        Text("·")
                        Text(when)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                if !item.prs.isEmpty {
                    count(item.prs.count, systemImage: "arrow.triangle.pull", label: "pull requests")
                }
                if item.commentCount > 0 {
                    count(item.commentCount, systemImage: "bubble", label: "comments")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let assignee {
                Text(assignee.emoji)
                    .font(.callout)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
                    .accessibilityLabel("Assigned to \(assignee.name)")
            }
        }
        .padding(.vertical, 2)
    }

    /// The second line's time: the lease left on work in progress, when a
    /// done item was closed, or when an open one last changed.
    private var when: String? {
        let now = Date()
        if item.inProgress {
            guard let ms = item.leaseExpiresAt else { return nil }
            let left = Date(timeIntervalSince1970: Double(ms) / 1000).timeIntervalSince(now)
            return left > 0 ? "\(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 1))) left" : "lease expiring"
        }
        if item.status == "done" {
            return item.closedAt.map { "closed " + Self.ago($0, now) }
        }
        return item.updatedAt.map { "updated " + Self.ago($0, now) }
    }

    private static func ago(_ ms: Int64, _ now: Date) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func count(_ n: Int, systemImage: String, label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text("\(n)").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) \(label)")
    }
}

struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let itemID: Int64
    let backlog: BacklogModel

    private var people: [Int64: Participant] { backlog.people }

    @State private var item: BacklogItem?
    @State private var comments: [Comment] = []
    @State private var editing = false
    @State private var closing = false
    @State private var closeNote = ""

    var body: some View {
        List {
            if let item {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.title3.bold())
                        HStack(spacing: 8) {
                            Text(item.statusLabel)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.12), in: Capsule())
                                .foregroundStyle(.tint)
                            if let a = item.assigneeId.flatMap({ people[$0] }) {
                                Text("\(a.emoji) \(a.name)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !item.body.isEmpty {
                            Text(richText(item.body, workspace: app.selectedID)).textSelection(.enabled)
                        }
                        if let note = item.closeNote, !note.isEmpty {
                            Text(richText(note, workspace: app.selectedID)).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !item.prs.isEmpty {
                    Section("Pull requests") {
                        ForEach(item.prs) { pr in
                            Button {
                                if let url = URL(string: pr.url) { openURL(url) }
                            } label: {
                                Label(pr.url.replacingOccurrences(of: "https://github.com/", with: ""),
                                      systemImage: "arrow.triangle.pull")
                            }
                        }
                    }
                }
                if !comments.isEmpty {
                    Section("Comments") {
                        ForEach(comments) { c in
                            MessageRow(message: c.asMessage, author: people[c.authorId])
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if item == nil { ProgressView() } }
        .navigationTitle("#\(itemID)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if item != nil {
                ToolbarItem(placement: .primaryAction) {
                    if let item { actions(item) }
                }
            }
        }
        .sheet(isPresented: $editing) {
            if let item {
                ItemSheet(backlog: backlog, item: item) { self.item = $0 }
            }
        }
        .alert("Close #\(itemID)", isPresented: $closing) {
            TextField("Note (optional)", text: $closeNote)
            Button("Cancel", role: .cancel) {}
            Button("Close item") { act { await backlog.close(app, itemID, note: closeNote) } }
        }
        .safeAreaInset(edge: .bottom) {
            if item != nil {
                Composer(placeholder: "Add a comment") { await addComment($0) }
            }
        }
        .task(id: "\(app.revision("backlog"))-\(app.revision("pr"))-\(app.revision("comment"))") {
            await load()
        }
    }

    /// What you can do to the item (#149): the same as on the web.
    private func actions(_ item: BacklogItem) -> some View {
        let me = app.participant?.id
        return Menu("Actions", systemImage: "ellipsis.circle") {
            Button("Edit", systemImage: "pencil") { editing = true }
            if item.status != "done" {
                AssignMenu(item: item, backlog: backlog) { self.item = $0 }
            }
            if item.inProgress {
                Button("Stop", systemImage: "pause") { act { await backlog.stop(app, itemID) } }
            } else if item.status == "open" && (item.assigneeId == nil || item.assigneeId == me) {
                Button("Start", systemImage: "play") { act { await backlog.start(app, itemID) } }
            }
            if item.status == "done" {
                Button("Reopen", systemImage: "arrow.uturn.backward") { act { await backlog.reopen(app, itemID) } }
            } else {
                Button("Close", systemImage: "checkmark") {
                    closeNote = ""
                    closing = true
                }
            }
        }
    }

    /// Runs an action on the item, then shows the result.
    private func act(_ action: @escaping () async -> Void) {
        Task {
            await action()
            await load()
        }
    }

    private func load() async {
        guard let token = app.token, let ws = app.selected else { return }
        let base = "api/workspaces/\(ws.id)/backlog/\(itemID)"
        if backlog.people.isEmpty {
            await backlog.load(app)
        }
        do {
            async let i: BacklogItem = app.api.get(base, token: token)
            async let c: [Comment] = app.api.get(base + "/comments", token: token)
            (item, comments) = try await (i, c)
            log.info("item \(itemID): \(item?.prs.count ?? 0) PRs, \(comments.count) comments")
        } catch {
            app.handle(error)
        }
    }

    private func addComment(_ body: String) async -> Bool {
        guard let token = app.token, let ws = app.selected else { return false }
        do {
            let c: Comment = try await app.api.post("api/workspaces/\(ws.id)/backlog/\(itemID)/comments", token: token,
                                                    body: NewComment(body: body))
            if !comments.contains(where: { $0.id == c.id }) {
                comments.append(c)
            }
            return true
        } catch {
            app.handle(error)
            return false
        }
    }
}

/// A submenu to assign an item to someone or to nobody (#149).
struct AssignMenu: View {
    @Environment(AppModel.self) private var app
    let item: BacklogItem
    let backlog: BacklogModel
    /// Gets the item once it's saved.
    var saved: (BacklogItem) -> Void = { _ in }

    var body: some View {
        Menu("Assign to", systemImage: "person") {
            Picker("Assign to", selection: Binding(get: { item.assigneeId }, set: { to in
                Task {
                    if let it = await backlog.assign(app, item.id, to: to) { saved(it) }
                }
            })) {
                Text("Unassigned").tag(Int64?.none)
                ForEach(backlog.people.values.sorted { $0.name < $1.name }) { p in
                    Text("\(p.emoji) \(p.name)").tag(Int64?.some(p.id))
                }
            }
            .pickerStyle(.inline)
        }
    }
}

struct NewComment: Encodable, Sendable {
    let body: String
}

/// Adds a backlog item (item nil) or edits one: a title and optional details.
struct ItemSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let backlog: BacklogModel
    var item: BacklogItem? = nil
    /// Gets the item once an edit is saved.
    var saved: (BacklogItem) -> Void = { _ in }
    @State private var title = ""
    @State private var details = ""
    @State private var assigneeId: Int64?
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title, axis: .vertical)
                    .focused($titleFocused)
                TextField("Details (optional)", text: $details, axis: .vertical)
                    .lineLimit(4...)
                Picker("Assignee", selection: $assigneeId) {
                    Text("Unassigned").tag(Int64?.none)
                    ForEach(backlog.people.values.sorted { $0.name < $1.name }) { p in
                        Text("\(p.emoji) \(p.name)").tag(Int64?.some(p.id))
                    }
                }
            }
            .navigationTitle(item.map { "Edit #\($0.id)" } ?? "New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "Add" : "Save") {
                        saving = true
                        Task {
                            let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let item {
                                if let it = await backlog.update(app, id: item.id, title: trimmedTitle, body: details) {
                                    var latest = it
                                    if assigneeId != item.assigneeId {
                                        latest = await backlog.assign(app, item.id, to: assigneeId) ?? it
                                    }
                                    saved(latest)
                                    dismiss()
                                }
                            } else if await backlog.add(app, title: trimmedTitle, body: details, assigneeId: assigneeId) {
                                dismiss()
                            }
                            saving = false
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || saving)
                }
            }
            .onAppear {
                if let item {
                    title = item.title
                    details = item.body
                    assigneeId = item.assigneeId
                } else {
                    titleFocused = true
                }
            }
        }
        .presentationDetents(item == nil ? [.medium, .large] : [.large])
    }
}
