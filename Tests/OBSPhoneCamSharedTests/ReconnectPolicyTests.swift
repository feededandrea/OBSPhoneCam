import XCTest
final class ReconnectPolicyTests: XCTestCase {
    func testBackoffDoesNotExceedMax() {
        let policy = ReconnectPolicy(baseDelay: 1, maxDelay: 5, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 5)
    }

    func testMaxAttempts() {
        let policy = ReconnectPolicy(baseDelay: 1, maxDelay: 5, jitter: 0, maxAttempts: 2)
        XCTAssertNotNil(policy.delay(forAttempt: 2))
        XCTAssertNil(policy.delay(forAttempt: 3))
    }
}
