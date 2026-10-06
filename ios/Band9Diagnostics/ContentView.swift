import SwiftUI

enum AppExperience: String, CaseIterable, Identifiable {
    case watch, health, data
    var id: String { rawValue }
    var title: String {
        switch self { case .watch: return "Watch 管理版"; case .health: return "健康生活版"; case .data: return "数据分析版" }
    }
    var subtitle: String {
        switch self {
        case .watch: return "设备、表盘、设置。熟悉的 Watch 布局。"
        case .health: return "从今天出发，看活动、睡眠与日常记录。"
        case .data: return "查看历史趋势、样本覆盖和本地数据。"
        }
    }
    var symbol: String {
        switch self { case .watch: return "applewatch"; case .health: return "heart.text.square.fill"; case .data: return "chart.xyaxis.line" }
    }
    var accent: Color {
        switch self { case .watch: return .orange; case .health: return Color(red: 0.02, green: 0.55, blue: 0.48); case .data: return .cyan }
    }
}

struct ContentView: View {
    @ObservedObject var model: BluetoothModel
    @StateObject private var library = FaceLibrary()
    @AppStorage("watch.experience") private var experienceValue = AppExperience.watch.rawValue
    @AppStorage("watch.tab") private var watchTab = 0
    @State private var showingExperiences = false
    private var experience: AppExperience { AppExperience(rawValue: experienceValue) ?? .watch }

    var body: some View {
        Group {
            switch experience {
            case .watch: watchTabs
            case .health: healthTabs
            case .data: dataTabs
            }
        }
        .tint(experience.accent).accentColor(experience.accent)
        .preferredColorScheme(experience == .health ? .light : .dark)
        .sheet(isPresented: $showingExperiences) { ExperiencePicker(selection: $experienceValue) }
    }

    private var watchTabs: some View {
        TabView(selection: $watchTab) {
            NavigationStack {
                MyWatchView(model: model, archive: model.archive, library: library)
                    .toolbar { experienceButton }
            }.tabItem { Label("我的手表", systemImage: "applewatch") }.tag(0)
            FaceGalleryView(library: library, model: model)
                .tabItem { Label("表盘图库", systemImage: "square.grid.2x2.fill") }.tag(1)
            NavigationStack {
                DiscoverView().toolbar { experienceButton }
            }.tabItem { Label("发现", systemImage: "safari") }.tag(2)
        }
    }

    private var healthTabs: some View {
        TabView {
            NavigationStack {
                HealthOverviewView(model: model, archive: model.archive, showConnections: true)
                    .toolbar { experienceButton }
            }.tabItem { Label("今天", systemImage: "heart.fill") }
            NavigationStack {
                HealthRecordsView(model: model, archive: model.archive).toolbar { experienceButton }
            }.tabItem { Label("记录", systemImage: "calendar") }
            NavigationStack {
                DeviceControlView(model: model, archive: model.archive).toolbar { experienceButton }
            }.tabItem { Label("我的手环", systemImage: "applewatch") }
        }
    }

    private var dataTabs: some View {
        TabView {
            NavigationStack {
                AnalyticsView(model: model, archive: model.archive).toolbar { experienceButton }
            }.tabItem { Label("概览", systemImage: "chart.bar.xaxis") }
            NavigationStack {
                HealthRecordsView(model: model, archive: model.archive).toolbar { experienceButton }
            }.tabItem { Label("数据", systemImage: "list.bullet.rectangle.portrait") }
            NavigationStack {
                DeviceControlView(model: model, archive: model.archive).toolbar { experienceButton }
            }.tabItem { Label("设备", systemImage: "sensor.tag.radiowaves.forward") }
        }
    }

    @ToolbarContentBuilder private var experienceButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingExperiences = true } label: { Image(systemName: "square.stack.3d.up") }
                .accessibilityLabel("切换三种界面")
        }
    }
}

struct ExperiencePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("同一只手环，三种视角。")
                        .font(.title2.bold()).padding(.bottom, 4)
                    ForEach(AppExperience.allCases) { item in
                        Button {
                            selection = item.rawValue
                            dismiss()
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: item.symbol).font(.system(size: 32)).foregroundStyle(item.accent).frame(width: 48)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.title).font(.headline).foregroundStyle(.primary)
                                    Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if selection == item.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(item.accent) }
                            }.padding(22).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
                        }.buttonStyle(.plain)
                    }
                    Text("切换界面会保留设备连接、密钥、健康记录和收藏。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 6)
                }.padding(20)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("选择你的界面").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private enum WatchRoute: String, CaseIterable, Identifiable {
    case connection, health, records, general, battery, storage, privacy, capabilities
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: return "连接与同步"; case .health: return "健康"; case .records: return "活动记录"
        case .general: return "通用"; case .battery: return "电池"; case .storage: return "数据与导出"
        case .privacy: return "隐私"; case .capabilities: return "功能与数据"
        }
    }
    var symbol: String {
        switch self {
        case .connection: return "arrow.triangle.2.circlepath"; case .health: return "heart.fill"; case .records: return "figure.walk"
        case .general: return "gearshape.fill"; case .battery: return "battery.100percent"; case .storage: return "externaldrive.fill"
        case .privacy: return "hand.raised.fill"; case .capabilities: return "square.grid.2x2.fill"
        }
    }
    var color: Color {
        switch self {
        case .connection: return .blue; case .health: return .pink; case .records: return .green
        case .general: return .gray; case .battery: return .green; case .storage: return .orange
        case .privacy: return .blue; case .capabilities: return .purple
        }
    }
}

