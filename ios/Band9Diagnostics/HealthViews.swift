import Charts
import SwiftUI

/// A destination in the main Watch-style navigation stack.
struct HealthOverviewView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    var showConnections = false
    @State private var selectedDate = Date()

    private var records: [HealthRecord] { archive.records(for: model.currentDeviceID) }
    private var dayRecords: [HealthRecord] { BandHealthReading.on(selectedDate, in: records) }
    private var heartRecords: [HealthRecord] {
        dayRecords.filter { $0.kind == "heart_rate" && $0.value?.isFinite == true }
            .sorted { $0.startTime < $1.startTime }
    }
    private var latestOxygen: HealthRecord? {
        dayRecords.first { $0.kind == "spo2" && $0.value?.isFinite == true }
    }
    private var weekSteps: [BandHealthDay] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        let deviceRecords = records
        return (-6...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return BandHealthDay(date: day, value: BandHealthReading.total("steps", on: day, in: deviceRecords))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BandHealthDateControl(date: $selectedDate)
                if showConnections { syncCard }
                activityCard
                HStack(alignment: .top, spacing: 12) {
                    compactMetric("距离", symbol: "location.fill", kind: "distance", unit: "公里", scale: 0.001)
                    compactMetric("活动能量", symbol: "flame.fill", kind: "active_calories", unit: "千卡", scale: 1)
                }
                heartCard
                oxygenCard
                sleepCard
                NavigationLink {
                    HealthRecordsView(model: model, archive: archive, initialDate: selectedDate)
                } label: {
                    HStack {
                        Label("显示所有健康记录", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(18)
                    .background(BandHealthStyle.card, in: RoundedRectangle(cornerRadius: 18))
                }
                if let error = archive.lastError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.red)
                }
                Text("健康记录保存在这台 iPhone，尚未写入 Apple 健康。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("健康")
        .navigationBarTitleDisplayMode(.large)
    }

    private var syncCard: some View {
        BandHealthCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: model.isAuthenticated ? "checkmark.circle.fill" : "applewatch")
                    .foregroundStyle(model.isAuthenticated ? Color.green : BandHealthStyle.accent)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.isAuthenticated ? "手环已连接" : "连接手环以更新记录")
                        .font(.subheadline.weight(.semibold))
                    Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.isSyncing {
                    ProgressView().tint(BandHealthStyle.accent)
                        .accessibilityLabel("正在同步健康记录")
                } else {
                    Button(model.isAuthenticated ? "同步" : "连接") {
                        if model.isAuthenticated { model.syncHealth() }
                        else { model.reconnect() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.currentDeviceID == nil)
                }
            }
        }
    }

    private var activityCard: some View {
        let total = BandHealthReading.total("steps", on: selectedDate, in: records)
        let days = weekSteps
        return BandHealthCard {
            metricHeading("步数", symbol: "figure.walk", color: BandHealthStyle.accent)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(total.map { BandHealthReading.number($0, decimals: 0) } ?? "—")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5).lineLimit(1)
                Text("步").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            if days.contains(where: { $0.value != nil }) {
                Chart(days) { day in
                    if let value = day.value {
                        BarMark(x: .value("日期", day.date, unit: .day), y: .value("步数", value))
                            .foregroundStyle(Calendar.current.isDate(day.date, inSameDayAs: selectedDate)
                                             ? BandHealthStyle.accent : BandHealthStyle.accent.opacity(0.35))
                            .cornerRadius(4)
                            .accessibilityLabel(day.date.formatted(date: .abbreviated, time: .omitted))
                            .accessibilityValue("\(BandHealthReading.number(value, decimals: 0)) 步")
                    }
                }
                .chartXScale(domain: chartDateRange)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 130)
                Text("截至所选日期的 7 天 · 空白表示暂无记录")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                emptyReading("这一天还没有步数记录")
            }
        }
    }

    private var chartDateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: selectedDate)
        let start = calendar.date(byAdding: .day, value: -6, to: end) ?? end
        let nextDay = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        return start...nextDay
    }

    private func compactMetric(_ title: String, symbol: String, kind: String, unit: String, scale: Double) -> some View {
        let total = BandHealthReading.total(kind, on: selectedDate, in: records)
        return BandHealthCard {
            metricHeading(title, symbol: symbol, color: BandHealthStyle.accent)
            Text(total.map { BandHealthReading.number($0 * scale, decimals: kind == "distance" ? 2 : 0) } ?? "—")
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5).lineLimit(1)
            Text(total == nil ? "暂无记录" : unit)
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heartCard: some View {
        let samples = heartRecords
        let latest = samples.last
        return BandHealthCard {
            metricHeading("心率", symbol: "heart.fill", color: .pink)
            if let record = latest, let value = record.value {
                valueLine(BandHealthReading.number(value, decimals: 0), unit: "次/分")
                Text("最近一次 · \(record.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if samples.count > 1 {
                    Chart(samples) { sample in
                        if let sampleValue = sample.value {
                            PointMark(x: .value("时间", sample.date), y: .value("心率", sampleValue))
                                .foregroundStyle(.pink).symbolSize(20)
                        }
                    }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .frame(height: 135)
                }
                recordsLink("查看心率记录", kind: "heart_rate")
            } else {
                emptyReading("这一天还没有心率记录", detail: "手环测量后，同步即可在这里查看。")
            }
        }
    }

    private var oxygenCard: some View {
        BandHealthCard {
            metricHeading("血氧", symbol: "drop.fill", color: .cyan)
            if let record = latestOxygen, let value = record.value {
                valueLine(BandHealthReading.number(value, decimals: 0), unit: "%")
                Text("最近一次 · \(record.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                recordsLink("查看血氧记录", kind: "spo2")
            } else {
                emptyReading("这一天还没有血氧记录", detail: "只显示手环实际测得并同步的结果。")
            }
        }
    }

    private var sleepCard: some View {
        let duration = archive.sleepDuration(endingOn: selectedDate, device: model.currentDeviceID)
        return BandHealthCard {
            metricHeading("睡眠", symbol: "bed.double.fill", color: .indigo)
            if let duration = duration {
                Text(BandHealthReading.duration(duration))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("前一天 18:00 至所选日期 18:00 的睡眠时长")
                    .font(.caption).foregroundStyle(.secondary)
                recordsLink("查看睡眠记录", kind: "sleep")
            } else {
                emptyReading("还没有这一晚的睡眠记录", detail: "佩戴手环入睡后，再同步查看。")
            }
        }
    }

    private func metricHeading(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
    }

    private func valueLine(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded))
            Text(unit).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func emptyReading(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if let detail = detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 5)
    }

    private func recordsLink(_ title: String, kind: String) -> some View {
        NavigationLink {
            HealthRecordsView(model: model, archive: archive, initialKind: kind, initialDate: selectedDate)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
            }
            .font(.footnote.weight(.medium))
            .padding(.top, 6)
        }
    }
}

