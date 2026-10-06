import Combine
import CoreBluetooth
import Foundation
import UIKit

struct ScanDevice: Identifiable, Codable {
    let id: UUID
    var name: String
    var rssi: Int?
    var advertisedServices: [String]
    var lastSeen: Date
}

struct CharacteristicSnapshot: Identifiable, Codable {
    let id: String
    let uuid: String
    let properties: [String]
    let isNotifying: Bool
}

struct ServiceSnapshot: Identifiable, Codable {
    let id: String
    let uuid: String
    let isPrimary: Bool
    let discoveryComplete: Bool
    let characteristics: [CharacteristicSnapshot]
}

struct DiagnosticLog: Identifiable, Codable {
    let id = UUID()
    let time: Date
    let message: String

    enum CodingKeys: String, CodingKey { case time, message }
}

// CBCentralManager and all timers use the main queue. No BLE operation runs in
// the background, and no authentication key or protocol payload is collected.
final class BluetoothModel: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "尚未申请蓝牙权限"
    @Published private(set) var status = "点击“扫描附近设备”开始。"
    @Published private(set) var devices: [ScanDevice] = []
    @Published private(set) var selectedDevice: ScanDevice?
    @Published private(set) var services: [ServiceSnapshot] = []
    @Published private(set) var diagnosis: CoreDiagnosis?
    @Published private(set) var logs: [DiagnosticLog] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var discoveryComplete = false
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isReadingBattery = false
    @Published private(set) var isChangingSubscription = false
    @Published private(set) var isSubscribed = false
    @Published private(set) var notificationCount = 0
    @Published private(set) var exportURL: URL?
    @Published private(set) var exportError: String?

    private enum Phase: String {
        case idle, connecting, discovering, ready, failed, cancelling
    }
    private enum NextAction {
        case none, scan, connect(UUID)
    }

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var pendingAction: NextAction = .none
    private var finalStopStatus: String?
    private var phase: Phase = .idle
    private var generation = UUID()
    private var pendingServices = Set<ObjectIdentifier>()
    private var discoveredServices = Set<ObjectIdentifier>()
    private var scanTimeout: DispatchWorkItem?
    private var operationTimeout: DispatchWorkItem?
    private var cancellationTimeout: DispatchWorkItem?
    private var batteryTimeout: DispatchWorkItem?
    private var subscriptionTimeout: DispatchWorkItem?

    var coreVersion: String { RustBridge.version }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var canReadBattery: Bool {
        phase == .ready && discoveryComplete && isConnected && batteryCharacteristic != nil && !isReadingBattery
    }

    var canSubscribe: Bool {
        phase == .ready && discoveryComplete && isConnected && notificationCharacteristic != nil && !isChangingSubscription
    }

    func scan() { request(.scan) }

    func connect(_ device: ScanDevice) { request(.connect(device.id)) }

    func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        if case .scan = pendingAction { pendingAction = .none }
        central?.stopScan()
        if isScanning {
            isScanning = false
            isBusy = false
            status = "扫描已停止，共发现 \(devices.count) 台设备。"
            log("扫描停止。")
        }
    }

    func disconnect() { request(.none) }

    func suspend() {
        // The iOS permission dialog can briefly make the scene inactive. The
        // caller invokes this only for the background scene phase.
        guard central != nil else { return }
        request(.none, completionStatus: "应用进入后台，已停止诊断；回到前台后可重新扫描。")
        log("进入后台，停止扫描并取消连接。")
    }

    private func request(_ action: NextAction, completionStatus: String? = nil) {
        generation = UUID()
        cancelWorkTimers()
        central?.stopScan()
        isScanning = false
        isBusy = false
        isReadingBattery = false
        isChangingSubscription = false
        pendingAction = action
        finalStopStatus = completionStatus

        if let peripheral = activePeripheral {
            // Even if the object's state has already changed to disconnected,
            // drain the delegate callback before reusing this peripheral.
            phase = .cancelling
            isBusy = true
            status = completionStatus ?? "正在结束上一次连接…"
            central?.cancelPeripheralConnection(peripheral)
            cancellationTimeout?.cancel()
            cancellationTimeout = schedule(after: 5) { [weak self] in
                guard let self = self, self.phase == .cancelling else { return }
                self.log("旧连接取消未及时回调，重新创建蓝牙会话。")
                self.activePeripheral?.delegate = nil
                self.activePeripheral = nil
                self.central?.delegate = nil
                self.central = nil
                self.peripherals.removeAll()
                self.isConnected = false
                self.isSubscribed = false
                self.isBusy = false
                self.phase = .idle
                // Peripheral objects belong to their original central manager.
                // A timed-out connection replacement needs a new scan.
                if case .connect = self.pendingAction {
                    self.pendingAction = .scan
                    self.status = "旧会话已关闭，请在重新扫描后选择设备。"
                }
                self.startPendingAction()
            }
            return
        }
        activePeripheral?.delegate = nil
        activePeripheral = nil
        isConnected = false
        isSubscribed = false
        phase = .idle
        startPendingAction()
    }

    private func startPendingAction() {
        guard activePeripheral == nil else { return }
        if case .none = pendingAction {
            isBusy = false
            status = finalStopStatus ?? "已停止扫描并断开连接。"
            return
        }
        guard let central = central else {
            status = "正在等待蓝牙权限与蓝牙状态…"
            isBusy = true
            self.central = CBCentralManager(delegate: self, queue: .main,
                                            options: [CBCentralManagerOptionShowPowerAlertKey: true])
            return
        }
        guard central.state == .poweredOn else {
            status = bluetoothState
            isBusy = central.state == .unknown || central.state == .resetting
            if !isBusy { pendingAction = .none }
            return
        }
        let action = pendingAction
        pendingAction = .none
        resetReport()
        switch action {
        case .none: break
        case .scan:
            devices.removeAll()
            peripherals.removeAll()
            selectedDevice = nil
            isScanning = true
            isBusy = false
            status = "正在扫描附近的蓝牙设备（最多 15 秒）…"
            central.scanForPeripherals(withServices: nil,
                                      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("开始前台扫描，不按设备名称过滤。")
            scanTimeout = schedule(after: 15) { [weak self] in self?.stopScan() }
        case .connect(let id):
            guard let peripheral = peripherals[id], let device = devices.first(where: { $0.id == id }) else {
                status = "设备记录已失效，请重新扫描。"
                return
            }
            selectedDevice = device
            activePeripheral = peripheral
            peripheral.delegate = self
            phase = .connecting
            isBusy = true
            status = "正在连接 \(device.name)…"
            log("请求连接选定设备。")
            central.connect(peripheral, options: nil)
            operationTimeout = schedule(after: 15) { [weak self] in
                guard let self = self, self.phase == .connecting else { return }
                self.request(.none, completionStatus: "连接超时，请让手环靠近手机后重新扫描。")
                self.log("连接在 15 秒内未完成，已取消。")
            }
        }
    }

    private func resetReport() {
        services.removeAll()
        diagnosis = nil
        discoveryComplete = false
        batteryLevel = nil
        notificationCount = 0
        isSubscribed = false
        pendingServices.removeAll()
        discoveredServices.removeAll()
        exportURL = nil
        exportError = nil
    }

    private func schedule(after seconds: TimeInterval, action: @escaping () -> Void) -> DispatchWorkItem {
        let expectedGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard self?.generation == expectedGeneration else { return }
            action()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    private func cancelWorkTimers() {
        [scanTimeout, operationTimeout, batteryTimeout, subscriptionTimeout, cancellationTimeout].forEach { $0?.cancel() }
        scanTimeout = nil
        operationTimeout = nil
        batteryTimeout = nil
        subscriptionTimeout = nil
        cancellationTimeout = nil
    }

    private func log(_ message: String) {
        logs.append(DiagnosticLog(time: Date(), message: message))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    private func refreshServices(_ peripheral: CBPeripheral) {
        services = (peripheral.services ?? []).enumerated().map { serviceIndex, service in
            ServiceSnapshot(id: "\(serviceIndex)", uuid: service.uuid.uuidString,
                            isPrimary: service.isPrimary,
                            discoveryComplete: discoveredServices.contains(ObjectIdentifier(service)),
                            characteristics: (service.characteristics ?? []).enumerated().map { characteristicIndex, characteristic in
                CharacteristicSnapshot(id: "\(serviceIndex)-\(characteristicIndex)",
                                       uuid: characteristic.uuid.uuidString,
                                       properties: Self.propertyNames(characteristic.properties),
                                       isNotifying: characteristic.isNotifying)
            })
        }
    }

    private static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        let known: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"), (.indicate, "indicate"), (.broadcast, "broadcast"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"), (.indicateEncryptionRequired, "indicateEncryptionRequired")
        ]
        return known.compactMap { properties.contains($0.0) ? $0.1 : nil }
    }

    private func finishDiscovery(_ peripheral: CBPeripheral) {
        guard phase == .discovering, pendingServices.isEmpty else { return }
        operationTimeout?.cancel()
        operationTimeout = nil
        refreshServices(peripheral)
        phase = .ready
        isBusy = false
        discoveryComplete = true
        status = "服务发现完成。尚未进行手环认证或健康数据同步。"
        log("服务发现完成：\(services.count) 个服务，\(services.reduce(0) { $0 + $1.characteristics.count }) 个特征。")
        do {
            diagnosis = try RustBridge.diagnose(services: services)
            log("Rust 核心完成服务特征诊断。")
        } catch {
            diagnosis = nil
            status = "服务已完整发现，但 Rust 诊断失败：\(error.localizedDescription)"
            log("Rust 诊断失败：\(error.localizedDescription)")
        }
    }

    private func failDiscovery(_ message: String, peripheral: CBPeripheral) {
        operationTimeout?.cancel()
        operationTimeout = nil
        phase = .failed
        isBusy = false
        discoveryComplete = false
        diagnosis = nil
        pendingServices.removeAll()
        refreshServices(peripheral)
        status = "服务发现未完成：\(message)"
        log(status)
    }

    private var batteryCharacteristic: CBCharacteristic? {
        activePeripheral?.services?.first(where: { $0.uuid == CBUUID(string: "180F") })?
            .characteristics?.first(where: { $0.uuid == CBUUID(string: "2A19") && $0.properties.contains(.read) })
    }

    private var notificationCharacteristic: CBCharacteristic? {
        guard let notifyUUID = diagnosis?.suggestedNotifyUUID,
              let writeUUID = diagnosis?.suggestedWriteUUID else { return nil }
        let notifyCandidate = CBUUID(string: notifyUUID)
        let writeCandidate = CBUUID(string: writeUUID)
        guard notifyCandidate == CBUUID(string: "005E"),
              writeCandidate == CBUUID(string: "005F") else { return nil }
        // Both characteristics must belong to the same FE95 service instance.
        // The write capability identifies the pair; this app never writes to it.
        for service in activePeripheral?.services ?? [] where service.uuid == CBUUID(string: "FE95") {
            let characteristics = service.characteristics ?? []
            guard characteristics.contains(where: {
                $0.uuid == writeCandidate && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse))
            }) else { continue }
            if let notification = characteristics.first(where: {
                $0.uuid == notifyCandidate && ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
            }) {
                return notification
            }
        }
        return nil
    }

    func readBattery() {
        guard canReadBattery, let peripheral = activePeripheral, let characteristic = batteryCharacteristic else { return }
        isReadingBattery = true
        peripheral.readValue(for: characteristic)
        log("用户请求读取标准电量特征 2A19。")
        batteryTimeout = schedule(after: 8) { [weak self] in
            guard let self = self else { return }
            self.isReadingBattery = false
            self.log("标准电量读取超时。")
            self.status = "电量读取超时，服务清单仍可导出。"
        }
    }

    func toggleSubscription() {
        guard canSubscribe, let peripheral = activePeripheral, let characteristic = notificationCharacteristic else { return }
        isChangingSubscription = true
        let enable = !characteristic.isNotifying
        peripheral.setNotifyValue(enable, for: characteristic)
        log(enable ? "用户请求订阅 005E 通知；未写入认证命令。" : "用户请求停止订阅 005E 通知。")
        subscriptionTimeout = schedule(after: 8) { [weak self] in
            guard let self = self else { return }
            self.isChangingSubscription = false
            self.status = "通知订阅状态确认超时，可断开后重试。"
            self.log("通知订阅状态确认超时。")
        }
    }

    func prepareExport() {
        struct Report: Encodable {
            let schemaVersion: Int
            let exportedAt: Date
            let appVersion: String
            let coreVersion: String
            let systemVersion: String
            let bluetoothState: String
            let status: String
            let phase: String
            let isConnected: Bool
            let serviceDiscoveryComplete: Bool
            let device: ScanDevice?
            let services: [ServiceSnapshot]
            let diagnosis: CoreDiagnosis?
            let batteryPercent: Int?
            let notificationCount: Int
            let logs: [DiagnosticLog]
            let limitations: [String]
        }
        let report = Report(schemaVersion: 1, exportedAt: Date(), appVersion: appVersion,
                            coreVersion: coreVersion, systemVersion: UIDevice.current.systemVersion,
                            bluetoothState: bluetoothState, status: status, phase: phase.rawValue,
                            isConnected: isConnected, serviceDiscoveryComplete: discoveryComplete,
                            device: selectedDevice, services: services, diagnosis: diagnosis,
                            batteryPercent: batteryLevel, notificationCount: notificationCount, logs: logs,
                            limitations: ["服务匹配不能证明设备型号或认证成功。", "未进行小米协议认证、数据同步或 HealthKit 写入。", "不包含通知原始内容；包含设备名称和本机蓝牙设备标识。"])
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Band9Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("band9-diagnostics.json")
            try encoder.encode(report).write(to: url, options: .atomic)
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }
}

