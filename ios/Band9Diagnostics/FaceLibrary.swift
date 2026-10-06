import Foundation
import SwiftUI

enum WatchFaceKind: String, CaseIterable, Codable, Identifiable {
    case digital, split, analog, solar, modular, activity

    var id: String { rawValue }
    var title: String {
        switch self {
        case .digital: return "数字焦点"
        case .split: return "双色时刻"
        case .analog: return "经典指针"
        case .solar: return "日光弧线"
        case .modular: return "信息模块"
        case .activity: return "步履圆环"
        }
    }
    var summary: String {
        switch self {
        case .digital: return "醒目的大数字，让时间成为主角。"
        case .split: return "上下双色，呈现简洁而鲜明的节奏。"
        case .analog: return "精细刻度和纤细指针，保留看时间的仪式感。"
        case .solar: return "温暖渐变与柔和弧线，描绘时间的流动。"
        case .modular: return "时间、步数和电量，整齐地聚在一起。"
        case .activity: return "用今天的真实步数，点亮一道进度圆环。"
        }
    }
}

enum WatchFacePalette: String, CaseIterable, Codable, Identifiable {
    case orange, mint, blue, violet, rose, silver
    var id: String { rawValue }
    var title: String {
        switch self {
        case .orange: return "日落橙"
        case .mint: return "薄荷绿"
        case .blue: return "晴空蓝"
        case .violet: return "鸢尾紫"
        case .rose: return "珊瑚粉"
        case .silver: return "月光银"
        }
    }
    var color: Color {
        switch self {
        case .orange: return Color(red: 1, green: 0.43, blue: 0.18)
        case .mint: return Color(red: 0.35, green: 0.91, blue: 0.74)
        case .blue: return Color(red: 0.35, green: 0.73, blue: 1)
        case .violet: return Color(red: 0.73, green: 0.58, blue: 1)
        case .rose: return Color(red: 1, green: 0.43, blue: 0.57)
        case .silver: return Color(red: 0.89, green: 0.91, blue: 0.95)
        }
    }
}

enum WatchFaceStyle: String, CaseIterable, Codable, Identifiable {
    case rounded, crisp
    var id: String { rawValue }
    var title: String { self == .rounded ? "圆润" : "硬朗" }
    var fontDesign: Font.Design { self == .rounded ? .rounded : .default }
}

enum WatchFaceComplication: String, CaseIterable, Codable, Identifiable {
    case date, steps, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .date: return "日期"
        case .steps: return "步数"
        case .battery: return "电量"
        }
    }
}

struct WatchFaceDesign: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: WatchFaceKind
    var palette: WatchFacePalette
    var style: WatchFaceStyle
    var complication: WatchFaceComplication

    var title: String { kind.title }

    static let catalog: [WatchFaceDesign] = [
        WatchFaceDesign(id: UUID(uuidString: "14DB0DF2-6AAA-47ED-BDA1-000000000001")!, kind: .digital,
                        palette: .orange, style: .rounded, complication: .date),
        WatchFaceDesign(id: UUID(uuidString: "14DB0DF2-6AAA-47ED-BDA1-000000000002")!, kind: .split,
                        palette: .violet, style: .crisp, complication: .date),
        WatchFaceDesign(id: UUID(uuidString: "14DB0DF2-6AAA-47ED-BDA1-000000000003")!, kind: .analog,
                        palette: .silver, style: .rounded, complication: .date),
        WatchFaceDesign(id: UUID(uuidString: "14DB0DF2-6AAA-47ED-BDA1-000000000004")!, kind: .solar,
                        palette: .orange, style: .rounded, complication: .battery),
        WatchFaceDesign(id: UUID(uuidString: "14DB0DF2-6AAA-47ED-BDA1-000000000005")!, kind: .modular,
                        palette: .blue, style: .crisp, complication: .steps),
        WatchFaceDesign(id: UUID(uuidString: "14DB0DF2-6AAA-47ED-BDA1-000000000006")!, kind: .activity,
                        palette: .mint, style: .rounded, complication: .steps)
    ]
}

final class FaceLibrary: ObservableObject {
    @Published private(set) var faces: [WatchFaceDesign] = []
    private let defaults: UserDefaults
    private let storageKey = "band9.watch-face-previews.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey), data.count < 256_000,
           let saved = try? JSONDecoder().decode([WatchFaceDesign].self, from: data) {
            var known = Set<UUID>()
            faces = saved.filter { known.insert($0.id).inserted }.prefix(50).map { $0 }
        }
    }

    @discardableResult
    func save(_ face: WatchFaceDesign) -> WatchFaceDesign {
        if let index = faces.firstIndex(where: { $0.id == face.id }) {
            faces[index] = face
            persist()
            return face
        }
        if let matching = faces.first(where: {
            $0.kind == face.kind && $0.palette == face.palette &&
                $0.style == face.style && $0.complication == face.complication
        }) { return matching }
        var saved = face
        saved.id = UUID()
        faces.insert(saved, at: 0)
        faces = Array(faces.prefix(50))
        persist()
        return saved
    }

    func remove(_ id: UUID) {
        faces.removeAll { $0.id == id }
        persist()
    }

    func contains(_ id: UUID) -> Bool { faces.contains { $0.id == id } }

    private func persist() {
        guard let data = try? JSONEncoder().encode(faces) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