/// Date filtering keeps every archived day reachable without a global record cap.
struct HealthRecordsView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @State private var selectedDate: Date
    @State private var selectedKind: String

    init(model: BluetoothModel, archive: HealthArchive, initialKind: String = "all", initialDate: Date? = nil) {
        _model = ObservedObject(wrappedValue: model)
        _archive = ObservedObject(wrappedValue: archive)
        _selectedKind = State(initialValue: initialKind)
        let latest = archive.records(for: model.currentDeviceID).first { initialKind == "all" || $0.kind == initialKind }
        _selectedDate = State(initialValue: initialDate ?? latest.map { BandHealthReading.preferredDate(for: $0) } ?? Date())
    }

    private var records: [HealthRecord] { archive.records(for: model.currentDeviceID) }
    private var filteredRecords: [HealthRecord] {
        records.filter { record in
            guard selectedKind == "all" || record.kind == selectedKind else { return false }
            if record.kind == "sleep" {
                return BandHealthReading.overlapsSleepNight(record, endingOn: selectedDate)
            }
            return Calendar.current.isDate(record.date, inSameDayAs: selectedDate)
        }
    }
    private var kinds: [(id: String, label: String)] {
        [("all", "全部"), ("steps", "步数"), ("distance", "距离"), ("active_calories", "能量"),
         ("heart_rate", "心率"), ("spo2", "血氧"), ("sleep", "睡眠")]
    }

    var body: some View {
        let visibleRecords = filteredRecords
        List {
            Section {
                BandHealthDateControl(date: $selectedDate)
                Picker("记录类型", selection: $selectedKind) {
                    ForEach(kinds, id: \.id) { kind in Text(kind.label).tag(kind.id) }
                }
                .pickerStyle(.menu)
            }
            .listRowBackground(BandHealthStyle.card)

            if visibleRecords.isEmpty {
                Section {
                    ContentUnavailableView("这一天暂无记录", systemImage: "calendar.badge.clock",
                                           description: Text(records.isEmpty ? "连接手环并同步，健康记录会保存在这里。" : "可以切换日期或记录类型，查看已同步的数据。"))
                        .listRowBackground(Color(uiColor: .systemGroupedBackground))
                    if let latest = records.first(where: { selectedKind == "all" || $0.kind == selectedKind }),
                       !Calendar.current.isDate(BandHealthReading.preferredDate(for: latest), inSameDayAs: selectedDate) {
                        Button("查看最近有记录的一天") { selectedDate = BandHealthReading.preferredDate(for: latest) }
                            .listRowBackground(BandHealthStyle.card)
                    }
                }
            } else {
                Section {
                    ForEach(visibleRecords) { record in
                        NavigationLink {
                            BandHealthRecordDetail(record: record)
                        } label: {
                            BandHealthRecordRow(record: record)
                        }
                        .listRowBackground(BandHealthStyle.card)
                    }
                } header: {
                    Text("\(selectedDate.formatted(.dateTime.month().day())) · \(visibleRecords.count) 条记录")
                } footer: {
                    Text("每日累计和分时记录分别展示。睡眠以当天 18:00 为界，包含前一晚的记录。")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("健康记录")
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: model.currentDeviceID) { _, _ in
            let latest = records.first { selectedKind == "all" || $0.kind == selectedKind }
            selectedDate = latest.map { BandHealthReading.preferredDate(for: $0) } ?? Date()
        }
    }
}

private struct BandHealthRecordRow: View {
    let record: HealthRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BandHealthReading.symbol(record.kind))
                .font(.body.weight(.semibold))
                .foregroundStyle(BandHealthReading.color(record.kind))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.kind == "sleep" ? record.localizedStage : record.localizedKind)
                    .font(.subheadline.weight(.medium))
                Text(record.aggregation == "daily_total" ? "当日累计" : record.date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(BandHealthReading.recordValue(record))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 5)
    }
}

