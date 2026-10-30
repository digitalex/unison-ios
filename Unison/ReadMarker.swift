import Foundation
import UserNotifications

/// The chat read marker (#122, server side in #124): how far you have read a
/// workspace's chat, kept on the server so reading anywhere clears the
/// phone's notifications for those messages.
enum ReadMarker {
    /// Whether a notification's payload is for a chat message in workspace
    /// that a marker at upTo covers. Comment notifications are about backlog
    /// items, not chat, so the marker leaves them alone.
    static func covers(_ userInfo: [AnyHashable: Any], workspace: String, upTo: Int64) -> Bool {
        guard userInfo["workspace_id"] as? String == workspace, userInfo["kind"] as? String != "comment_mention",
              let id = (userInfo["message_id"] as? NSNumber)?.int64Value else { return false }
        return id <= upTo
    }

    /// Removes the delivered notifications the marker covers.
    static func clear(workspace: String, upTo: Int64) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.deliveredNotifications()
            .filter { covers($0.request.content.userInfo, workspace: workspace, upTo: upTo) }
            .map(\.request.identifier)
        if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
            log.info("read: cleared \(ids.count) notifications up to \(upTo)")
        }
    }

    /// The workspaces with delivered chat notifications.
    static func notifiedWorkspaces() async -> Set<String> {
        Set(await UNUserNotificationCenter.current().deliveredNotifications().compactMap {
            $0.request.content.userInfo["workspace_id"] as? String
        })
    }
}

/// `{"up_to": N}`; the API converts the key's case.
struct ReadUpTo: Codable, Sendable {
    var upTo: Int64
}

extension AppModel {
    /// Marks the selected workspace's chat read up to message upTo, and
    /// clears the notifications that covers.
    func markRead(upTo: Int64) async {
        guard let token, let ws = selectedID, upTo > (readUpTo[ws] ?? 0) else { return }
        readUpTo[ws] = upTo
        do {
            let r: ReadUpTo = try await api.put("api/workspaces/\(ws)/read", token: token, body: ReadUpTo(upTo: upTo))
            readUpTo[ws] = max(readUpTo[ws] ?? 0, r.upTo)
            await ReadMarker.clear(workspace: ws, upTo: r.upTo)
        } catch let e as APIError where e.status == 404 || e.status == 405 {
            // A server from before the read marker.
        } catch {
            log.error("read: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears notifications for chat read elsewhere (the web, another
    /// device) since they arrived: on coming to the foreground, in case a
    /// silent push didn't get through.
    func clearReadNotifications() async {
        guard let token else { return }
        for ws in await ReadMarker.notifiedWorkspaces() where workspaces.contains(where: { $0.id == ws }) {
            do {
                let r: ReadUpTo = try await api.get("api/workspaces/\(ws)/read", token: token)
                readUpTo[ws] = max(readUpTo[ws] ?? 0, r.upTo)
                await ReadMarker.clear(workspace: ws, upTo: r.upTo)
            } catch {
                log.error("read: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