private struct MyWatchView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @ObservedObject var library: FaceLibrary
    @State private var query = ""
    private var routes: [WatchRoute] { WatchRoute.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if query.isEmpty {
                    NavigationLink {
                        DeviceControlView(model: model, archive: archive)
                    } label: {
                        HStack(spacing: 16) {
                            MiniBandArtwork().frame(width: 56, height: 82)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.selectedDevice?.name ?? model.lastDevice?.name ?? "添加你的手环").font(.headline).foregroundStyle(.primary)
                                Text(model.isAuthenticated ? "已连接" : "点此连接与管理")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                if let battery = model.batteryLevel {
                                    Label("\(battery)%", systemImage: "battery.100percent").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                    SavedFacesRow(library: library, model: model)
                }
                VStack(spacing: 0) {
                    ForEach(routes) { route in
                        NavigationLink { destination(route) } label: {
                            HStack(spacing: 13) {
                                SettingIcon(symbol: route.symbol, color: route.color)
                                Text(route.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.padding(.horizontal, 16).padding(.vertical, 12)
                        }.buttonStyle(.plain)
                        if route != routes.last { Divider().padding(.leading, 60) }
                    }
                }.background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
                if routes.isEmpty { ContentUnavailableView.search(text: query) }
                if query.isEmpty {
                    Text("为你的小米手环而设计。")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 10)
                }
            }.padding(20)
        }.background(Color.black).navigationTitle("我的手表")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索设置")
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                NavigationLink("所有手表") { DeviceControlView(model: model, archive: archive) }.font(.subheadline)
            } }
    }

    @ViewBuilder private func destination(_ route: WatchRoute) -> some View {
        switch route {
        case .connection: DeviceControlView(model: model, archive: archive)
        case .health: HealthOverviewView(model: model, archive: archive)
        case .records: HealthRecordsView(model: model, archive: archive)
        case .general: GeneralSettingsView(model: model)
        case .battery: BatteryView(model: model)
        case .storage: DataStorageView(model: model, archive: archive)
        case .privacy: PrivacyView()
        case .capabilities: CapabilitiesView()
        }
    }
}

