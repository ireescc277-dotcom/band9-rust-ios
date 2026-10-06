import Combine
import Foundation

struct HealthRecord: Codable, Identifiable {
    let id: String
    let kind: String
    let startTime: UInt64
    let endTime: UInt64
    let value: Double?
    let unit: String
    let stage: String?
    let aggregation: String
    let sourceFileID: String

    enum CodingKeys: String, CodingKey {
        case id, kind, value, unit, stage, aggregation
        case startTime = "start_time", endTime = "end_time", sourceFileID = "source_file_id"
    }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(startTime)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(endTime)) }
    var localizedKind: String {
        switch kind {
        case "steps": return "步数"
        case "heart_rate": return "心率"
        case "spo2": return "血氧"
        case "sleep": return "睡眠"
        case "distance": return "距离"
        case "active_calories": return "活动能量"
        default: return kind
        }
    }
    var localizedStage: String {
        switch stage {
        case "awake": return "清醒"
        case "light": return "浅睡"
        case "deep": return "深睡"
        case "rem": return "快速眼动"
        default: return "睡眠时段"
        }
    }
    var localizedUnit: String {
        switch kind {
        case "steps": return "步"
        case "heart_rate": return "次/分"
        case "spo2": return "%"
        case "distance": return "米"
        case "active_calories": return "千卡"
        default: return unit
        }
    }
}

struct HealthFile: Codable {
    struct FileID: Codable {
        let hex: String
        let timestamp: UInt64
        let timezoneQuarters: Int
        let version: Int
        let fileType: Int
        let subtype: Int
        let detailType: Int
        enum CodingKeys: String, CodingKey {
            case hex, timestamp, version, subtype
            case timezoneQuarters = "timezone_quarters", fileType = "file_type", detailType = "detail_type"
        }
    }
    struct Parsed: Codable { let status: String; let reason: String?; let records: [HealthRecord] }
    let fileID: FileID
    let rawHex: String
    let crc32: UInt32
    let parsed: Parsed
    enum CodingKeys: String, CodingKey { case fileID = "file_id", rawHex = "raw_hex", crc32, parsed }
}

struct StoredHealthRecord: Codable, Identifiable {
    let deviceID: UUID
    let record: HealthRecord
    var id: String { deviceID.uuidString + ":" + record.id }
}

struct ArchivedHealthFile: Codable, Identifiable {
    let deviceID: UUID
    let fileID: String
    let receivedAt: Date
    let parseStatus: String
    let parseReason: String?
    let recordCount: Int
    let byteCount: Int
    var id: String { deviceID.uuidString + ":" + fileID }
}

