import SwiftUI

struct InboxEntry: Decodable, Identifiable, Sendable {
    let id: Int64
    let senderName: String
    let senderEmoji: String
    let body: String
    let item: Message.Item?
    let url: String?
    let createdAt: Int64

    var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000) }
}

/// The signed-in member's inbox: what needs them. It's loaded by the tab
/// view so the tab badge stays current from any tab.
@MainActor
@Observable
final class InboxModel {
    private(set) var entries: [InboxEntry] = []
    private(set) var loaded = false
    /// The entry just dismissed, offered for Undo.
    private(set) var dismissed: InboxEntry?

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        do {
            entries = try await app.api.get("api/workspaces/\(ws.id)/inbox", token: token)
            loaded = true
        } catch {
            app.handle(error)
        }
    }

    func dismiss(_ entry: InboxEntry, app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        entries.removeAll { $0.id == entry.id }
        dismissed = entry
        do {
            let _: InboxEntry = try await app.api.post("api/workspaces/\(ws.id)/inbox/\(entry.id)/dismiss", token: token)
        } catch {
            app.handle(error)
            await load(app)
        }
    }

    func undo(app: AppModel) async {
        guard let token = app.token, let ws = app.selected, let entry = dismissed else { return }
        dismissed = nil
        do {
            let _: InboxEntry = try await app.api.post("api/workspaces/\(ws.id)/inbox/\(entry.id)/restore", token: token)
            await load(app)
        } catch {
            app.handle(error)
        }
    }

    func forgetDismissed() { dismissed = nil }
}

struct InboxView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let inbox: InboxModel

    var body: some View {
        Group {
            if !inbox.loaded {
                ProgressView()
            } else if inbox.entries.isEmpty {
                ContentUnavailableView("Nothing needs you", systemImage: "checkmark.circle",
                                       description: Text("When a teammate or agent needs you to act, it shows up here."))
            } else {
                List(inbox.entries) { entry in
                    Button {
                        if let s = entry.url, let url = URL(string: s) { openURL(url) }
                    } label: {
                        InboxRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Dismiss", systemImage: "checkmark") {
                            Task { await inbox.dismiss(entry, app: app) }
                        }
                        .tint(.green)
                    }
                }
                .listStyle(.plain)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if inbox.dismissed != nil {
                HStack {
                    Text("Dismissed")
                    Spacer()
                    Button("Undo") { Task { await inbox.undo(app: app) } }
                        .fontWeight(.semibold)
                }
                .padding()
                .background(.bar, in: RoundedRectangle(cornerRadius: 14))
                .padding()
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    withAnimation { inbox.forgetDismissed() }
                }
            }
        }
        .animation(.default, value: inbox.dismissed?.id)
        .refreshable { await inbox.load(app) }
    }
}

struct InboxRow: View {
    let entry: InboxEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.senderEmoji)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(.fill.tertiary, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.senderName).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Text(entry.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.body)
                if entry.item != nil || entry.url != nil {
                    HStack(spacing: 6) {
                        if let item = entry.item {
                            Text("#\(item.id) \(item.title)").lineLimit(1)
                        }
                        if entry.url != nil {
                            Image(systemName: "arrow.up.right.square")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
