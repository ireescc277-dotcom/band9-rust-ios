import SwiftUI
import UniformTypeIdentifiers

struct DeviceKeyView: View {
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
