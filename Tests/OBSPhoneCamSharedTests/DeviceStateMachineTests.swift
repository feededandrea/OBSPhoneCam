import XCTest
final class DeviceStateMachineTests: XCTestCase {
    func testConnectionStateRecoverableFlags() {
        XCTAssertTrue(ConnectionState.disconnected.isRecoverable)
        XCTAssertTrue(ConnectionState.degraded.isRecoverable)
        XCTAssertFalse(ConnectionState.streaming.isRecoverable)
    }
}
