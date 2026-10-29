import Foundation
import Observation

/// The chat messages that ask the signed-in member to act and that they
/// haven't marked done (`GET …/actions`). It drives the Chat tab's badge
/// and the "Needs you" treatment in chat. It's loaded by the tab view so
/// the badge stays current from any tab.
@MainActor
@Observable
final class ActionsModel {
    private(set) var open: Set<Int64> = []
    /// Messages marked done in this session, which offer Undo.
    private(set) var doneHere: Set<Int64> = []
    /// The workspace `open` is from.
    private var workspaceID: String?

    var count: Int { open.count }

    func needsMe(_ id: Int64) -> Bool { open.contains(id) }

    func load(_ app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        let path = "api/workspaces/\(ws.id)/actions"
        if workspaceID != ws.id {
            workspaceID = ws.id
            let list: [Message]? = app.api.cached(path)
            open = Set((list ?? []).map(\.id))
        }
        do {
            let list: [Message] = try await app.api.get(path, token: token)
            open = Set(list.map(\.id))
        } catch let e as APIError where e.status == 404 {
            open = [] // a server from before actions
        } catch {
            app.handle(error)
        }
    }

    func done(_ id: Int64, app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        open.remove(id)
        doneHere.insert(id)
        do {
            let _: Message = try await app.api.post("api/workspaces/\(ws.id)/messages/\(id)/done", token: token)
        } catch {
            app.handle(error)
            await load(app)
        }
    }

    func undo(_ id: Int64, app: AppModel) async {
        guard let token = app.token, let ws = app.selected else { return }
        doneHere.remove(id)
        open.insert(id)
        do {
            let _: Message = try await app.api.delete("api/workspaces/\(ws.id)/messages/\(id)/done", token: token)
        } catch {
            app.handle(error)
            await load(app)
        }
    }
}