extension BluetoothModel: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn: bluetoothState = "蓝牙已开启"
        case .poweredOff: bluetoothState = "蓝牙已关闭，请在系统设置中开启。"
        case .unauthorized: bluetoothState = "没有蓝牙权限，请前往系统设置为本应用开启蓝牙。"
        case .unsupported: bluetoothState = "此设备不支持蓝牙低功耗连接。"
        case .resetting: bluetoothState = "蓝牙正在重置，请稍候。"
        case .unknown: bluetoothState = "正在等待蓝牙状态…"
        @unknown default: bluetoothState = "未知蓝牙状态，请重新扫描。"
        }
        log(bluetoothState)
        if central.state == .poweredOn {
            if case .none = pendingAction {
                if activePeripheral == nil { status = "蓝牙已就绪，点击扫描开始。" }
            } else {
                startPendingAction()
            }
        } else {
            cancelWorkTimers()
            central.stopScan()
            activePeripheral?.delegate = nil
            activePeripheral = nil
            isScanning = false
            isBusy = central.state == .unknown || central.state == .resetting
            isConnected = false
            isSubscribed = false
            isReadingBattery = false
            isChangingSubscription = false
            phase = .idle
            status = bluetoothState
            if !isBusy { pendingAction = .none }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central, isScanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "未命名蓝牙设备"
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString).sorted()
        let device = ScanDevice(id: peripheral.identifier, name: name.isEmpty ? "未命名蓝牙设备" : name,
                                rssi: RSSI.intValue == 127 ? nil : RSSI.intValue,
                                advertisedServices: advertised, lastSeen: Date())
        peripherals[peripheral.identifier] = peripheral
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort {
            if $0.rssi != $1.rssi { return ($0.rssi ?? Int.min) > ($1.rssi ?? Int.min) }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === activePeripheral else { return }
        guard phase == .connecting else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        operationTimeout?.cancel()
        isConnected = true
        phase = .discovering
        status = "已连接，正在发现所有服务与特征…"
        log("蓝牙连接建立；开始完整服务发现。")
        peripheral.discoverServices(nil)
        operationTimeout = schedule(after: 20) { [weak self, weak peripheral] in
            guard let self = self, let peripheral = peripheral, self.phase == .discovering else { return }
            self.failDiscovery("20 秒内未完成，可断开后重试。", peripheral: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        endConnection(central, peripheral: peripheral, error: error, failed: true)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        endConnection(central, peripheral: peripheral, error: error, failed: false)
    }

    private func endConnection(_ central: CBCentralManager, peripheral: CBPeripheral, error: Error?, failed: Bool) {
        guard central === self.central, peripheral === activePeripheral else { return }
        let wasCancelling = phase == .cancelling
        cancelWorkTimers()
        peripheral.delegate = nil
        activePeripheral = nil
        isBusy = false
        isConnected = false
        isSubscribed = false
        isReadingBattery = false
        isChangingSubscription = false
        phase = .idle
        status = failed ? "连接失败" : "连接已断开"
        if let error = error { status += "：\(error.localizedDescription)" }
        log(status)
        if wasCancelling { startPendingAction() }
    }
}

extension BluetoothModel: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === activePeripheral, phase == .discovering else { return }
        if let error = error {
            failDiscovery(error.localizedDescription, peripheral: peripheral)
            return
        }
        let foundServices = peripheral.services ?? []
        pendingServices = Set(foundServices.map(ObjectIdentifier.init))
        refreshServices(peripheral)
        if foundServices.isEmpty { finishDiscovery(peripheral) }
        else { foundServices.forEach { peripheral.discoverCharacteristics(nil, for: $0) } }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === activePeripheral, phase == .discovering,
              pendingServices.contains(ObjectIdentifier(service)) else { return }
        if let error = error {
            failDiscovery("服务 \(service.uuid.uuidString)：\(error.localizedDescription)", peripheral: peripheral)
            return
        }
        pendingServices.remove(ObjectIdentifier(service))
        discoveredServices.insert(ObjectIdentifier(service))
        refreshServices(peripheral)
        if pendingServices.isEmpty { finishDiscovery(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === activePeripheral, phase == .ready,
              characteristic === notificationCharacteristic else { return }
        subscriptionTimeout?.cancel()
        subscriptionTimeout = nil
        isChangingSubscription = false
        isSubscribed = characteristic.isNotifying
        refreshServices(peripheral)
        if let error = error {
            status = "通知订阅失败：\(error.localizedDescription)"
            log(status)
        } else {
            status = isSubscribed ? "正在接收 005E 通知，仅记录长度；尚未认证。" : "已停止订阅 005E 通知。"
            log(status)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === activePeripheral, phase == .ready else { return }
        if characteristic === batteryCharacteristic {
            batteryTimeout?.cancel()
            batteryTimeout = nil
            isReadingBattery = false
            if let error = error {
                status = "电量读取失败：\(error.localizedDescription)"
            } else if let value = characteristic.value, value.count == 1, let percent = value.first, percent <= 100 {
                batteryLevel = Int(percent)
                status = "标准电量：\(percent)%；此结果不代表手环认证成功。"
            } else {
                status = "电量特征返回格式无效。"
            }
            log(status)
        } else if characteristic === notificationCharacteristic {
            if let error = error { log("通知接收失败：\(error.localizedDescription)") }
            else {
                notificationCount += 1
                log("005E 通知 #\(notificationCount)：\(characteristic.value?.count ?? 0) 字节（未记录内容）。")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === activePeripheral, phase == .ready || phase == .discovering else { return }
        failDiscovery("设备服务发生变化，请断开并重新连接。", peripheral: peripheral)
    }
}
