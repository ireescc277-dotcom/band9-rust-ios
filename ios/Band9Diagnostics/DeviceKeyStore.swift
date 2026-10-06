import Foundation
import Security

enum DeviceKeyStore {
    private static let service = "org.band9lab.device-auth"
    enum Failure: LocalizedError {
        case invalidKey, keychain(OSStatus), invalidImport
        var errorDescription: String? {
            switch self {
            case .invalidKey: return "设备密钥必须是 32 个十六进制字符（16 字节）。"
            case .keychain(let status): return "系统钥匙串操作失败（\(status)）。请解锁手机后重试。"
            case .invalidImport: return "文件未包含有效密钥。支持 32 位十六进制文本，或含 auth_key、authKey、key_hex 字段的 JSON。"
            }
        }
    }
    static func normalize(_ text: String) throws -> String {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.count == 32, Data(hex: key)?.count == 16 else { throw Failure.invalidKey }
        return key
    }
    private static func query(_ device: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: device.uuidString]
    }
    static func save(_ text: String, for device: UUID) throws {
        let key = try normalize(text)
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(device) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(device)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.keychain(added) }
        } else if status != errSecSuccess { throw Failure.keychain(status) }
    }
    static func load(for device: UUID) throws -> String? {
        var item = query(device)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Failure.keychain(status)
        }
        return try normalize(key)
    }
    static func remove(for device: UUID) throws {
        let status = SecItemDelete(query(device) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    struct ImportCandidate: Identifiable {
        let id = UUID()
        let label: String
        let key: String
        var peripheralID: UUID? = nil
        var deviceName: String? = nil
        var invalidPeripheralID = false
    }
    static func importCandidates(from data: Data) throws -> [ImportCandidate] {
        guard data.count <= 1_048_576 else { throw Failure.invalidImport }
        if let text = String(data: data, encoding: .utf8), let key = try? normalize(text) {
            return [ImportCandidate(label: "导入的设备密钥", key: key)]
        }
        let json = try JSONSerialization.jsonObject(with: data)
        var result = [ImportCandidate]()
        func visit(_ value: Any, depth: Int) {
            guard depth <= 8, result.count < 50 else { return }
            if let object = value as? [String: Any] {
                for field in ["auth_key", "authKey", "key_hex", "encryptKey", "encrypt_key"] {
                    if let text = object[field] as? String, let key = try? normalize(text) {
                        let name = (object["name"] as? String) ?? (object["device_name"] as? String) ?? "设备记录 \(result.count + 1)"
                        let address = (object["mac"] as? String) ?? (object["mac_address"] as? String)
                        let peripheralID = (object["peripheral_id"] as? String).flatMap(UUID.init(uuidString:))
                        let invalidID = object["peripheral_id"] != nil && peripheralID == nil
                        result.append(ImportCandidate(label: address.map { "\(name) · \($0)" } ?? name, key: key,
                                                      peripheralID: peripheralID, deviceName: name, invalidPeripheralID: invalidID))
                        break
                    }
                }
                for child in object.values where child is [String: Any] || child is [Any] { visit(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { visit(child, depth: depth + 1) }
            }
        }
        visit(json, depth: 0)
        guard !result.isEmpty else { throw Failure.invalidImport }
        return result
    }
}
