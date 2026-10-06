import Foundation

struct CoreDiagnosis: Codable {
    let coreVersion: String
    let profile: String
    let summary: String
    let warnings: [String]
    let suggestedNotifyUUID: String?
    let suggestedWriteUUID: String?

    enum CodingKeys: String, CodingKey {
        case coreVersion = "core_version"
        case profile, summary, warnings
        case suggestedNotifyUUID = "suggested_notify_uuid"
        case suggestedWriteUUID = "suggested_write_uuid"
    }
}

enum RustBridge {
    private struct Input: Encodable {
        struct Service: Encodable {
            struct Characteristic: Encodable {
                let uuid: String
                let properties: [String]
            }
            let uuid: String
            let characteristics: [Characteristic]
        }
        let services: [Service]
    }

    enum BridgeError: LocalizedError {
        case invalidInput, missingResult

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "无法准备服务诊断数据。"
            case .missingResult: return "Rust 核心未返回诊断结果。"
            }
        }
    }

    static var version: String {
        guard let pointer = band9_core_version() else { return "未知" }
        return String(cString: pointer)
    }

    static func diagnose(services: [ServiceSnapshot]) throws -> CoreDiagnosis {
        let input = Input(services: services.map { service in
            Input.Service(uuid: service.uuid, characteristics: service.characteristics.map {
                Input.Service.Characteristic(uuid: $0.uuid, properties: $0.properties)
            })
        })
        let data = try JSONEncoder().encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw BridgeError.invalidInput
        }
        return try json.withCString { inputPointer in
            guard let resultPointer = band9_diagnose_json(inputPointer) else {
                throw BridgeError.missingResult
            }
            defer { band9_string_free(resultPointer) }
            let result = Data(String(cString: resultPointer).utf8)
            return try JSONDecoder().decode(CoreDiagnosis.self, from: result)
        }
    }
}
