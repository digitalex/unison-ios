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
