import Foundation
import Testing
@testable import Unison

struct RouteTests {
    @Test func pushPayloadOpensTheThreadRoot() throws {
        let route = try #require(Route(userInfo: ["workspace_id": "ws_1", "message_id": NSNumber(value: 269), "parent_id": NSNumber(value: 266)]))
        #expect(route.workspaceID == "ws_1")
        #expect(route.thread == 266)
    }

    @Test func topLevelMessageIsItsOwnThread() throws {
        let route = try #require(Route(userInfo: ["message_id": "42"]))
        #expect(route.thread == 42)
        #expect(route.itemID == nil)
    }

    @Test func itemComment() throws {
        let route = try #require(Route(userInfo: ["item_id": NSNumber(value: 7), "comment_id": NSNumber(value: 3)]))
        #expect(route.thread == nil)
        #expect(route.itemID == 7)
        #expect(route.commentID == 3)
    }

    @Test func payloadWithoutATargetIsIgnored() {
        #expect(Route(userInfo: ["workspace_id": "ws_1"]) == nil)
    }

    @Test func link() throws {
        let route = try #require(Route(url: URL(string: "unison://open?workspace_id=ws_1&message_id=5")!))
        #expect(route.workspaceID == "ws_1")
        #expect(route.thread == 5)
        #expect(Route(url: URL(string: "https://example.com/open?message_id=5")!) == nil)
    }
}

struct ResponseCacheTests {
    @Test func roundTripsAResponse() throws {
        let key = "test/\(UUID().uuidString)?status=done"
        ResponseCache.write(Data(#"[{"id":1,"name":"Ada","emoji":"🐬","sponsor":{"display_name":"Alex"}}]"#.utf8), key)
        let people: [Participant] = try #require(ResponseCache.read(key))
        #expect(people.first?.name == "Ada")
        #expect(people.first?.sponsor?.displayName == "Alex")
    }

    @Test func missingKeyIsNil() {
        let people: [Participant]? = ResponseCache.read("test/missing-\(UUID().uuidString)")
        #expect(people == nil)
    }
}

struct MessageTests {
    @Test func dateIsNeverInTheFuture() throws {
        let future = Int64(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let json = #"{"id":1,"author_id":2,"parent_id":null,"body":"hi","created_at":\#(future),"item":null,"reactions":null}"#
        let message = try JSONDecoder.api.decode(Message.self, from: Data(json.utf8))
        #expect(message.date <= .now)
    }
}

@Suite struct ItemLinkTests {
    private func links(_ s: String) -> [String] {
        richText(s, workspace: "ws_1").runs.compactMap { run in
            run.link.flatMap { $0.scheme == "unison" ? Route(url: $0)?.itemID.map(String.init) : nil }
        }
    }

    @Test func linksItemReferences() {
        #expect(links("see #97 and (#98).") == ["97", "98"])
    }

    @Test func skipsPullRequestsWordsAndCode() {
        #expect(links("PR #82, pull request #83, PRs #84") == [])
        #expect(links("a#1 b&#2 x/#3 #4a `#5`") == [])
    }

    @Test func keepsWorkspaceAndExistingLinks() {
        let text = richText("[docs](https://example.com/#6) #7", workspace: "ws_1")
        let urls = text.runs.compactMap(\.link)
        #expect(urls.count == 2)
        #expect(Route(url: urls[1])?.workspaceID == "ws_1")
    }
}

struct ReadMarkerTests {
    private func payload(_ ws: String, message: Int64?, kind: String = "mention") -> [AnyHashable: Any] {
        var p: [AnyHashable: Any] = ["workspace_id": ws, "kind": kind]
        if let message { p["message_id"] = NSNumber(value: message) }
        return p
    }

    @Test func coversChatMessagesUpToTheMarker() {
        #expect(ReadMarker.covers(payload("ws_1", message: 40), workspace: "ws_1", upTo: 42))
        #expect(ReadMarker.covers(payload("ws_1", message: 42, kind: "action"), workspace: "ws_1", upTo: 42))
        #expect(!ReadMarker.covers(payload("ws_1", message: 43), workspace: "ws_1", upTo: 42))
    }

    @Test func leavesOtherWorkspacesAndComments() {
        #expect(!ReadMarker.covers(payload("ws_2", message: 40), workspace: "ws_1", upTo: 42))
        #expect(!ReadMarker.covers(payload("ws_1", message: 40, kind: "comment_mention"), workspace: "ws_1", upTo: 42))
        #expect(!ReadMarker.covers(payload("ws_1", message: nil, kind: "comment_mention"), workspace: "ws_1", upTo: 42))
    }
}
