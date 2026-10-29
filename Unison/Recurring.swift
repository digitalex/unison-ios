import SwiftUI

/// A recurring task (#111): due daily, or weekly on a weekday, at 00:00
/// server time, when it's added to the top of the backlog (#112).
struct Schedule: Decodable, Identifiable, Sendable {
    let id: Int64
    let title: String
    let body: String
    let cadence: String // "daily" or "weekly"
    let weekday: String? // "mon" … "sun", for weekly
    let nextDueAt: Int64

    var nextDue: Date { Date(timeIntervalSince1970: Double(nextDueAt) / 1000) }

    /// "Daily" or "Weekly on Monday".
    var cadenceText: String {
        guard cadence == "weekly", let day = weekday.flatMap(Weekday.init(rawValue:)) else { return "Daily" }
        return "Weekly on \(day.name)"
    }
}

/// The weekdays a weekly schedule can fall on, in the server's spelling.
enum Weekday: String, CaseIterable, Identifiable {
    case mon, tue, wed, thu, fri, sat, sun
    var id: Self { self }
    var name: String {
        ["mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday",
         "fri": "Friday", "sat": "Saturday", "sun": "Sunday"][rawValue]!
    }
}

struct ScheduleInput: Encodable, Sendable {
    let title: String
    let body: String
    let cadence: String
    let weekday: String?
}

/// The Recurring section's data: the workspace's schedules.
@MainActor
@Observable
final class RecurringModel {
    private(set) var schedules: [Schedule] = []
    private(set) var loaded = false
    private var shownPath: String?

    private func path(_ app: AppModel) -> String? {
        app.selected.map { "api/workspaces/\($0.id)/schedules" }
    }

    func load(_ app: AppModel) async {
        guard let token = app.token, let path = path(app) else { return }
        if shownPath != path {
            shownPath = path
            let cached: [Schedule]? = app.api.cached(path)
            schedules = cached ?? []
            loaded = cached != nil
        }
        do {
            schedules = try await app.api.get(path, token: token)
            loaded = true
        } catch let e as APIError where e.status == 404 {
            schedules = [] // a server from before recurring tasks
            loaded = true
        } catch {
            app.handle(error)
        }
    }

    /// Adds a schedule (id nil) or saves one. Returns whether it worked.
    func save(_ app: AppModel, id: Int64?, _ input: ScheduleInput) async -> Bool {
        guard let token = app.token, let path = path(app) else { return false }
        do {
            if let id {
                let _: Schedule = try await app.api.patch("\(path)/\(id)", token: token, body: input)
            } else {
                let _: Schedule = try await app.api.post(path, token: token, body: input)
            }
            await load(app)
            return true
        } catch {
            app.handle(error)
            return false
        }
    }

    func remove(_ app: AppModel, _ id: Int64) async {
        guard let token = app.token, let path = path(app) else { return }
        schedules.removeAll { $0.id == id }
        do {
            let _: Empty = try await app.api.delete("\(path)/\(id)", token: token)
        } catch {
            app.handle(error)
        }
        await load(app)
    }
}

/// The schedules, in the Backlog tab's Recurring section.
struct RecurringList: View {
    @Environment(AppModel.self) private var app
    let recurring: RecurringModel
    @Binding var editing: Schedule?

    var body: some View {
        if recurring.loaded && recurring.schedules.isEmpty {
            ContentUnavailableView("No recurring tasks", systemImage: "repeat",
                                   description: Text("Each run is added to the top of the backlog at midnight (server time)."))
                .listRowSeparator(.hidden)
        }
        ForEach(recurring.schedules) { sc in
            Button { editing = sc } label: { ScheduleRow(schedule: sc) }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        Task { await recurring.remove(app, sc.id) }
                    }
                }
        }
    }
}

struct ScheduleRow: View {
    let schedule: Schedule

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "repeat")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(schedule.title)
                Text("\(schedule.cadenceText) · next \(schedule.nextDue.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Adds a recurring task, or edits one.
struct ScheduleSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let recurring: RecurringModel
    let schedule: Schedule?
    @State private var title = ""
    @State private var details = ""
    @State private var weekly = false
    @State private var weekday = Weekday.mon
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .focused($titleFocused)
                    TextField("Details (optional)", text: $details, axis: .vertical)
                        .lineLimit(4...)
                }
                Section {
                    Picker("Repeats", selection: $weekly) {
                        Text("Daily").tag(false)
                        Text("Weekly").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if weekly {
                        Picker("On", selection: $weekday) {
                            ForEach(Weekday.allCases) { Text($0.name).tag($0) }
                        }
                    }
                } footer: {
                    Text("Each run is added to the top of the backlog at midnight, server time.")
                }
            }
            .navigationTitle(schedule == nil ? "New recurring task" : "Recurring task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(schedule == nil ? "Add" : "Save") {
                        saving = true
                        Task {
                            let input = ScheduleInput(title: trimmedTitle,
                                                      body: details.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      cadence: weekly ? "weekly" : "daily",
                                                      weekday: weekly ? weekday.rawValue : nil)
                            if await recurring.save(app, id: schedule?.id, input) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(trimmedTitle.isEmpty || saving)
                }
            }
            .onAppear {
                if let schedule {
                    title = schedule.title
                    details = schedule.body
                    weekly = schedule.cadence == "weekly"
                    weekday = schedule.weekday.flatMap(Weekday.init(rawValue:)) ?? .mon
                } else {
                    titleFocused = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
