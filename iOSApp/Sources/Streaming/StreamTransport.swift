import Foundation

protocol StreamTransport: AnyObject {
    var isConnected: Bool { get }
    func connect(host: String, port: UInt16) async throws
    func sendHandshake(_ packet: HandshakePacket) async throws
    func sendHeartbeat(_ packet: HeartbeatPacket) async throws
    func sendControl(_ packet: ControlPacket) async throws
    func sendStreamPacket(_ packet: StreamPacket) async throws
    func close()
}
