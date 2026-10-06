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
    var systemConnected: Bool? = nil
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

// CBCentralManager, Rust sessions and write queues are confined to the main
// queue. Keys stay in Keychain and are excluded from logs and exports.
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
    @Published private(set) var authState = "尚未连接"
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isSyncing = false
    @Published private(set) var hasStoredKey = false
    @Published private(set) var lastDevice: ScanDevice?
    @Published private(set) var firmware: String?
    @Published private(set) var modelName: String?
    @Published private(set) var keyError: String?
    @Published private(set) var syncMessage = "还没有同步健康数据"
    @Published private(set) var healthExportURL: URL?
    @Published private(set) var retrievedConnectedCount = 0
    @Published private(set) var scanResultCount = 0
    let archive = HealthArchive()

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
    private var session: RustSession?
    private var sessionTimer: DispatchSourceTimer?
    private var writeTimeout: DispatchWorkItem?
    private var syncTimeout: DispatchWorkItem?
    private var writeQueue: [Data] = []
    private var awaitingWriteResponse = false
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var sessionStartedAt: TimeInterval?
    private var isAppActive = true
    private var backgroundStartedAt: TimeInterval?
    private var scannedIdentifiers = Set<UUID>()
    private var automaticReconnectAttempts = 0
    private var authenticationTimeoutSeconds: TimeInterval = 45
    private var syncHadFailures = false

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "band9.last-device") {
            lastDevice = try? JSONDecoder().decode(ScanDevice.self, from: data)
        }
    }

    var currentDeviceID: UUID? { selectedDevice?.id ?? lastDevice?.id }

    var pendingDeviceImportURL: URL? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("private-band-auth-key.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var coreVersion: String { RustBridge.version }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var canReadBattery: Bool {
        phase == .ready && discoveryComplete && isConnected && batteryCharacteristic != nil && !isReadingBattery
    }

    var canSubscribe: Bool {
        phase == .ready && discoveryComplete && isConnected && notificationCharacteristic != nil && !isChangingSubscription
    }

    func scan() {
        automaticReconnectAttempts = 0
        request(.scan)
    }

    func connect(_ device: ScanDevice) {
        automaticReconnectAttempts = 0
        request(.connect(device.id))
    }

    func reconnect() {
        automaticReconnectAttempts = 0
        guard let device = selectedDevice ?? lastDevice else { scan(); return }
        request(.connect(device.id))
    }

    func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        if case .scan = pendingAction { pendingAction = .none }
        central?.stopScan()
        if isScanning {
            isScanning = false
            isBusy = false
            status = devices.isEmpty ? "暂未找到手环。请靠近手机并唤醒手环；已连接系统的设备也会出现在列表中。" : "扫描已停止，共发现 \(devices.count) 台设备。"
            log("扫描停止：广播发现 \(scanResultCount) 台，系统已连接 \(retrievedConnectedCount) 台，共 \(devices.count) 台候选设备。")
            prepareExport()
        }
    }

    func disconnect() { request(.none) }

    func suspend() {
        // The iOS permission dialog can briefly make the scene inactive. The
        // caller invokes this only for the background scene phase.
        isAppActive = false
        backgroundStartedAt = ProcessInfo.processInfo.systemUptime
        stopScan()
        session?.pauseClock()
        sessionTimer?.cancel()
        sessionTimer = nil
        writeTimeout?.cancel()
        writeTimeout = nil
        syncTimeout?.cancel()
        syncTimeout = nil
        if isConnected { log("进入后台，保留设备连接并暂停主动发送。") }
        prepareExport()
    }

    func resume() {
        guard !isAppActive else { return }
        isAppActive = true
        if let started = backgroundStartedAt, let authStarted = sessionStartedAt {
            sessionStartedAt = authStarted + ProcessInfo.processInfo.systemUptime - started
        }
        backgroundStartedAt = nil
        session?.resumeClock()
        if session != nil {
            startSessionTimer()
            if awaitingWriteResponse { armWriteTimeout() }
            if isSyncing { armSyncTimeout() }
            drainWriteQueue()
        }
    }

    private func request(_ action: NextAction, completionStatus: String? = nil) {
        generation = UUID()
        destroySession()
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
            scannedIdentifiers.removeAll()
            scanResultCount = 0
            retrievedConnectedCount = 0
            mergeSystemConnectedDevices(central)
            isScanning = true
            isBusy = false
            status = "正在扫描附近的蓝牙设备（最多 15 秒）…"
            central.scanForPeripherals(withServices: nil,
                                      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("开始前台扫描，不按设备名称过滤。")
            scanTimeout = schedule(after: 15) { [weak self] in self?.stopScan() }
        case .connect(let id):
            let recovered = central.retrievePeripherals(withIdentifiers: [id]).first
            guard let peripheral = peripherals[id] ?? recovered,
                  let device = devices.first(where: { $0.id == id }) ?? lastDevice.flatMap({ $0.id == id ? $0 : nil }) else {
                status = "设备记录已失效，请重新扫描。"
                return
            }
            selectedDevice = device
            lastDevice = device
            if let stored = try? JSONEncoder().encode(device) { UserDefaults.standard.set(stored, forKey: "band9.last-device") }
            hasStoredKey = (try? DeviceKeyStore.load(for: device.id)) != nil
            authState = "等待蓝牙连接"
            keyError = nil
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
        firmware = nil
        modelName = nil
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
        let redacted = message.replacingOccurrences(of: "(?i)\\b[0-9a-f]{32,}\\b", with: "〈数据已隐藏〉", options: .regularExpression)
        logs.append(DiagnosticLog(time: Date(), message: redacted))
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    private func mergeSystemConnectedDevices(_ central: CBCentralManager) {
        let knownServices = ["FE95", "FEE0", "180D"].map(CBUUID.init(string:))
        let connected = central.retrieveConnectedPeripherals(withServices: knownServices)
        retrievedConnectedCount = connected.count
        for peripheral in connected {
            peripherals[peripheral.identifier] = peripheral
            if !devices.contains(where: { $0.id == peripheral.identifier }) {
                devices.append(ScanDevice(id: peripheral.identifier, name: peripheral.name ?? "系统已连接的蓝牙设备",
                                          rssi: nil, advertisedServices: [], lastSeen: Date(), systemConnected: true))
            }
        }
        log("从系统获取到 \(connected.count) 台已连接的候选设备。")
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
        status = "服务发现完成，正在检查设备认证条件。"
        log("服务发现完成：\(services.count) 个服务，\(services.reduce(0) { $0 + $1.characteristics.count }) 个特征。")
        do {
            diagnosis = try RustBridge.diagnose(services: services)
            log("Rust 核心完成服务特征诊断。")
            beginAuthenticationIfPossible()
        } catch {
            diagnosis = nil
            status = "服务已完整发现，但 Rust 诊断失败：\(error.localizedDescription)"
            log("Rust 诊断失败：\(error.localizedDescription)")
        }
        prepareExport()
    }

    private func failDiscovery(_ message: String, peripheral: CBPeripheral) {
        operationTimeout?.cancel()
        operationTimeout = nil
        phase = .failed
        isBusy = false
        discoveryComplete = false
        diagnosis = nil
        destroySession()
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
        // The write capability identifies the pair before authentication starts.
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
        if !enable { destroySession() }
        peripheral.setNotifyValue(enable, for: characteristic)
        log(enable ? "用户请求订阅 005E 通知。" : "用户请求停止订阅 005E 通知。")
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
            let isAuthenticated: Bool
            let authenticationState: String
            let serviceDiscoveryComplete: Bool
            let device: ScanDevice?
            let services: [ServiceSnapshot]
            let diagnosis: CoreDiagnosis?
            let batteryPercent: Int?
            let notificationCount: Int
            let logs: [DiagnosticLog]
            let limitations: [String]
            let scanResults: [ScanDevice]
            let retrieveConnectedCount: Int
            let scanCount: Int
        }
        let report = Report(schemaVersion: 1, exportedAt: Date(), appVersion: appVersion,
                            coreVersion: coreVersion, systemVersion: UIDevice.current.systemVersion,
                            bluetoothState: bluetoothState, status: status, phase: phase.rawValue,
                            isConnected: isConnected, isAuthenticated: isAuthenticated, authenticationState: authState,
                            serviceDiscoveryComplete: discoveryComplete,
                            device: selectedDevice, services: services, diagnosis: diagnosis,
                            batteryPercent: batteryLevel, notificationCount: notificationCount, logs: logs,
                            limitations: ["服务匹配本身不能证明设备型号或认证成功。", "健康记录保存在本机；当前未写入 HealthKit。", "不包含密钥、会话随机数或通知原始内容；包含设备名称和本机蓝牙设备标识。"],
                            scanResults: devices, retrieveConnectedCount: retrievedConnectedCount, scanCount: scanResultCount)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Band9Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("band9-diagnostics.json")
            try encoder.encode(report).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
            destroySession()
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
        scannedIdentifiers.insert(peripheral.identifier)
        scanResultCount = scannedIdentifiers.count
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            var updated = device
            updated.systemConnected = devices[index].systemConnected
            devices[index] = updated
        } else {
            devices.append(device)
        }
        devices.sort {
            if ($0.systemConnected == true) != ($1.systemConnected == true) { return $0.systemConnected == true }
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
        let previousFailure = phase == .failed ? finalStopStatus : nil
        destroySession()
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
        else if let previousFailure = previousFailure {
            status = previousFailure
            authState = "认证或通信失败"
        }
        prepareExport()
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
            status = isSubscribed ? "设备通知已开启。" : "已停止订阅 005E 通知。"
            log(status)
            if isSubscribed { startAuthenticatedSession() }
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
                if let value = characteristic.value, session != nil { runSessionCommand("receive", hex: value.hex) }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === activePeripheral, phase == .ready || phase == .discovering else { return }
        failDiscovery("设备服务发生变化，请断开并重新连接。", peripheral: peripheral)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral === activePeripheral, phase == .ready else { return }
        drainWriteQueue()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === activePeripheral, characteristic === sessionWriteCharacteristic,
              session != nil, awaitingWriteResponse else { return }
        writeTimeout?.cancel()
        writeTimeout = nil
        awaitingWriteResponse = false
        if let error = error { sessionFailure("蓝牙发送失败：\(error.localizedDescription)") }
        else { drainWriteQueue() }
    }
}

