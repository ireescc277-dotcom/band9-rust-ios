import Charts
import SwiftUI

struct AnalyticsView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @State private var window = 7
    @State private var metric = Metric.steps
    @AppStorage("watch.stepGoal") private var stepGoal = 8000
    private let background = Color(red: 0.025, green: 0.055, blue: 0.105)
    private let panel = Color(red: 0.065, green: 0.10, blue: 0.16)

    private enum Metric: String, CaseIterable, Identifiable {
        case steps, distance, active_calories
        var id: String { rawValue }
        var title: String { switch self { case .steps: return "步数"; case .distance: return "距离"; case .active_calories: return "活动能量" } }
        var unit: String { switch self { case .steps: return "步"; case .distance: return "公里"; case .active_calories: return "千卡" } }
    }
    private struct DayValue: Identifiable {
        var id: Date { date }
        let date: Date
        let value: Double
    }
    private var files: [ArchivedHealthFile] { archive.files.filter { $0.deviceID == model.currentDeviceID } }
    private var days: [Date] {
        let start = Calendar.current.startOfDay(for: Date())
        return (0..<window).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: start) }
    }
    var body: some View {
        // Resolve archive deduplication once per update, then reuse the snapshot
        // for every card instead of sorting all history for each chart day.
        let snapshot = archive.records(for: model.currentDeviceID)
        let dates = days
        let trend = dates.compactMap { date -> DayValue? in
            dailyValue(metric, on: date, in: snapshot).map { DayValue(date: date, value: $0) }
        }
        let todaySteps = dailyValue(.steps, on: Date(), in: snapshot)
        let counts = snapshot.reduce(into: [String: Int]()) { $0[$1.kind, default: 0] += 1 }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                statusHeader
                todayCard(todaySteps: todaySteps)
                trendCard(series: trend, days: dates)
                coverageCard(counts: counts)
                NavigationLink { DataStorageView(model: model, archive: archive) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("本机档案").font(.headline).foregroundStyle(.white)
                            Text("\(files.count) 份文件 · \(snapshot.count) 条去重记录").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
                    }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
                Text("趋势只统计已经收到的样本。空白日期表示没有数据，不当作零计入平均值。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 3)
            }.padding(20)
        }.background(background).navigationTitle("数据概览")
    }

    private var statusHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.isAuthenticated ? "设备在线" : "本机记录", systemImage: model.isAuthenticated ? "dot.radiowaves.left.and.right" : "internaldrive")
                    .font(.caption.weight(.semibold)).foregroundStyle(.cyan)
                if let date = files.first?.receivedAt {
                    Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                } else { Text("连接后同步第一份记录").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button {
                if model.isAuthenticated { model.syncHealth() } else { model.reconnect() }
            } label: {
                if model.isSyncing { ProgressView() }
                else { Label(model.isAuthenticated ? "同步" : "连接", systemImage: "arrow.triangle.2.circlepath").font(.subheadline.weight(.semibold)) }
            }.buttonStyle(.bordered).disabled(model.isSyncing || model.isBusy)
        }
    }

    private func todayCard(todaySteps: Double?) -> some View {
        HStack(spacing: 22) {
            ZStack {
                Circle().stroke(Color.cyan.opacity(0.12), lineWidth: 10)
                Circle().trim(from: 0, to: min(max((todaySteps ?? 0) / Double(max(stepGoal, 1)), 0), 1))
                    .stroke(Color.cyan.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "figure.walk").font(.system(size: 28)).foregroundStyle(.cyan)
            }.frame(width: 88, height: 88).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("今日步数").font(.subheadline).foregroundStyle(.secondary)
                Text(todaySteps.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                    .font(.system(size: 38, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(todaySteps == nil ? "尚未收到今日数据" : "本机目标 \(stepGoal) 步")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(panel, in: RoundedRectangle(cornerRadius: 23))
    }

    private func trendCard(series: [DayValue], days: [Date]) -> some View {
        let total: Double? = series.isEmpty ? nil : series.reduce(0) { $0 + $1.value }
        let average = total.map { $0 / Double(series.count) }
        let rangeStart = days.first ?? Date()
        let rangeEnd = Calendar.current.date(byAdding: .day, value: 1, to: days.last ?? rangeStart) ?? rangeStart
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("活动趋势").font(.title3.bold())
                Spacer()
                Picker("时间范围", selection: $window) { Text("7 天").tag(7); Text("30 天").tag(30) }
                    .pickerStyle(.segmented).frame(width: 132)
            }
            Picker("指标", selection: $metric) { ForEach(Metric.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 28) {
                stat("记录合计", value: total)
                stat("有记录日均", value: average)
            }
            if series.isEmpty {
                ContentUnavailableView("还没有这项记录", systemImage: "chart.bar", description: Text("同步后按收到的数据绘制趋势。"))
                    .frame(minHeight: 180)
            } else {
                Chart(series) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value(metric.unit, day.value))
                        .foregroundStyle(Color.cyan.gradient).cornerRadius(3)
                }
                .chartXScale(domain: rangeStart...rangeEnd)
                .chartYScale(domain: 0...max(series.map(\.value).max() ?? 1, 1))
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: window == 7 ? 1 : 7)) { _ in AxisValueLabel(format: .dateTime.day()) } }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 175)
            }
            HStack {
                Circle().fill(.cyan).frame(width: 6, height: 6)
                Text("最近 \(window) 天中，有 \(series.count) 天收到\(metric.title)记录").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 23))
    }

    private func stat(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { $0.formatted(.number.precision(.fractionLength(metric == .distance ? 1 : 0))) } ?? "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).minimumScaleFactor(0.7).lineLimit(1)
                Text(metric.unit).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func coverageCard(counts: [String: Int]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("数据覆盖").font(.title3.bold())
            ForEach([("steps", "步数"), ("distance", "距离"), ("active_calories", "活动能量"), ("heart_rate", "心率"), ("spo2", "血氧"), ("sleep", "睡眠")], id: \.0) { kind, title in
                let count = counts[kind] ?? 0
                NavigationLink {
                    HealthRecordsView(model: model, archive: archive, initialKind: kind)
                } label: {
                    HStack {
                        Text(title).foregroundStyle(.primary)
                        Spacer()
                        Text(count == 0 ? "暂无样本" : "\(count) 条").font(.subheadline).foregroundStyle(count == 0 ? Color.secondary : .cyan)
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
                if kind != "sleep" { Divider().overlay(Color.white.opacity(0.03)) }
            }
        }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 23))
    }

    private func dailyValue(_ metric: Metric, on date: Date, in records: [HealthRecord]) -> Double? {
        let matching = records.filter {
            $0.kind == metric.rawValue && $0.value?.isFinite == true && Calendar.current.isDate($0.date, inSameDayAs: date)
        }
        let totals = matching.filter { $0.aggregation == "daily_total" }.compactMap(\.value)
        let result: Double?
        if let total = totals.first { result = total }
        else {
            let minutes = matching.filter { $0.aggregation == "minute" }
            let unique = Dictionary(minutes.map { ("\($0.startTime)|\($0.endTime)", $0) }, uniquingKeysWith: { first, _ in first })
            result = unique.isEmpty ? nil : unique.values.compactMap(\.value).reduce(0, +)
        }
        return result.map { metric == .distance ? $0 / 1000 : $0 }
    }
}
