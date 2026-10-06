import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: BluetoothModel

    var body: some View {
        NavigationStack {
            List {
                introduction
                controls
                if !model.devices.isEmpty { nearbyDevices }
                if let device = model.selectedDevice { selectedDevice(device) }
                if let diagnosis = model.diagnosis { diagnosisSection(diagnosis) }
                if model.discoveryComplete { optionalActions }
                if !model.services.isEmpty { servicesSection }
                exportSection
                logsSection
                Section {
                    LabeledContent("App 版本", value: model.appVersion)
                    LabeledContent("Rust 核心", value: model.coreVersion)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("手环连接诊断")
            .textSelection(.enabled)
        }
    }

    private var introduction: some View {
        Section {
            Label("先确认手机能看见手环", systemImage: "wave.3.right")
                .font(.headline)
            Text("查看蓝牙连接、服务和协议日志。设备名称与服务匹配不能单独确认型号。")
                .font(.subheadline)
            Text("认证状态：\(model.authState)。密钥与通信原文不会进入诊断报告。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        Section("蓝牙状态") {
            Label(model.bluetoothState, systemImage: "antenna.radiowaves.left.and.right")
                .font(.subheadline)
            HStack(alignment: .top, spacing: 10) {
                if model.isBusy || model.isScanning { ProgressView().padding(.top, 3) }
                Text(model.status).font(.subheadline)
            }
            Button(action: model.scan) {
                Label(model.isScanning ? "重新扫描附近设备" : "扫描附近设备", systemImage: "magnifyingglass")
            }
            if model.isScanning {
                Button("停止扫描", action: model.stopScan)
            }
            if model.isConnected || model.isBusy {
                Button("取消连接与诊断", role: .destructive, action: model.disconnect)
            }
        }
    }

    private var nearbyDevices: some View {
        Section {
            ForEach(model.devices) { device in
                Button {
                    model.connect(device)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name).font(.headline).foregroundStyle(.primary)
                                .lineLimit(2)
                            if device.systemConnected == true {
                                Text("系统已连接 · 可直接连接").font(.caption).foregroundStyle(.green)
                            }
                            Text(String(device.id.uuidString.prefix(8)))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            if !device.advertisedServices.isEmpty {
                                Text("广播服务：\(device.advertisedServices.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(device.rssi.map { "\($0) dBm" } ?? "信号未知")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Label("连接", systemImage: "chevron.right")
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        } header: {
            Text("附近设备 · \(model.devices.count)")
        } footer: {
            Text("包含系统已连接的候选设备和广播扫描结果。系统连接不代表本应用已经认证。")
        }
    }

    private func selectedDevice(_ device: ScanDevice) -> some View {
        Section("选定设备") {
            LabeledContent("名称", value: device.name)
            LabeledContent("连接状态", value: model.isConnected ? "已连接" : "未连接")
            VStack(alignment: .leading, spacing: 5) {
                Text("本机蓝牙标识").font(.caption).foregroundStyle(.secondary)
                Text(device.id.uuidString).font(.caption.monospaced())
            }
            LabeledContent("服务发现", value: model.discoveryComplete ? "完整" : "未完成")
        }
    }

    private func diagnosisSection(_ result: CoreDiagnosis) -> some View {
        Section("Rust 核心诊断") {
            Text(result.summary)
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("这是服务特征判断，不是手环认证结果。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var optionalActions: some View {
        Section {
            if let battery = model.batteryLevel {
                LabeledContent("标准电量", value: "\(battery)%")
            }
            Button(action: model.readBattery) {
                HStack {
                    Label("读取标准电量", systemImage: "battery.100percent")
                    if model.isReadingBattery { Spacer(); ProgressView() }
                }
            }
            .disabled(!model.canReadBattery)
            Button(action: model.toggleSubscription) {
                HStack {
                    Label(model.isSubscribed ? "停止订阅 005E 通知" : "订阅 005E 通知",
                          systemImage: model.isSubscribed ? "bell.slash" : "bell")
                    if model.isChangingSubscription { Spacer(); ProgressView() }
                }
            }
            .disabled(!model.canSubscribe)
            if model.notificationCount > 0 {
                LabeledContent("已接收通知", value: "\(model.notificationCount) 条")
            }
        } header: {
            Text("可选诊断")
        } footer: {
            Text("仅在发现对应特征且仍连接时可用。保存了设备密钥时，开启通知后将自动认证。标准电量读取成功本身不代表认证成功。")
        }
    }

    private var servicesSection: some View {
        Section("服务与特征 · \(model.services.count)") {
            ForEach(model.services) { service in
                DisclosureGroup {
                    if service.characteristics.isEmpty {
                        Text(service.discoveryComplete ? "没有发现特征。" : "特征发现未完成。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(service.characteristics) { characteristic in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(characteristic.uuid).font(.caption.monospaced())
                            Text(characteristic.properties.isEmpty ? "无已知属性" : characteristic.properties.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if characteristic.isNotifying {
                                Label("通知已开启", systemImage: "bell.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(service.uuid).font(.caption.monospaced())
                        Text(service.discoveryComplete ? "\(service.characteristics.count) 个特征" : "发现未完成")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button(action: model.prepareExport) {
                Label("生成诊断报告", systemImage: "doc.badge.gearshape")
            }
            if let url = model.exportURL {
                ShareLink(item: url, preview: SharePreview("手环蓝牙诊断报告")) {
                    Label("分享 JSON 报告", systemImage: "square.and.arrow.up")
                }
                Text("报告是点击生成时的快照；诊断状态变化后可重新生成。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.exportError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("导出诊断")
        } footer: {
            Text("报告包含设备名称、本机蓝牙标识、系统版本、服务清单和最近 200 条日志。分享前请确认接收对象；通知原始内容不会写入报告。")
        }
    }

    private var logsSection: some View {
        Section("最近日志 · 最多 200 条") {
            if model.logs.isEmpty {
                Text("开始扫描后会记录诊断过程。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.logs.reversed()) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.time, style: .time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Text(entry.message).font(.caption)
                }
            }
        }
    }
}