struct SettingIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            .frame(width: 31, height: 31).background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct MiniBandArtwork: View {
    var body: some View {
        ZStack {
            Capsule().fill(Color(white: 0.72)).frame(width: 24)
            Capsule().fill(LinearGradient(colors: [.white, .gray, .white], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 46, height: 72)
            Capsule().fill(.black).frame(width: 39, height: 65)
            VStack(spacing: 1) {
                Text("09").foregroundStyle(.orange)
                Text("41").foregroundStyle(.white)
            }.font(.system(size: 22, weight: .semibold, design: .rounded))
        }.accessibilityHidden(true)
    }
}

struct DeviceControlView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    @State private var showingKey = false
    @State private var usePreparedKey = false
    @State private var showingDiagnostics = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 18) {
                    MiniBandArtwork().frame(width: 55, height: 90)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.selectedDevice?.name ?? model.lastDevice?.name ?? "尚未添加手环").font(.headline)
                        Label(model.isAuthenticated ? "已连接并认证" : model.authState, systemImage: model.isAuthenticated ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption).foregroundStyle(model.isAuthenticated ? Color.green : Color.secondary)
                        if let battery = model.batteryLevel { Text("电量 \(battery)%").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 12)
                Text(model.status).font(.footnote).foregroundStyle(.secondary)
                Button(model.isAuthenticated ? "同步健康数据" : "连接手环") {
                    if model.isAuthenticated { model.syncHealth() } else { model.reconnect() }
                }.disabled(model.isSyncing || model.isBusy)
                if model.isSyncing { Label(model.syncMessage, systemImage: "arrow.triangle.2.circlepath").font(.caption) }
                if model.isConnected || model.isBusy { Button("断开连接", role: .destructive, action: model.disconnect) }
            }
            Section("添加与配对") {
                Button("从设备文件连接") { usePreparedKey = false; showingKey = true }
                if model.pendingDeviceImportURL != nil {
                    Button("导入已准备的手环") { usePreparedKey = true; showingKey = true }
                }
                Button(model.isScanning ? "重新查找附近手环" : "查找附近手环", action: model.scan)
                if model.isScanning { HStack { ProgressView(); Text("正在查找附近设备…").font(.caption) }; Button("停止查找", action: model.stopScan) }
                ForEach(model.devices) { device in
                    Button { model.connect(device) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name).foregroundStyle(.primary)
                                Text(device.systemConnected == true ? "系统已连接" : "附近的蓝牙设备").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id == model.currentDeviceID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                }
            }
            Section("手环管理") {
                NavigationLink { GeneralSettingsView(model: model) } label: { Label("通用", systemImage: "gearshape") }
                NavigationLink { BatteryView(model: model) } label: { Label("电池", systemImage: "battery.100percent") }
                NavigationLink { DataStorageView(model: model, archive: archive) } label: { Label("数据与导出", systemImage: "externaldrive") }
                if model.currentDeviceID != nil { Button("管理设备密钥") { usePreparedKey = false; showingKey = true } }
            }
            Section {
                NavigationLink("功能与数据") { CapabilitiesView() }
                Button("连接诊断与日志") { model.prepareExport(); showingDiagnostics = true }
            }
        }.navigationTitle("所有手表")
            .sheet(isPresented: $showingKey) { DeviceKeyView(model: model, initialImportURL: usePreparedKey ? model.pendingDeviceImportURL : nil) }
            .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(model: model) }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: BluetoothModel
    @AppStorage("watch.experience") private var experienceValue = AppExperience.watch.rawValue
    @AppStorage("watch.stepGoal") private var stepGoal = 8000
    var body: some View {
        Form {
            Section("关于本机") {
                LabeledContent("名称", value: model.selectedDevice?.name ?? model.lastDevice?.name ?? "尚未选择")
                if let name = model.modelName { LabeledContent("型号", value: name) }
                if let firmware = model.firmware { LabeledContent("固件版本", value: firmware) }
                LabeledContent("App 版本", value: model.appVersion)
            }
            Section("界面") {
                Picker("界面版本", selection: $experienceValue) { ForEach(AppExperience.allCases) { Text($0.title).tag($0.rawValue) } }
            }
            Section {
                Stepper(value: $stepGoal, in: 1000...50000, step: 500) { LabeledContent("每日步数目标", value: "\(stepGoal) 步") }
            } header: { Text("本机目标") } footer: { Text("用于 App 内展示进度，不会修改手环里的运动目标。") }
            Section {
                NavigationLink("隐私与数据") { PrivacyView() }
                Link("查看项目与更新", destination: URL(string: "https://github.com/ireescc277-dotcom/band9-rust-ios")!)
            }
        }.navigationTitle("通用").navigationBarTitleDisplayMode(.inline)
    }
}

