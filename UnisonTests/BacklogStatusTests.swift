import XCTest
@testable import Unison

/// Status and assignee are independent (#146).
final class BacklogStatusTests: XCTestCase {
    private func item(_ status: String, assignee: Int64? = nil) throws -> BacklogItem {
        let assigneeJSON = assignee.map(String.init) ?? "null"
        let json = """
        {"id":1,"title":"t","body":"","status":"\(status)","assignee_id":\(assigneeJSON),"close_note":null,"prs":[],"comment_count":0}
        """
        return try JSONDecoder.api.decode(BacklogItem.self, from: Data(json.utf8))
    }

    func testInProgress() throws {
        XCTAssertTrue(try item("in_progress").inProgress)
        XCTAssertTrue(try item("assigned", assignee: 2).inProgress, "servers from before #146")
        XCTAssertFalse(try item("open", assignee: 2).inProgress, "assigned but not started")
        XCTAssertFalse(try item("done").inProgress)
    }

    func testStatusLabel() throws {
        XCTAssertEqual(try item("in_progress").statusLabel, "In progress")
        XCTAssertEqual(try item("assigned").statusLabel, "In progress")
        XCTAssertEqual(try item("open").statusLabel, "Open")
        XCTAssertEqual(try item("done").statusLabel, "Done")
    }
}