final class HealthArchive: ObservableObject {
    @Published private(set) var records: [StoredHealthRecord] = []
    @Published private(set) var files: [ArchivedHealthFile] = []
    @Published private(set) var lastError: String?
    private let directory: URL
    private struct Index: Codable {
        let version: Int
        let records: [StoredHealthRecord]
        let files: [ArchivedHealthFile]
    }
    enum Failure: LocalizedError {
        case invalidFile, noFiles
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "健康文件的编号或原始数据无效，未保存。"
            case .noFiles: return "当前设备还没有可导出的健康文件。"
            }
        }
    }

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Band9Health", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            let indexURL = directory.appendingPathComponent("index.json")
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                records = index.records
                files = index.files
            }
        } catch { lastError = "读取本机健康档案失败：\(error.localizedDescription)" }
    }

    func records(for device: UUID?) -> [HealthRecord] {
        guard let device = device else { return [] }
        let received = Dictionary(files.filter { $0.deviceID == device }.map { ($0.fileID, $0.receivedAt) }, uniquingKeysWith: { first, _ in first })
        let candidates = records.filter { $0.deviceID == device }.map(\.record).sorted {
            (received[$0.sourceFileID] ?? .distantPast) > (received[$1.sourceFileID] ?? .distantPast)
        }
        var unique = [String: HealthRecord]()
        for record in candidates {
            let semanticID = "\(record.kind)|\(record.startTime)|\(record.endTime)|\(record.aggregation)"
            if unique[semanticID] == nil { unique[semanticID] = record }
        }
        return unique.values.sorted { $0.startTime > $1.startTime }
    }

    func ingest(_ file: HealthFile, device: UUID) throws {
        guard file.fileID.hex.count == 14, Data(hex: file.fileID.hex)?.count == 7,
              let raw = Data(hex: file.rawHex) else { throw Failure.invalidFile }
        let rawDirectory = directory.appendingPathComponent(device.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Persist evidence before the index. If an index update fails, the raw
        // file is still available locally for a later recovery/export.
        try encoder.encode(file).write(to: rawDirectory.appendingPathComponent(file.fileID.hex + ".json"),
                                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try raw.write(to: rawDirectory.appendingPathComponent(file.fileID.hex + ".bin"),
                      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var updatedRecords = records
        if file.parsed.status == "supported" {
            updatedRecords.removeAll { $0.deviceID == device && $0.record.sourceFileID == file.fileID.hex }
            let unique = Dictionary(file.parsed.records.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            updatedRecords.append(contentsOf: unique.values.map { StoredHealthRecord(deviceID: device, record: $0) })
            updatedRecords.sort { $0.record.startTime > $1.record.startTime }
        }
        var updatedFiles = files.filter { !($0.deviceID == device && $0.fileID == file.fileID.hex) }
        updatedFiles.append(ArchivedHealthFile(deviceID: device, fileID: file.fileID.hex, receivedAt: Date(),
                                              parseStatus: file.parsed.status, parseReason: file.parsed.reason,
                                              recordCount: file.parsed.records.count, byteCount: raw.count))
        updatedFiles.sort { $0.receivedAt > $1.receivedAt }
        try encoder.encode(Index(version: 1, records: updatedRecords, files: updatedFiles))
            .write(to: directory.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        records = updatedRecords
        files = updatedFiles
        lastError = nil
    }

    func export(device: UUID) throws -> URL {
        let deviceFiles = files.filter { $0.deviceID == device }
        guard !deviceFiles.isEmpty else { throw Failure.noFiles }
        struct Export: Encodable {
            let schemaVersion: Int
            let exportedAt: Date
            let deviceID: UUID
            let files: [HealthFile]
            let records: [HealthRecord]
        }
        let decoder = JSONDecoder()
        let rawDirectory = directory.appendingPathComponent(device.uuidString, isDirectory: true)
        let healthFiles = try deviceFiles.map {
            try decoder.decode(HealthFile.self, from: Data(contentsOf: rawDirectory.appendingPathComponent($0.fileID + ".json")))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let export = Export(schemaVersion: 1, exportedAt: Date(), deviceID: device, files: healthFiles, records: records(for: device))
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("band9-health-export.json")
        try encoder.encode(export).write(to: output, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return output
    }

    func steps(on date: Date, device: UUID?) -> Double? {
        let candidates = records(for: device).filter { $0.kind == "steps" && Calendar.current.isDate($0.date, inSameDayAs: date) }
        // Daily totals already include minute samples. Never sum both sources.
        let totals = candidates.filter { $0.aggregation == "daily_total" }.compactMap(\.value)
        if let total = totals.first { return total }
        let minuteRecords = candidates.filter { $0.aggregation == "minute" }
        let uniqueMinutes = Dictionary(minuteRecords.map { ("\($0.startTime)-\($0.endTime)", $0) }, uniquingKeysWith: { first, _ in first })
        let minutes = uniqueMinutes.values.compactMap(\.value)
        return minutes.isEmpty ? nil : minutes.reduce(0, +)
    }

    func sleepDuration(endingOn date: Date, device: UUID?) -> TimeInterval? {
        let calendar = Calendar.current
        guard let windowEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date),
              let windowStart = calendar.date(byAdding: .day, value: -1, to: windowEnd) else { return nil }
        let lowerBound = windowStart.timeIntervalSince1970
        let upperBound = windowEnd.timeIntervalSince1970
        // A sleep night spans midnight. Select all explicit sleep stages that
        // overlap yesterday 18:00 to today 18:00, then clip and union them.
        let intervals = records(for: device).filter {
            $0.kind == "sleep" && ["light", "deep", "rem"].contains($0.stage ?? "") &&
            $0.endTime > $0.startTime && TimeInterval($0.startTime) < upperBound && TimeInterval($0.endTime) > lowerBound
        }.map {
            (start: max(TimeInterval($0.startTime), lowerBound), end: min(TimeInterval($0.endTime), upperBound))
        }.sorted { $0.start < $1.start }
        guard let first = intervals.first else { return nil }
        var start = first.start
        var end = first.end
        var seconds: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.start <= end { end = max(end, interval.end) }
            else { seconds += end - start; start = interval.start; end = interval.end }
        }
        return seconds + end - start
    }
}
