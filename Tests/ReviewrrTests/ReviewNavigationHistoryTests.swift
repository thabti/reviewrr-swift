import XCTest

final class ReviewNavigationHistoryTests: XCTestCase {
    func testBackForwardAndBranching() {
        var history = ReviewNavigationHistory()
        let first = ReviewNavigationHistory.Destination.pullRequest(PRReference(owner: "a", repo: "b", number: 1), .dotCom)
        let second = ReviewNavigationHistory.Destination.pullRequest(PRReference(owner: "a", repo: "b", number: 2), .dotCom)
        XCTAssertFalse(history.canGoBack)
        history.visit(first)
        history.visit(second)
        XCTAssertEqual(history.destination(offset: -1), first)
        history.commit(offset: -1)
        XCTAssertTrue(history.canGoForward)
        history.visit(.dashboard)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.destination(offset: -1), first)
    }

    func testDemoIsAResumableDestination() {
        var history = ReviewNavigationHistory()
        history.visit(.demo)
        history.commit(offset: -1)
        XCTAssertEqual(history.destination(offset: 1), .demo)
        history.commit(offset: 1)
        XCTAssertEqual(history.entries[history.index], .demo)
    }

    func testReloadAndUncommittedFailureDoNotChangeHistory() {
        var history = ReviewNavigationHistory()
        let target = ReviewNavigationHistory.Destination.pullRequest(PRReference(owner: "a", repo: "b", number: 1), .dotCom)
        history.visit(target)
        history.visit(target)
        XCTAssertEqual(history.entries.count, 2)
        _ = history.destination(offset: -1)
        XCTAssertEqual(history.index, 1)
        history.commit(offset: 10)
        XCTAssertEqual(history.index, 1)
    }
}
