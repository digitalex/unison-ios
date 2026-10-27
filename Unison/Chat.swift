import SwiftUI

/// The Chat tab's data: the workspace's messages and who wrote them.
@MainActor
@Observable
final class ChatModel {
    private(set) var messages: [Message] = []
    private(set) var people: [Int64: Participant] = [:]
    private(set) var loaded = false

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        do {
            async let msgs: [Message] = app.api.get("api/workspaces/\(ws.id)/messages", token: token)
            async let ppl: [Participant] = app.api.get("api/workspaces/\(ws.id)/participants", token: token)
            let (m, p) = try await (msgs, ppl)
            messages = m
            people = Dictionary(p.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            loaded = true
        } catch {
            app.handle(error)
        }
    }

    func send(_ body: String, parent: Int64?, action: Bool = false, app: AppModel) async -> Bool {
        guard let token = app.token, let ws = app.selected else { return false }
        do {
            let m: Message = try await app.api.post("api/workspaces/\(ws.id)/messages", token: token,
                                                    body: NewMessage(body: body, parentId: parent,
                                                                     actionRequired: action ? true : nil))
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
    @State private var chat = ChatModel()
    @State private var position = ScrollPosition(edge: .bottom)

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
                                    Label(replies.isEmpty ? "Reply" : replies.count == 1 ? "1 reply" : "\(replies.count) replies",
                                          systemImage: "arrowshape.turn.up.left")
                                        .font(.footnote.weight(.medium))
                                }
                                .padding(.leading, 44)
                            }
                        }
                    }
                    .padding()
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition($position)
            }
        }
        .onChange(of: chat.messages.last?.id) {
            withAnimation { position.scrollTo(edge: .bottom) }
        }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Message", canFlag: true) { await chat.send($0, parent: nil, action: $1, app: app) }
        }
        .navigationDestination(for: Int64.self) { id in
            ThreadView(chat: chat, actions: actions, parentID: id)
        }
        .task(id: "\(app.selectedID ?? "")-\(app.revision("message"))-\(app.revision("participant"))") {
            await chat.load(app)
        }
    }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var app
    let chat: ChatModel
    let actions: ActionsModel
    let parentID: Int64

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let parent = chat.messages.first(where: { $0.id == parentID }) {
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
        // Opened straight from a notification, the chat may not be loaded yet.
        .task { if !chat.loaded { await chat.load(app) } }
        .safeAreaInset(edge: .bottom) {
            Composer(placeholder: "Reply") { body, _ in await chat.send(body, parent: parentID, app: app) }
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
                Text(markdown(message.body))
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

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A growing text field with a send button, pinned to the bottom.
struct Composer: View {
    let placeholder: String
    /// Offers a "Needs action" flag: the message asks those it @mentions to act.
    var canFlag = false
    let send: (String, Bool) async -> Bool
    @State private var text = ""
    @State private var flagged = false
    @State private var sending = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if canFlag {
                Button {
                    flagged.toggle()
                } label: {
                    Image(systemName: flagged ? "flag.fill" : "flag")
                        .font(.system(size: 20))
                        .foregroundStyle(flagged ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .frame(width: 32, height: 38)
                }
                .accessibilityLabel(flagged ? "Needs action: on" : "Needs action: off")
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 20))
            Button {
                let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                sending = true
                Task {
                    if await send(body, flagged) {
                        text = ""
                        flagged = false
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
