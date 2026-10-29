import SwiftUI

/// The Chat tab's data: the workspace's messages and who wrote them.
@MainActor
@Observable
final class ChatModel {
    private(set) var messages: [Message] = []
    private(set) var people: [Int64: Participant] = [:]
    private(set) var loaded = false

    /// The workspace the messages are from.
    private var workspaceID: String?

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        let msgsPath = "api/workspaces/\(ws.id)/messages", pplPath = "api/workspaces/\(ws.id)/participants"
        // On first load or a workspace switch, show the cached copy while refetching.
        if workspaceID != ws.id {
            workspaceID = ws.id
            let m: [Message]? = app.api.cached(msgsPath), p: [Participant]? = app.api.cached(pplPath)
            show(m ?? [], p ?? [])
            loaded = m != nil
        }
        do {
            async let msgs: [Message] = app.api.get(msgsPath, token: token)
            async let ppl: [Participant] = app.api.get(pplPath, token: token)
            let (m, p) = try await (msgs, ppl)
            show(m, p)
            loaded = true
        } catch {
            app.handle(error)
        }
    }

    private func show(_ m: [Message], _ p: [Participant]) {
        messages = m
        people = Dictionary(p.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func send(_ body: String, parent: Int64?, app: AppModel) async -> Bool {
        guard let token = app.token, let ws = app.selected else { return false }
        do {
            let m: Message = try await app.api.post("api/workspaces/\(ws.id)/messages", token: token,
                                                    body: NewMessage(body: body, parentId: parent))
            if !messages.contains(where: { $0.id == m.id }) {
                messages.append(m)
            }
            return true
        } catch {
            app.handle(error)
            return false
        }
    }

    var topLevel: [Message] { messages.filter { $0.parentId == nil } }

    func replies(to id: Int64) -> [Message] { messages.filter { $0.parentId == id } }
}

struct ChatView: View {
    @Environment(AppModel.self) private var app
    let actions: ActionsModel
    /// Changes whenever the chat should jump: to a message, or the newest.
    var jump = ChatJump()
    @State private var chat = ChatModel()
    @State private var position = ScrollPosition(edge: .bottom)
    /// A jump that came before the messages loaded (the first visit).
    @State private var pendingJump: Int64?

    var body: some View {
        Group {
            if !chat.loaded {
                ProgressView()
            } else if chat.topLevel.isEmpty {
                ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Say hello to your team."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(chat.topLevel) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                MessageRow(message: m, author: chat.people[m.authorId], actions: actions)
                                let replies = chat.replies(to: m.id)
                                NavigationLink(value: m.id) {
                                    if replies.isEmpty {
                                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                                            .font(.footnote.weight(.medium))
                                    } else {
                                        ThreadSummary(replies: replies, people: chat.people)
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                                .padding(.leading, 44)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition($position)
            }
        }
        .onChange(of: chat.messages.last?.id) {
            // A pending jump waits for the load to finish (below).
            if pendingJump == nil { withAnimation { scroll(to: nil) } }
        }
        .onChange(of: jump) {
            if chat.loaded {
                withAnimation { scroll(to: jump.to) }
            } else {
                pendingJump = jump.to
            }
        }
        // The tab's first tap creates this view with the jump already set.
        .onAppear { pendingJump = jump.to }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Message") { await chat.send($0, parent: nil, app: app) }
        }
        .navigationDestination(for: Int64.self) { id in
            ThreadView(chat: chat, actions: actions, parentID: id)
        }
        .task(id: "\(app.selectedID ?? "")-\(app.revision("message"))-\(app.revision("participant"))") {
            await chat.load(app)
            if let target = pendingJump {
                // Let the list lay out first, or its bottom anchor wins.
                await Task.yield()
                pendingJump = nil
                withAnimation { scroll(to: target) }
            }
        }
    }

    /// Scrolls to a top-level message, or to the newest one.
    private func scroll(to id: Int64?) {
        if let id {
            position.scrollTo(id: id, anchor: .top)
        } else {
            position.scrollTo(edge: .bottom)
        }
    }
}

/// Where a tap on the Chat tab sends the chat: a top-level message, or the
/// newest one (`to` nil). `tap` makes each tap a change.
struct ChatJump: Equatable {
    var tap = 0
    var to: Int64?
}

/// Under a message with replies, as on the web (#87): who replied, how many
/// replies, and when the last one came. Tapping it opens the thread.
struct ThreadSummary: View {
    let replies: [Message]
    let people: [Int64: Participant]

    var body: some View {
        let authors = replies.map(\.authorId).reduce(into: [Int64]()) { if !$0.contains($1) { $0.append($1) } }
        HStack(spacing: 8) {
            HStack(spacing: -4) {
                ForEach(authors.prefix(4), id: \.self) { id in
                    Text(people[id]?.emoji ?? "👤")
                        .font(.caption)
                        .frame(width: 22, height: 22)
                        .background(.fill.secondary, in: Circle())
                }
            }
            Text(replies.count == 1 ? "1 reply" : "\(replies.count) replies")
                .font(.footnote.weight(.semibold))
            if let last = replies.last {
                Text("Last reply \(last.date, format: .relative(presentation: .named))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.fill.tertiary, in: Capsule())
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    let actions: ActionsModel
    let parentID: Int64

    /// Whether the chat was reloaded to find the thread's message.
    @State private var reloaded = false

    private var parent: Message? { chat.messages.first { $0.id == parentID } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let parent {
                    MessageRow(message: parent, author: chat.people[parent.authorId], actions: actions)
                    Divider()
                }
                ForEach(chat.replies(to: parentID)) { m in
                    MessageRow(message: m, author: chat.people[m.authorId], actions: actions)
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if parent == nil {
                if reloaded {
                    ContentUnavailableView("Message not found", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } else {
                    ProgressView()
                }
            }
        }
        // Opened straight from a notification, the chat may not be loaded yet,
        // or not have the new message.
        .task(id: parentID) {
            if parent == nil { await chat.load(app) }
            reloaded = true
        }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Reply") { await chat.send($0, parent: parentID, app: app) }
        }
    }
}

struct MessageRow: View {
    @Environment(AppModel.self) private var app
    let message: Message
    let author: Participant?
    var actions: ActionsModel? = nil

    private var needsMe: Bool { actions?.needsMe(message.id) ?? false }

    var body: some View {
        content
            .padding(needsMe ? 10 : 0)
            .background(needsMe ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 12))
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(author?.emoji ?? "👤")
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(author?.name ?? "Someone").font(.subheadline.weight(.semibold))
                    if let sponsor = author?.sponsor {
                        Text("agent of \(sponsor.displayName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text(message.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if needsMe {
                    HStack {
                        Label("Needs you", systemImage: "flag.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Done", systemImage: "checkmark") {
                            Task { await actions?.done(message.id, app: app) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                } else if actions?.doneHere.contains(message.id) == true {
                    HStack(spacing: 6) {
                        Label("Done", systemImage: "checkmark").foregroundStyle(.secondary)
                        Button("Undo") { Task { await actions?.undo(message.id, app: app) } }
                    }
                    .font(.caption)
                } else if message.actionRequired == true {
                    Label("Action requested", systemImage: "flag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let item = message.item {
                    Text("#\(item.id) \(item.title)")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.12), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Text(richText(message.body, workspace: app.selectedID))
                    .font(.body)
                    .textSelection(.enabled)
                if let reactions = message.reactions, !reactions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(reactions, id: \.emoji) { r in
                            Text("\(r.emoji) \(r.count)")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.fill.tertiary, in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

/// A growing text field with a send button, pinned to the bottom.
struct Composer: View {
    let placeholder: String
    let send: (String) async -> Bool
    @State private var text = ""
    @State private var sending = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
            Button {
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                sending = true
                Task {
                    if await send(body) {
                        text = ""
                    }
                    sending = false
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
