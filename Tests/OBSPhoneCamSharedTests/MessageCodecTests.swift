import XCTest
final class MessageCodecTests: XCTestCase {
    func testHandshakeRoundtrip() throws {
        let codec = MessageCodec()
        let identity = DeviceIdentity(displayName: "Test iPhone", model: "iPhone", osVersion: "17")
        let packet = HandshakePacket(identity: identity, appVersion: "0.1", supportedCodecs: ["h264"], preferredQuality: .medium1080p)
        let envelope = try codec.envelope(.handshake, deviceID: identity.id, payload: packet)
        let decoded = try codec.payload(HandshakePacket.self, from: envelope)
        XCTAssertEqual(decoded.identity.id, identity.id)
        XCTAssertEqual(decoded.preferredQuality, .medium1080p)
    }
}
