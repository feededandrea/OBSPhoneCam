import Foundation

public enum MessageCodecError: Error, LocalizedError, Sendable {
    case encodeFailed(String)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .encodeFailed(let detail): return "No se pudo codificar el mensaje: \(detail)"
        case .decodeFailed(let detail): return "No se pudo decodificar el mensaje: \(detail)"
        }
    }
}

public struct MessageCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.encoder = e
        self.decoder = d
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try encoder.encode(value) }
        catch { throw MessageCodecError.encodeFailed(error.localizedDescription) }
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw MessageCodecError.decodeFailed(error.localizedDescription) }
    }

    public func envelope<T: Codable>(_ type: PhoneCamMessageType, deviceID: String?, payload: T) throws -> PhoneCamEnvelope {
        PhoneCamEnvelope(type: type, deviceID: deviceID, payload: try encode(payload))
    }

    public func payload<T: Codable>(_ type: T.Type, from envelope: PhoneCamEnvelope) throws -> T {
        try decode(type, from: envelope.payload)
    }
}