extension BluetoothModel {
    private var sessionWriteCharacteristic: CBCharacteristic? {
        guard let notification = notificationCharacteristic, let service = notification.service,
              let uuid = diagnosis?.suggestedWriteUUID else { return nil }
        return service.characteristics?.first {
            $0.uuid == CBUUID(string: uuid) && ($0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse))
        }
    }

    func saveDeviceKey(_ text: String) -> Bool {
        guard let device = selectedDevice ?? lastDevice else {
            keyError = "请先扫描并选择需要连接的手环。"
            return false
        }
        do {
            try DeviceKeyStore.save(text, for: device.id)
            hasStoredKey = true
            keyError = nil
            log("设备密钥已保存在本机钥匙串。")
            if session != nil { reconnect() }
            else { beginAuthenticationIfPossible() }
            return true
        } catch { keyError = error.localizedDescription; return false }
    }

    func importDeviceRecord(_ candidate: DeviceKeyStore.ImportCandidate) -> Bool {
        guard !candidate.invalidPeripheralID else {
            keyError = "这条记录的蓝牙标识格式无效，请重新导出设备文件。"
            return false
        }
        guard let id = candidate.peripheralID else {
            guard currentDeviceID != nil else {
                keyError = "这条记录没有本机蓝牙标识，请先扫描并选择对应手环，再导入密钥。"
                return false
            }
            return saveDeviceKey(candidate.key)
        }
        do {
            // The explicit selection binds the key to the record's UUID, never
            // to a different device that happened to be selected previously.
            try DeviceKeyStore.save(candidate.key, for: id)
            let device = ScanDevice(id: id, name: candidate.deviceName ?? candidate.label,
                                    rssi: nil, advertisedServices: [], lastSeen: Date())
            resetReport()
            selectedDevice = device
            lastDevice = device
            if let stored = try? JSONEncoder().encode(device) { UserDefaults.standard.set(stored, forKey: "band9.last-device") }
            hasStoredKey = true
            keyError = nil
            automaticReconnectAttempts = 0
            log("已选择设备文件中的记录，密钥保存在该设备对应的本机钥匙串。")
            request(.connect(id))
            return true
        } catch { keyError = error.localizedDescription; return false }
    }

    func removeDeviceKey() {
        guard let id = currentDeviceID else { return }
        do {
            try DeviceKeyStore.remove(for: id)
            disconnect()
            hasStoredKey = false
            keyError = nil
            authState = "设备密钥已从本机删除"
        } catch { keyError = error.localizedDescription }
    }

    private func beginAuthenticationIfPossible() {
        guard phase == .ready, isConnected, session == nil, let id = selectedDevice?.id else { return }
        guard notificationCharacteristic != nil, sessionWriteCharacteristic != nil else {
            authState = "此设备未发现受支持的小米 V2 通道"
            status = "可在连接诊断中查看服务清单。"
            return
        }
        do {
            guard try DeviceKeyStore.load(for: id) != nil else {
                hasStoredKey = false
                authState = "需要设备密钥"
                status = "已连接手环，请添加此设备的 AuthKey 后认证。"
                return
            }
            hasStoredKey = true
            isSubscribed = notificationCharacteristic?.isNotifying == true
            if isSubscribed { startAuthenticatedSession() }
            else {
                authState = "正在开启设备通知"
                if !isChangingSubscription { toggleSubscription() }
            }
        } catch { keyError = error.localizedDescription; authState = "无法读取设备密钥" }
    }

    private func startAuthenticatedSession() {
        guard session == nil, phase == .ready, isConnected, isSubscribed,
              let peripheral = activePeripheral, let characteristic = sessionWriteCharacteristic,
              let id = selectedDevice?.id else { return }
        do {
            guard let key = try DeviceKeyStore.load(for: id) else { authState = "需要设备密钥"; return }
            writeType = characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            let mtu = peripheral.maximumWriteValueLength(for: writeType)
            guard mtu >= 20 else { sessionFailure("设备蓝牙写入容量不足，无法开始认证。"); return }
            session = try RustSession(key: key, mtu: mtu)
            sessionStartedAt = ProcessInfo.processInfo.systemUptime
            authenticationTimeoutSeconds = 45
            authState = "正在安全认证"
            log("创建新的 Rust 认证会话，随机数由系统安全生成。")
            startSessionTimer()
            runSessionCommand("start")
        } catch { sessionFailure(error.localizedDescription) }
    }

    private func destroySession() {
        sessionTimer?.cancel()
        sessionTimer = nil
        writeTimeout?.cancel()
        writeTimeout = nil
        syncTimeout?.cancel()
        syncTimeout = nil
        session?.close()
        session = nil
        sessionStartedAt = nil
        writeQueue.removeAll()
        awaitingWriteResponse = false
        isAuthenticated = false
        if isSyncing { syncMessage = "同步已中断，已收到的数据保留在本机。" }
        isSyncing = false
        authState = "尚未认证"
    }

    private func startSessionTimer() {
        guard isAppActive, session != nil, sessionTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.session != nil else { return }
            if !self.isAuthenticated, let started = self.sessionStartedAt,
               ProcessInfo.processInfo.systemUptime - started > self.authenticationTimeoutSeconds {
                self.sessionFailure("认证超时，请确认设备密钥属于这只手环后重新连接。")
                return
            }
            self.runSessionCommand("tick")
        }
        sessionTimer = timer
        timer.resume()
    }

    private func armWriteTimeout() {
        writeTimeout?.cancel()
        writeTimeout = schedule(after: 8) { [weak self] in
            self?.sessionFailure("蓝牙发送确认超时，请重新连接。")
        }
    }

    private func armSyncTimeout() {
        syncTimeout?.cancel()
        syncTimeout = schedule(after: 180) { [weak self] in
            guard let self = self, self.isSyncing else { return }
            self.isSyncing = false
            self.syncMessage = "本次同步超过 3 分钟；已收到的数据保留在本机，可重新连接后再试。"
            self.log(self.syncMessage)
        }
    }

    private func sessionFailure(_ message: String) {
        destroySession()
        authState = "认证或通信失败"
        status = message
        finalStopStatus = message
        log(message)
        // Stop notifications and the physical connection so delayed responses
        // from a failed session can never enter a replacement Rust session.
        if let peripheral = activePeripheral {
            phase = .failed
            central?.cancelPeripheralConnection(peripheral)
        }
        prepareExport()
    }

    private func runSessionCommand(_ operation: String, hex: String? = nil) {
        guard let session = session else { return }
        do {
            let response = try session.command(operation, hex: hex)
            if let reconnect = response.events.first(where: { $0.kind == "reconnect_required" }) {
                handleSessionEvent(reconnect)
                return
            }
            if response.state == "failed" {
                sessionFailure(response.error ?? "手环认证或协议处理失败，请重新连接。")
                return
            }
            if let error = response.error {
                log("协议提示，继续处理本次响应：\(error)")
            }
            // Preserve Rust's order, including all fragments of a frame.
            for item in response.outbound {
                guard let data = Data(hex: item.hex), !data.isEmpty else { throw RustSession.Failure.malformedHex }
                writeQueue.append(data)
            }
            guard writeQueue.count <= 4096 else { sessionFailure("发送队列超出上限，请重新连接。"); return }
            drainWriteQueue()
            guard self.session === session else { return }
            for event in response.events {
                guard self.session === session else { return }
                handleSessionEvent(event)
            }
        } catch { sessionFailure(error.localizedDescription) }
    }

    private func drainWriteQueue() {
        guard isAppActive, session != nil, phase == .ready, !awaitingWriteResponse,
              let peripheral = activePeripheral, let characteristic = sessionWriteCharacteristic else { return }
        while !writeQueue.isEmpty {
            if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                if writeTimeout == nil { armWriteTimeout() }
                return
            }
            writeTimeout?.cancel()
            writeTimeout = nil
            let data = writeQueue.removeFirst()
            guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else {
                sessionFailure("协议数据超过当前蓝牙写入容量，请重新连接。")
                return
            }
            if writeType == .withResponse { awaitingWriteResponse = true }
            peripheral.writeValue(data, for: characteristic, type: writeType)
            if writeType == .withResponse {
                armWriteTimeout()
                return
            }
        }
    }

    private func handleSessionEvent(_ event: SessionReply.Event) {
        switch event.kind {
        case "session_config":
            log(event.message)
            prepareExport()
        case "pairing_required":
            authenticationTimeoutSeconds = 120
            sessionStartedAt = ProcessInfo.processInfo.systemUptime
            authState = "等待确认配对"
            status = "请在手环或系统弹窗中确认配对。"
            log(status)
            prepareExport()
        case "reconnect_required":
            guard automaticReconnectAttempts < 2, let id = selectedDevice?.id else {
                sessionFailure("手环重复要求重新建立会话，请稍后手动重连。")
                return
            }
            automaticReconnectAttempts += 1
            log("手环要求重新建立认证会话，正在进行第 \(automaticReconnectAttempts) 次重连。")
            request(.connect(id))
        case "authenticated":
            isAuthenticated = true
            authState = "认证成功"
            status = "手环已连接，可以同步健康数据。"
            log("手环协议认证成功。")
            runSessionCommand("battery")
            runSessionCommand("device_info")
            prepareExport()
        case "battery":
            if let percent = event.data["percent"]?.number, percent >= 0, percent <= 100 {
                batteryLevel = Int(percent)
                log("已更新手环电量。")
                prepareExport()
            }
        case "device_info":
            firmware = event.data["firmware"]?.string
            modelName = event.data["model"]?.string
            prepareExport()
        case "health_file":
            guard let device = selectedDevice?.id else { return }
            do {
                let file = try JSONDecoder().decode(HealthFile.self, from: JSONEncoder().encode(event.data))
                try archive.ingest(file, device: device)
                let count = archive.files.filter { $0.deviceID == device }.count
                syncMessage = "已保存 \(count) 个健康文件。"
                log(file.parsed.status == "supported" ? "健康文件已保存并解析为 \(file.parsed.records.count) 条记录。" : "健康文件已保存；此格式暂未解析。")
            } catch {
                syncHadFailures = true
                syncMessage = "保存健康文件失败：\(error.localizedDescription)"
                log(syncMessage)
            }
        case "sync_started":
            isSyncing = true
            syncMessage = "正在获取手环健康记录…"
        case "health_file_list":
            syncMessage = "已收到健康文件目录，正在读取数据…"
        case "sync_complete":
            isSyncing = false
            syncTimeout?.cancel()
            syncTimeout = nil
            let failed = syncHadFailures || (event.data["failures"]?.number ?? 0) > 0
            syncMessage = failed ? "同步结束，部分文件未完成；已收到的数据保留在本机，可稍后重试。" : "同步完成，已收到的记录已保存在本机。"
            log(syncMessage)
            prepareExport()
        case "sync_failed":
            syncHadFailures = true
            isSyncing = false
            syncTimeout?.cancel()
            syncTimeout = nil
            syncMessage = "部分数据未完成同步，可稍后重试。"
            log(event.message)
        case "protocol_error": log("协议处理提示：\(event.message)")
        default: break
        }
    }

    func syncHealth() {
        guard isAuthenticated, !isSyncing else { return }
        isSyncing = true
        syncHadFailures = false
        syncMessage = "正在获取手环健康记录…"
        armSyncTimeout()
        runSessionCommand("sync")
    }

    func refreshBattery() {
        guard isAuthenticated else { return }
        runSessionCommand("battery")
    }

    func exportHealth() {
        guard let id = currentDeviceID else { return }
        do { healthExportURL = try archive.export(device: id); exportError = nil }
        catch { healthExportURL = nil; exportError = error.localizedDescription }
    }
}
