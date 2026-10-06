import SwiftUI

struct DeviceWatchFacesSummary: View {
    @ObservedObject var model: BluetoothModel
    private var currentFace: DeviceWatchFace? { model.watchfaces.first { $0.isActive } }
    private var isBusy: Bool {
        model.isBusy || model.isSyncing || model.isLoadingWatchfaces || model.isChangingWatchface
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("手环上的表盘").font(.title2.bold())
                Spacer()
                Button(action: model.refreshWatchfaces) {
                    if model.isLoadingWatchfaces { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(!model.isAuthenticated || isBusy)
                .accessibilityLabel("刷新手环表盘")
            }
            NavigationLink {
                DeviceWatchFacesView(model: model)
            } label: {
                HStack(spacing: 16) {
                    if let face = currentFace {
                        DeviceWatchFaceArtwork(faceID: face.id, store: model.watchfacePreviews,
                                               width: 56, height: 98)
                    } else {
                        Image(systemName: "rectangle.portrait")
                            .font(.system(size: 33, weight: .light)).foregroundStyle(.orange)
                            .frame(width: 56, height: 98)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        if let face = currentFace {
                            Text(deviceFaceName(face)).font(.headline).foregroundStyle(.primary)
                            Label("当前表盘", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(model.isLoadingWatchfaces ? "正在读取表盘…" : "查看手环表盘")
                                .font(.headline).foregroundStyle(.primary)
                            Text(model.isAuthenticated ? "读取设备上的表盘名称与当前状态" : "连接并认证后读取")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !model.watchfaces.isEmpty {
                            Text("\(model.watchfaces.count) 款已安装表盘")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain)
            if !model.watchfacesState.isEmpty {
                Text(model.watchfacesState).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.isAuthenticated && !model.watchfaces.isEmpty {
                Text("当前显示上次读取的列表，连接后可刷新和切换。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("列表和当前状态来自手环；可用预览图来自小米官方目录。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refreshIfNeeded)
        .onChange(of: model.isAuthenticated) { _, connected in
            if connected { refreshIfNeeded() }
        }
    }

    private func refreshIfNeeded() {
        guard model.isAuthenticated, model.watchfaces.isEmpty, !isBusy else { return }
        model.refreshWatchfaces()
    }
}

struct DeviceWatchFacesView: View {
    @ObservedObject var model: BluetoothModel
    private var isBusy: Bool {
        model.isBusy || model.isSyncing || model.isLoadingWatchfaces || model.isChangingWatchface
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if model.isLoadingWatchfaces || model.isChangingWatchface {
                        ProgressView()
                    } else {
                        Image(systemName: model.isAuthenticated ? "checkmark.shield" : "link")
                            .foregroundStyle(.orange)
                    }
                    Text(statusText).font(.subheadline)
                }
                Button("刷新表盘列表", action: model.refreshWatchfaces)
                    .disabled(!model.isAuthenticated || isBusy)
            } footer: {
                Text("列表和当前状态来自手环；可用预览图来自小米官方目录。")
            }

            if model.watchfaces.isEmpty {
                Section {
                    ContentUnavailableView(
                        model.isLoadingWatchfaces ? "正在读取表盘" : "还没有表盘列表",
                        systemImage: "rectangle.stack",
                        description: Text(model.isAuthenticated ? "点击刷新，从手环读取列表。" : "请先连接并认证手环。"))
                }
            } else {
                Section("已安装 · \(model.watchfaces.count) 款") {
                    ForEach(model.watchfaces) { face in
                        NavigationLink {
                            DeviceWatchFaceDetailView(face: face, model: model)
                        } label: {
                            DeviceWatchFaceListRow(face: face, previewStore: model.watchfacePreviews)
                        }
                    }
                }
            }
        }
        .navigationTitle("手环上的表盘")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.orange)
        .onAppear(perform: refreshIfNeeded)
        .onChange(of: model.isAuthenticated) { _, connected in
            if connected { refreshIfNeeded() }
        }
    }

    private var statusText: String {
        if !model.isAuthenticated { return "连接并认证后，可读取和切换表盘。" }
        if !model.watchfacesState.isEmpty { return model.watchfacesState }
        return "读取手环中已安装的表盘。"
    }

    private func refreshIfNeeded() {
        guard model.isAuthenticated, model.watchfaces.isEmpty, !isBusy else { return }
        model.refreshWatchfaces()
    }
}

private struct DeviceWatchFaceListRow: View {
    let face: DeviceWatchFace
    @ObservedObject var previewStore: WatchfacePreviewStore
    var body: some View {
        HStack(spacing: 13) {
            DeviceWatchFaceArtwork(faceID: face.id, store: previewStore, width: 42, height: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text(deviceFaceName(face)).font(.body)
                if face.isActive {
                    Text("当前表盘").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            if face.isActive {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("当前表盘")
            }
        }.padding(.vertical, 4)
    }
}

private struct DeviceWatchFaceDetailView: View {
    let face: DeviceWatchFace
    @ObservedObject var model: BluetoothModel
    private var currentRecord: DeviceWatchFace? { model.watchfaces.first { $0.id == face.id } }
    private var isCurrent: Bool { currentRecord?.isActive == true }
    private var isBusy: Bool {
        model.isBusy || model.isSyncing || model.isLoadingWatchfaces || model.isChangingWatchface
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    DeviceWatchFaceArtwork(faceID: face.id, store: model.watchfacePreviews,
                                           width: 174, height: 304)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    Text(deviceFaceName(currentRecord ?? face))
                        .font(.title2.bold())
                    if isCurrent {
                        Label("当前表盘", systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.orange)
                    } else if currentRecord != nil {
                        Text("已安装在手环上").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("列表已更新，请返回重新选择。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("列表和当前状态来自手环；可用预览图来自小米官方目录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section {
                Button {
                    guard let selected = currentRecord else { return }
                    model.selectWatchface(selected)
                } label: {
                    HStack {
                        Text(isCurrent ? "正在使用" : "设为当前表盘")
                        Spacer()
                        if model.isChangingWatchface { ProgressView() }
                        else if isCurrent { Image(systemName: "checkmark") }
                    }
                }
                .disabled(!model.isAuthenticated || isBusy || isCurrent || currentRecord == nil)
            } footer: {
                Text("切换后重新读取手环状态，确认成功才更新“当前表盘”标记。")
            }
            if !model.watchfacesState.isEmpty {
                Section {
                    Text(model.watchfacesState).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !model.isAuthenticated {
                Section {
                    Text("手环尚未连接并认证。连接后可以切换表盘。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("表盘详情")
        .navigationBarTitleDisplayMode(.inline)
        .tint(.orange)
    }
}

private struct DeviceWatchFaceArtwork: View {
    let faceID: String
    @ObservedObject var store: WatchfacePreviewStore
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let url = store.url(for: faceID) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        loading
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .accessibilityLabel("小米官方表盘预览图")
                    case .failure:
                        unavailable
                    @unknown default:
                        unavailable
                    }
                }
            } else if store.isLoading.contains(faceID) {
                loading
            } else {
                unavailable
            }
        }
        .frame(width: width, height: height)
        .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: width * 0.17))
        .clipShape(RoundedRectangle(cornerRadius: width * 0.17))
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            if width >= 100 {
                Text("正在获取预览图…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("正在获取表盘预览图")
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: width >= 100 ? 34 : 20, weight: .light))
                .foregroundStyle(.secondary)
            if width >= 100 {
                Text("此表盘尚无可用预览图")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("此表盘尚无可用预览图")
    }
}

private func deviceFaceName(_ face: DeviceWatchFace) -> String {
    let name = face.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "未命名表盘" : name
}