private struct BandHealthRecordDetail: View {
    let record: HealthRecord

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label(record.kind == "sleep" ? record.localizedStage : record.localizedKind,
                          systemImage: BandHealthReading.symbol(record.kind))
                        .foregroundStyle(BandHealthReading.color(record.kind))
                    Text(BandHealthReading.recordValue(record))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                }
                .padding(.vertical, 12)
                .listRowBackground(BandHealthStyle.card)
            }
            Section {
                LabeledContent("开始时间", value: record.date.formatted(date: .abbreviated, time: .shortened))
                if record.endTime > record.startTime {
                    LabeledContent("结束时间", value: record.endDate.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("记录方式", value: BandHealthReading.aggregationName(record.aggregation))
                LabeledContent("数据来源", value: "小米手环")
            }
            .listRowBackground(BandHealthStyle.card)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BandHealthDateControl: View {
    @Binding var date: Date

    var body: some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BandHealthStyle.accent)
            .accessibilityLabel("前一天")
            Spacer(minLength: 0)
            DatePicker("查看日期", selection: $date, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
                .accessibilityLabel("查看日期")
            Spacer(minLength: 0)
            Button { move(1) } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 40)
            }
            .buttonStyle(.plain)
            .foregroundStyle(BandHealthStyle.accent)
            .accessibilityLabel("后一天")
        }
    }

    private func move(_ days: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: days, to: date) { date = next }
    }
}

