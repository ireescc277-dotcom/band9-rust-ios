import Charts
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: BluetoothModel
    var body: some View {
        TabView {
            HealthDashboard(model: model, archive: model.archive)
                .tabItem { Label("今天", systemImage: "heart.text.square") }
            HealthHistory(model: model, archive: model.archive)
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
            DeviceView(model: model, archive: model.archive)
                .tabItem { Label("手环", systemImage: "applewatch") }
        }
        .tint(.teal)
    }
}

private struct HealthDashboard: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @State private var showingLocalImport = false
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private var records: [HealthRecord] { archive.records(for: model.currentDeviceID) }
    private var heartRecords: [HealthRecord] {
        Array(records.filter { $0.kind == "heart_rate" && $0.value != nil }.prefix(30).reversed())
    }
    private var latestHeart: HealthRecord? { records.first { $0.kind == "heart_rate" } }
    private var latestOxygen: HealthRecord? { records.first { $0.kind == "spo2" } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Date(), format: .dateTime.month().day().weekday(.wide))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("好好生活，慢慢记录。")
                                .font(.title2.bold())
                        }
                        Spacer()
                        Image(systemName: "figure.walk.circle.fill").font(.system(size: 44)).foregroundStyle(.teal)
                    }
                    connectionCard
                    LazyVGrid(columns: columns, spacing: 14) {
                        metric("今日步数", icon: "figure.walk", color: .teal,
                               value: archive.steps(on: Date(), device: model.currentDeviceID).map { String(Int($0)) },
                               unit: "步", detail: "每日总数优先，避免重复累计")
                        metric("昨夜睡眠", icon: "moon.zzz.fill", color: .indigo,
                               value: archive.sleepDuration(endingOn: Date(), device: model.currentDeviceID).map {
                                   "\(Int($0) / 3600)时\((Int($0) % 3600) / 60)分"
                               }, unit: "", detail: "昨晚18:00至今天18:00")
                        metric("最近心率", icon: "heart.fill", color: .pink,
                               value: latestHeart?.value.map { String(Int($0)) }, unit: "次/分",
                               detail: latestHeart.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "等待同步")
                        metric("最近血氧", icon: "drop.fill", color: .blue,
                               value: latestOxygen?.value.map { String(Int($0)) }, unit: "%",
                               detail: latestOxygen.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "等待同步")
                    }
                    Text("睡眠按昨晚 18:00 至今天 18:00 统计，仅累计手环明确记录的浅睡、深睡与快速眼动时段。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !heartRecords.isEmpty {
                        VStack(alignment: .leading, spacing: 15) {
                            Label("最近心率记录", systemImage: "waveform.path.ecg").font(.headline)
                            Chart(heartRecords) { record in
                                if let value = record.value {
                                    LineMark(x: .value("时间", record.date), y: .value("心率", value))
                                        .foregroundStyle(.pink)
                                    PointMark(x: .value("时间", record.date), y: .value("心率", value))
                                        .foregroundStyle(.pink).symbolSize(18)
                                }
                            }
                            .frame(height: 150)
                            .chartYAxisLabel("次/分")
                        }
                        .padding().background(.background, in: RoundedRectangle(cornerRadius: 20))
                    }
                    if records.isEmpty {
                        ContentUnavailableView("等待第一份记录", systemImage: "heart.text.square",
                                               description: Text("在“手环”中连接设备并添加设备密钥，再点同步。这里会显示实际收到的数据。"))
                            .padding(.vertical, 5)
                    }
                    if let error = archive.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("健康记录仅保存在这台手机，当前未写入 Apple 健康。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("今天")
            .sheet(isPresented: $showingLocalImport) {
                DeviceKeyView(model: model, initialImportURL: model.pendingDeviceImportURL)
            }
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "applewatch").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedDevice?.name ?? model.lastDevice?.name ?? "连接你的手环").font(.headline)
                    Text(model.isAuthenticated ? "已认证 · 数据保存在本机" : model.authState)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let battery = model.batteryLevel {
                    Label("\(battery)%", systemImage: "battery.75percent").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
            if model.pendingDeviceImportURL != nil {
                Button("导入已准备的手环") { showingLocalImport = true }
                    .font(.subheadline.weight(.semibold))
            }
            Button(action: model.isAuthenticated ? model.syncHealth : model.reconnect) {
                HStack {
                    if model.isSyncing { ProgressView().tint(.white) }
                    Text(model.isSyncing ? "正在同步…" : (model.isAuthenticated ? "同步健康数据" : "连接手环"))
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: model.isAuthenticated ? "arrow.triangle.2.circlepath" : "arrow.right")
                }
                .padding(12)
            }
            .buttonStyle(.borderedProminent).disabled(model.isSyncing)
        }
        .padding().background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metric(_ title: String, icon: String, color: Color, value: String?, unit: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.subheadline.weight(.medium)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—").font(.system(size: 27, weight: .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                if value != nil { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(value == nil ? "暂无同步数据" : detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct HealthHistory: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @State private var filter = "all"
    private var records: [HealthRecord] {
        archive.records(for: model.currentDeviceID).filter { filter == "all" || $0.kind == filter }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("记录类型", selection: $filter) {
                        Text("全部").tag("all")
                        Text("步数").tag("steps")
                        Text("睡眠").tag("sleep")
                        Text("心率").tag("heart_rate")
                        Text("血氧").tag("spo2")
                    }
                }
                if records.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "clock", description: Text("同步后的真实健康记录会按时间保存在这里。"))
                } else {
                    Section("最近 \(min(records.count, 500)) 条 · 共 \(records.count) 条") {
                        ForEach(Array(records.prefix(500))) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.kind == "sleep" ? record.localizedStage : record.localizedKind).font(.headline)
                                    Text(record.date, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                    if record.aggregation == "daily_total" { Text("当日累计").font(.caption2).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if record.kind == "sleep" {
                                    Text("\(Int(record.endTime >= record.startTime ? record.endTime - record.startTime : 0) / 60) 分钟")
                                } else if let value = record.value {
                                    Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(record.localizedUnit)")
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitle("健康记录")
        }
    }
}

private struct DeviceView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @State private var showingKey = false
    @State private var showingDiagnostics = false
    @State private var loadLocalImport = false
    private var deviceFiles: [ArchivedHealthFile] { archive.files.filter { $0.deviceID == model.currentDeviceID } }

    var body: some View {
        NavigationStack {
            List {
                Section("当前手环") {
                    Label(model.selectedDevice?.name ?? model.lastDevice?.name ?? "尚未选择手环", systemImage: "applewatch")
                        .font(.headline)
                    Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                    LabeledContent("认证", value: model.authState)
                    if let battery = model.batteryLevel { LabeledContent("电量", value: "\(battery)%") }
                    if let firmware = model.firmware { LabeledContent("固件", value: firmware) }
                    if model.currentDeviceID != nil {
                        Button(model.hasStoredKey ? "更新设备密钥" : "添加设备密钥") { loadLocalImport = false; showingKey = true }
                        Button("重新连接", action: model.reconnect)
                    }
                    if model.isConnected || model.isBusy { Button("断开连接", role: .destructive, action: model.disconnect) }
                }
                Section {
                    Button("从设备文件连接") { loadLocalImport = false; showingKey = true }
                    if model.pendingDeviceImportURL != nil {
                        Button("导入已准备的手环") { loadLocalImport = true; showingKey = true }
                    }
                    Button(action: model.scan) { Label(model.isScanning ? "重新查找手环" : "查找附近手环", systemImage: "magnifyingglass") }
                    if model.isScanning {
                        HStack { ProgressView(); Text("正在扫描，最多 15 秒…").font(.caption) }
                        Button("停止扫描", action: model.stopScan)
                    }
                    ForEach(model.devices) { device in
                        Button { model.connect(device) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.systemConnected == true ? "系统已连接 · 可直接连接" : (device.rssi.map { "信号 \($0) dBm" } ?? "附近蓝牙设备"))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(String(device.id.uuidString.prefix(8))).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                    }
                } header: { Text("发现设备 · \(model.devices.count)") }
                footer: { Text("同时查找系统已经连接的手环与正在广播的设备。系统蓝牙已连接后，仍需在这里选择并完成应用认证。") }
                Section("同步与本机数据") {
                    Button("同步健康数据", action: model.syncHealth).disabled(!model.isAuthenticated || model.isSyncing)
                    Button("刷新电量", action: model.refreshBattery).disabled(!model.isAuthenticated)
                    Text(model.syncMessage).font(.caption).foregroundStyle(.secondary)
                    LabeledContent("已保存文件", value: "\(deviceFiles.count)")
                    Button("生成原始数据导出", action: model.exportHealth).disabled(deviceFiles.isEmpty)
                    if let url = model.healthExportURL {
                        ShareLink(item: url) { Label("分享健康数据文件", systemImage: "square.and.arrow.up") }
                        Text("包含原始健康数据和设备标识，分享前请确认接收对象。不会包含设备密钥。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.exportError { Text(error).font(.caption).foregroundStyle(.red) }
                    if !deviceFiles.isEmpty {
                        NavigationLink("查看原始文件记录") {
                            List(deviceFiles) { file in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(file.fileID).font(.caption.monospaced())
                                    Text("\(file.byteCount) 字节 · \(file.recordCount) 条记录").font(.subheadline)
                                    Text(file.parseStatus == "supported" ? "已解析" : "原始数据已保存，暂未完整解析").font(.caption).foregroundStyle(.secondary)
                                    if let reason = file.parseReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                            }.navigationTitle("原始健康文件")
                        }
                    }
                }
                Section {
                    Button("连接诊断与日志") { showingDiagnostics = true }
                    LabeledContent("版本", value: model.appVersion)
                    Text("密钥保存在系统钥匙串，仅此手机可读取。健康记录保存在本机；当前尚未接入 Apple 健康。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的手环")
            .sheet(isPresented: $showingKey) {
                DeviceKeyView(model: model, initialImportURL: loadLocalImport ? model.pendingDeviceImportURL : nil)
            }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(model: model) }
        }
    }
}

private struct DeviceKeyView: View {
    @ObservedObject var model: BluetoothModel
    var initialImportURL: URL? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var importing = false
    @State private var importError: String?
    @State private var candidates: [DeviceKeyStore.ImportCandidate] = []
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(model.selectedDevice?.name ?? model.lastDevice?.name ?? "从设备文件连接手环").font(.headline)
                    Text("导入自己的设备文件后，选择要连接的手环。带本机蓝牙标识的记录可以直接发起连接，无需等待设备广播。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.currentDeviceID != nil {
                        SecureField("32 位十六进制 AuthKey", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .privacySensitive()
                        Button("保存并认证当前手环") {
                            if model.saveDeviceKey(key) { key = ""; candidates.removeAll(); dismiss() }
                        }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text("手动输入密钥或导入不带蓝牙标识的记录，需要先扫描并选择手环。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("从文件导入") { importing = true }
                    if let localURL = model.pendingDeviceImportURL, candidates.isEmpty {
                        Button("导入已准备的手环") { loadImport(localURL) }
                    }
                } footer: {
                    Text("密钥绑定所选记录的设备标识，不会绑定到另一台当前设备。不上传至 GitHub，不进入诊断日志或数据导出。")
                }
                if !candidates.isEmpty {
                    Section("选择当前手环对应的记录") {
                        ForEach(candidates) { candidate in
                            Button {
                                if model.importDeviceRecord(candidate) { candidates.removeAll(); key = ""; dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(candidate.peripheralID == nil ? candidate.label : "连接 \(candidate.label)")
                                    if let id = candidate.peripheralID {
                                        Text("目标设备：\(id.uuidString)")
                                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        if model.currentDeviceID != nil && id != model.currentDeviceID {
                                            Text("将切换到这条记录对应的手环")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text("无设备标识，仅可绑定已选择的手环")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if let error = importError ?? model.keyError { Text(error).foregroundStyle(.red).font(.caption) }
                if model.hasStoredKey {
                    Section { Button("删除本机保存的密钥", role: .destructive) { model.removeDeviceKey(); dismiss() } }
                }
            }
            .navigationTitle("设备密钥")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { key = ""; candidates.removeAll(); dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
                do {
                    let url = try result.get()
                    loadImport(url)
                } catch { importError = error.localizedDescription }
            }
            .onAppear {
                if let initialImportURL = initialImportURL { loadImport(initialImportURL) }
            }
            .onDisappear { key = ""; candidates.removeAll() }
        }
    }

    private func loadImport(_ url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 {
                throw DeviceKeyStore.Failure.invalidImport
            }
            candidates = try DeviceKeyStore.importCandidates(from: Data(contentsOf: url))
            importError = nil
        } catch { importError = error.localizedDescription }
    }
}