private struct BatteryView: View {
    @ObservedObject var model: BluetoothModel
    var body: some View {
        List {
            Section {
                VStack(spacing: 18) {
                    Image(systemName: "battery.100percent").font(.system(size: 62)).foregroundStyle(.green)
                    Text(model.batteryLevel.map { "\($0)%" } ?? "—").font(.system(size: 58, weight: .semibold, design: .rounded))
                    Text(model.batteryLevel == nil ? "连接手环后读取电量" : "最近一次从手环读取的电量").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
                Button("刷新电量", action: model.refreshBattery).disabled(!model.isAuthenticated)
            }
            Section { Text("当前协议没有提供电池健康度或剩余使用时长，这里只显示设备返回的电量。")
                .font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("电池").navigationBarTitleDisplayMode(.inline)
    }
}

struct DataStorageView: View {
    @ObservedObject var model: BluetoothModel
    @ObservedObject var archive: HealthArchive
    private var files: [ArchivedHealthFile] { archive.files.filter { $0.deviceID == model.currentDeviceID } }
    var body: some View {
        List {
            Section("本机资料") {
                LabeledContent("健康记录", value: "\(archive.records(for: model.currentDeviceID).count) 条")
                LabeledContent("原始文件", value: "\(files.count) 份")
                LabeledContent("原始文件大小", value: ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.byteCount }), countStyle: .file))
                if let date = files.first?.receivedAt { LabeledContent("最近同步", value: date.formatted(date: .abbreviated, time: .shortened)) }
            }
            Section {
                Button("准备健康数据导出", action: model.exportHealth).disabled(files.isEmpty)
                if let url = model.healthExportURL { ShareLink(item: url) { Label("分享健康数据文件", systemImage: "square.and.arrow.up") } }
                if let error = model.exportError ?? archive.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: { Text("导出包含你的健康记录、原始文件和设备标识，不包含配对密钥。") }
            Section("已同步文件") {
                if files.isEmpty { Text("同步后会在这里保存记录。").foregroundStyle(.secondary) }
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(file.receivedAt, style: .date); Spacer(); Text("\(file.recordCount) 条") }
                        Text(file.parseStatus == "supported" ? "已解析并保存" : "原始文件已保存，格式待适配").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }
            }
        }.navigationTitle("数据与导出").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyView: View {
    var body: some View {
        List {
            Section("保存在你的手机") {
                Label("配对密钥存入系统钥匙串", systemImage: "key.fill")
                Label("健康记录保存在 App 本机目录", systemImage: "iphone")
                Label("当前没有账号和云端上传", systemImage: "icloud.slash")
            }
            Section("由你决定分享") {
                Text("只有使用“数据与导出”中的分享按钮时，你选择的接收方才会收到导出文件。")
                Text("当前没有写入 Apple 健康。删除 App 可能同时删除本机健康档案，重要记录请先导出。")
            }.font(.subheadline)
        }.navigationTitle("隐私").navigationBarTitleDisplayMode(.inline)
    }
}

struct CapabilitiesView: View {
    var body: some View {
        List {
            Section("当前已接入") {
                capability("活动记录", "步数、距离、活动能量；每日和历史统计。", "figure.walk", .green)
                capability("连接与电量", "连接、认证、同步、电量读取。", "applewatch", .orange)
                capability("本机档案", "原始文件、去重记录和主动导出。", "externaldrive", .blue)
            }
            Section("收到对应记录后可展示") {
                capability("心率与血氧", "已实现解析；没有收到样本时显示暂无数据。", "heart.fill", .pink)
                capability("睡眠", "展示手环明确记录的睡眠阶段和时长。", "moon.fill", .indigo)
            }
            Section("待接入") {
                Text("压力、运动详情、通知与闹钟、天气、手环表盘管理、Apple 健康同步。")
                Text("图库里的设计目前是本机预览，尚不能安装到手环。")
            }.font(.subheadline).foregroundStyle(.secondary)
            Section { Text("本 App 不会用缺失的数据生成恢复评分、身体电量或健康诊断。")
                .font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("功能与数据").navigationBarTitleDisplayMode(.inline)
    }
    private func capability(_ title: String, _ detail: String, _ symbol: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 13) {
            SettingIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
}

private struct DiscoverView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("让每一份记录，\n都有自己的位置。")
                    .font(.system(size: 32, weight: .bold)).padding(.top, 8)
                NavigationLink { CapabilitiesView() } label: {
                    VStack(alignment: .leading, spacing: 20) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 65, weight: .light))
                        Text("了解你的手环").font(.title2.bold())
                        Text("哪些记录已经能读到，哪些能力仍在接入。")
                            .font(.subheadline).opacity(0.85)
                        Label("查看功能", systemImage: "arrow.right").font(.subheadline.bold())
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(26)
                        .foregroundStyle(.white).background(LinearGradient(colors: [.orange, Color(red: 0.65, green: 0.17, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 26))
                }.buttonStyle(.plain)
                NavigationLink { GuideView() } label: { guideCard("从连接到同步", detail: "配对一次，让记录留在手机里。", symbol: "arrow.triangle.2.circlepath", color: .blue) }.buttonStyle(.plain)
                NavigationLink { PrivacyView() } label: { guideCard("数据属于你", detail: "了解本机存储与数据导出。", symbol: "hand.raised.fill", color: .purple) }.buttonStyle(.plain)
            }.padding(20)
        }.background(Color.black).navigationTitle("发现")
    }
    private func guideCard(_ title: String, detail: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 18) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(color).frame(width: 42)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline).foregroundStyle(.primary); Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
        }.padding(22).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct GuideView: View {
    var body: some View {
        List {
            Section("1 · 添加手环") { Text("进入“所有手表”，导入自己的设备文件或选择附近手环并添加配对密钥。已经添加过的手环无需重复导入。") }
            Section("2 · 连接与确认") { Text("点击连接；手环或系统出现配对提示时确认。显示“已连接并认证”后即可读取数据。") }
            Section("3 · 同步记录") { Text("点击“同步健康数据”，同步期间保持 App 在前台。成功后可在健康或记录页面按日期浏览。") }
            Section("4 · 切换视角") { Text("点击右上角的界面按钮，在 Watch 管理版、健康生活版和数据分析版之间切换。三版共享同一份本机记录。") }
        }.navigationTitle("使用入门").navigationBarTitleDisplayMode(.inline)
    }
}