private struct BandHealthCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(BandHealthStyle.card, in: RoundedRectangle(cornerRadius: 20))
    }
}

private enum BandHealthStyle {
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let accent = Color.accentColor
}

private struct BandHealthDay: Identifiable {
    let date: Date
    let value: Double?
    var id: Date { date }
}

/// Read-only presentation calculations; persistence and archive deduplication remain unchanged.
private enum BandHealthReading {
    static func on(_ date: Date, in records: [HealthRecord]) -> [HealthRecord] {
        records.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    static func total(_ kind: String, on date: Date, in records: [HealthRecord]) -> Double? {
        let candidates = on(date, in: records).filter { $0.kind == kind && $0.value?.isFinite == true }
        // A daily total includes its minute records, so they must not be added together.
        if let total = candidates.first(where: { $0.aggregation == "daily_total" })?.value { return total }
        let minutes = candidates.filter { $0.aggregation == "minute" }
        let unique = Dictionary(minutes.map { ("\($0.startTime)|\($0.endTime)", $0) }, uniquingKeysWith: { first, _ in first })
        guard !unique.isEmpty else { return nil }
        return unique.values.compactMap(\.value).reduce(0, +)
    }

    static func overlapsSleepNight(_ record: HealthRecord, endingOn date: Date) -> Bool {
        let calendar = Calendar.current
        guard let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: date),
              let start = calendar.date(byAdding: .day, value: -1, to: end) else { return false }
        return record.date < end && record.endDate > start
    }

    static func preferredDate(for record: HealthRecord) -> Date {
        guard record.kind == "sleep" else { return record.date }
        let calendar = Calendar.current
        guard calendar.component(.hour, from: record.date) >= 18 else { return record.date }
        return calendar.date(byAdding: .day, value: 1, to: record.date) ?? record.date
    }

    static func number(_ value: Double, decimals: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...decimals)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, (seconds / 60).rounded(.down))
        let hours = (minutes / 60).rounded(.down)
        let remainder = minutes.truncatingRemainder(dividingBy: 60)
        if hours < 1 { return "\(number(remainder, decimals: 0)) 分钟" }
        return "\(number(hours, decimals: 0)) 小时 \(number(remainder, decimals: 0)) 分钟"
    }

    static func recordValue(_ record: HealthRecord) -> String {
        if record.kind == "sleep" {
            let seconds = record.endTime >= record.startTime ? record.endTime - record.startTime : 0
            return duration(TimeInterval(seconds))
        }
        guard let value = record.value, value.isFinite else { return "暂无数值" }
        if record.kind == "distance", value >= 1_000 {
            return "\(number(value / 1_000, decimals: 2)) 公里"
        }
        return "\(number(value, decimals: record.kind == "active_calories" ? 1 : 0)) \(record.localizedUnit)"
    }

    static func aggregationName(_ aggregation: String) -> String {
        switch aggregation {
        case "daily_total": return "当日累计"
        case "minute": return "分时记录"
        case "measurement": return "单次测量"
        case "interval", "sleep_interval": return "时段记录"
        default: return "手环记录"
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "steps": return "figure.walk"
        case "distance": return "location.fill"
        case "active_calories": return "flame.fill"
        case "heart_rate": return "heart.fill"
        case "spo2": return "drop.fill"
        case "sleep": return "bed.double.fill"
        default: return "heart.text.square"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "heart_rate": return .pink
        case "spo2": return .cyan
        case "sleep": return .indigo
        default: return BandHealthStyle.accent
        }
    }
}
