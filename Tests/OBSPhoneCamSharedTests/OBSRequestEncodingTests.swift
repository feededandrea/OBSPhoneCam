import XCTest
final class OBSRequestEncodingTests: XCTestCase {
    func testSceneSwitchRequestEncoding() throws {
        let request = OBSRequest(op: 6, d: OBSRequestData(requestType: "SetCurrentProgramScene", requestData: ["sceneName": .string("Intro")]))
        let data = try JSONEncoder().encode(request)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("SetCurrentProgramScene"))
        XCTAssertTrue(text.contains("Intro"))
    }
}
