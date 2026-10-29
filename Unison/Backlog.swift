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
        case active = "Active", done = "Done", recurring = "Recurring"
        var id: Self { self }
    }

    var filter = Filter.active
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
    func add(_ app: AppModel, title: String, body: String) async -> Bool {
        guard let token = app.token, let ws = app.selected else { return false }
        do {
            let _: BacklogItem = try await app.api.post("api/workspaces/\(ws.id)/backlog", token: token,
                                                        body: NewItem(title: title, body: body))
            await load(app)
            return true
        } catch {
            app.handle(error)
            return false
        }
    }
}

struct NewItem: Encodable, Sendable {
    let title: String
    let body: String
}

struct BacklogView: View {
    @Environment(AppModel.self) private var app
    @State private var backlog = BacklogModel()
    @State private var recurring = RecurringModel()
    @State private var adding = false
    @State private var addingSchedule = false
    @State private var editingSchedule: Schedule?

    var body: some View {
        @Bindable var backlog = backlog
        List {
            Picker("Show", selection: $backlog.filter) {
                ForEach(BacklogModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            if backlog.filter == .recurring {
                RecurringList(recurring: recurring, editing: $editingSchedule)
            } else {
                if backlog.loaded && backlog.items.isEmpty {
                    ContentUnavailableView(backlog.filter == .done ? "Nothing done yet" : "The backlog is empty",
                                           systemImage: "list.number")
                        .listRowSeparator(.hidden)
                }
                ForEach(backlog.items) { item in
                    NavigationLink(value: item.id) {
                        BacklogRow(item: item, assignee: item.assigneeId.flatMap { backlog.people[$0] })
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay { if backlog.filter == .recurring ? !recurring.loaded : !backlog.loaded { ProgressView() } }
        .refreshable { await backlog.filter == .recurring ? recurring.load(app) : backlog.load(app) }
        .navigationDestination(for: Int64.self) { id in
            ItemDetailView(itemID: id, backlog: backlog)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if backlog.filter == .recurring {
                    Button("New recurring task", systemImage: "plus") { addingSchedule = true }
                } else {
                    Button("New item", systemImage: "plus") { adding = true }
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $adding) {
            NewItemSheet(backlog: backlog)
        }
        .sheet(isPresented: $addingSchedule) {
            ScheduleSheet(recurring: recurring, schedule: nil)
        }
        .sheet(item: $editingSchedule) { sc in
            ScheduleSheet(recurring: recurring, schedule: sc)
        }

        .task(id: "\(app.selectedID ?? "")-\(backlog.filter)-\(app.revision("backlog"))-\(app.revision("pr"))-\(app.revision("comment"))") {
            if backlog.filter != .recurring { await backlog.load(app) }
        }
        .task(id: "\(app.selectedID ?? "")-\(backlog.filter == .recurring)-\(app.revision("schedule"))") {
            if backlog.filter == .recurring { await recurring.load(app) }
        }
    }
}

struct BacklogRow: View {
    let item: BacklogItem
    let assignee: Participant?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("#\(item.id)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                HStack(spacing: 6) {
                    if item.scheduleId != nil {
                        Image(systemName: "repeat").accessibilityLabel("Recurring")
                    }
                    if let assignee {
                        Text("\(assignee.emoji) \(assignee.name)")
                    }
                    if !item.prs.isEmpty {
                        count(item.prs.count, systemImage: "arrow.triangle.pull")
                    }
                    if item.commentCount > 0 {
                        count(item.commentCount, systemImage: "bubble")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func count(_ n: Int, systemImage: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            Text("\(n)")
        }
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

    var body: some View {
        List {
            if let item {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.title3.bold())
                        HStack(spacing: 8) {
                            Text(item.status.capitalized)
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
        .safeAreaInset(edge: .bottom) {
            if item != nil {
                Composer(placeholder: "Add a comment") { await addComment($0) }
            }
        }
        .task(id: "\(app.revision("backlog"))-\(app.revision("pr"))-\(app.revision("comment"))") {
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

struct NewComment: Encodable, Sendable {
    let body: String
}

/// Adds a backlog item: a title and optional details.
struct NewItemSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let backlog: BacklogModel
    @State private var title = ""
    @State private var details = ""
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
            }
            .navigationTitle("New item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
                            if await backlog.add(app, title: trimmedTitle, body: details) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || saving)
                }
            }
            .onAppear { titleFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
