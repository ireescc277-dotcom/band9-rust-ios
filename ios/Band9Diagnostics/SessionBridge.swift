import Foundation
import Security

enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
}

struct SessionReply: Decodable {
    struct Outbound: Decodable { let hex: String; let priority: UInt8 }
    struct Event: Decodable { let kind: String; let message: String; let data: JSONValue }
    let state: String
    let outbound: [Outbound]
    let events: [Event]
    let error: String?
}

final class RustSession {
    private var handle: UnsafeMutableRawPointer?
    private var pausedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    enum Failure: LocalizedError {
        case random, create, response, closed, malformedHex
        var errorDescription: String? {
            switch self {
            case .random: return "系统无法生成安全随机数，请重试。"
            case .create: return "无法创建手环认证会话，请检查设备密钥格式。"
            case .response: return "协议核心没有返回有效响应。"
            case .closed: return "连接会话已经结束。"
            case .malformedHex: return "协议核心返回的数据格式无效。"
            }
        }
    }

    init(key: String, mtu: Int) throws {
        var nonce = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else { throw Failure.random }
        let config: [String: Any] = ["key_hex": key, "phone_nonce_hex": Data(nonce).hex,
                                     "phone_name": "iPhone", "phone_api_level": 18,
                                     "region": "CN", "mtu": mtu]
        let encoded = try JSONSerialization.data(withJSONObject: config)
        let json = String(decoding: encoded, as: UTF8.self)
        handle = json.withCString { band9_session_create($0) }
        nonce.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        guard handle != nil else { throw Failure.create }
    }

    func command(_ operation: String, hex: String? = nil) throws -> SessionReply {
        guard let handle = handle else { throw Failure.closed }
        let elapsed = (pausedAt ?? ProcessInfo.processInfo.systemUptime) - pausedDuration
        var request: [String: Any] = ["op": operation, "now_ms": UInt64(max(0, elapsed) * 1000)]
        if let hex = hex { request["hex"] = hex }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        return try json.withCString { input in
            guard let output = band9_session_command(handle, input) else { throw Failure.response }
            defer { band9_string_free(output) }
            return try JSONDecoder().decode(SessionReply.self, from: Data(String(cString: output).utf8))
        }
    }

    func close() {
        if let handle = handle { band9_session_free(handle) }
        handle = nil
    }
    func pauseClock() { if pausedAt == nil { pausedAt = ProcessInfo.processInfo.systemUptime } }
    func resumeClock() {
        if let pausedAt = pausedAt { pausedDuration += ProcessInfo.processInfo.systemUptime - pausedAt }
        pausedAt = nil
    }
    deinit { close() }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2), hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(hex.count / 2)
        var position = hex.startIndex
        while position < hex.endIndex {
            let end = hex.index(position, offsetBy: 2)
            guard let byte = UInt8(hex[position..<end], radix: 16) else { return nil }
            result.append(byte)
            position = end
        }
        self.init(result)
    }
}
