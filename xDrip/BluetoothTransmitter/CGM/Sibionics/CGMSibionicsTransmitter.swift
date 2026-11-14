import CoreBluetooth
import Foundation
import os

/// CN AA55 is a stream, not request-per-frame pagination. Pinned JugglucoNG
/// 11e6e29 SibionicsBleManager schedules a 60s quiet poll after ChineseData.
/// Times here are monotonic seconds; source-clock validation remains in GS1Session.
struct GS1StreamPacing {
    static let firstResponseTimeout: TimeInterval = 30
    static let quietInterval: TimeInterval = 60
    // Local transport watchdog, not a sensor protocol/lifetime constant. Only a
    // new accepted minute renews it, including after a formerly caught-up tail.
    static let noProgressTimeout: TimeInterval = 180
    enum Action: Equatable { case none, request, responseTimeout, noProgress }
    private(set) var isBusy = false
    private(set) var isDraining = false
    private var responseDeadline: TimeInterval?
    private var quietDeadline: TimeInterval?
    private var progressDeadline: TimeInterval?
    var nextDeadline: TimeInterval? { [responseDeadline, quietDeadline, progressDeadline].compactMap { $0 }.min() }

    mutating func requestSent(at now: TimeInterval) -> Bool {
        guard !isBusy, progressDeadline.map({ now < $0 }) ?? true else { return false }
        isBusy = true; isDraining = false
        responseDeadline = now + Self.firstResponseTimeout; quietDeadline = nil
        if progressDeadline == nil { progressDeadline = now + Self.noProgressTimeout }
        return true
    }
    mutating func receivedDataFrame(at now: TimeInterval, advanced: Bool) {
        isBusy = true; responseDeadline = nil; quietDeadline = now + Self.quietInterval
        if advanced || progressDeadline == nil { progressDeadline = now + Self.noProgressTimeout }
    }
    mutating func receivedNotificationFragment(at now: TimeInterval) {
        // A split frame crossing the quiet boundary is still incoming traffic.
        // This cannot extend the first-response or no-progress deadlines.
        if quietDeadline != nil { quietDeadline = now + Self.quietInterval }
    }
    mutating func rejectStream(at now: TimeInterval, advanced: Bool = false) {
        isDraining = true
        receivedDataFrame(at: now, advanced: advanced)
    }
    mutating func timerFired(at now: TimeInterval) -> Action {
        if let progressDeadline, now >= progressDeadline { return .noProgress }
        if let responseDeadline, now >= responseDeadline {
            self.responseDeadline = nil
            rejectStream(at: now)
            return .responseTimeout
        }
        if let quietDeadline, now >= quietDeadline {
            self.quietDeadline = nil; isBusy = false; isDraining = false
            return .request
        }
        return .none
    }
}

/// Factory 14-day GS1 CN / AA55. Protocol and native-core state stay on the inherited
/// central queue. AA55 writes require the UI's persisted explicit Connect authorization.
final class CGMSibionicsTransmitter: BluetoothTransmitter, CGMTransmitter {
    private weak var cgmDelegate: CGMTransmitterDelegate?
    private let configuredIdentity: GS1CNIdentity?
    private let selectedUUID: UUID?
    private let authorized: Bool
    private let delivery = CGMDeliveryGate()
    private let extendedReadingStore = GS1ExtendedReadingStore()
    private var session: GS1Session?
    private weak var activePeripheral: CBPeripheral?
    private var assembler = GS1PacketAssembler(layout: .fixed10)
    private let statusLog = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryBlueToothTransmitter)
    private let deviceInformationService = CBUUID(string: "180A")
    private let deviceInformationFields = Set(["2A23", "2A24", "2A25", "2A26", "2A27", "2A29"])
    private var deviceInformation: [String: String] = [:]
    private var deviceInformationValues: [String: Data] = [:]
    private var detectedMAC: GS1MAC?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyReady = false
    private var beganConnection = false
    private var pacing = GS1StreamPacing()
    private var waitingForWriteCapacity = false
    private var watchdog: DispatchWorkItem?
    private var retries = 0
    private let statusLock = NSLock()
    private var statusValue = "Waiting for connection"
    var statusText: String { statusLock.lock(); defer { statusLock.unlock() }; return statusValue }
    var readOnlyDetectedMAC: GS1MAC? { statusLock.lock(); defer { statusLock.unlock() }; return detectedMAC }
    var extendedReadingForDisplay: GS1ExtendedReadingStore.Value? {
        guard let token = delivery.token(), let value = extendedReadingStore.current(), delivery.allows(token) else { return nil }
        return value
    }
    func updateExtendedReading(_ reading: GS1Session.Reading?, start: Date?, authorization: GS1ExtendedReadingConsent.Token?) {
        guard let reading, let start, let authorization, GS1ExtendedReadingConsent.allows(authorization) else {
            extendedReadingStore.update(nil)
            return
        }
        extendedReadingStore.update(.init(reading: reading, start: start, authorization: authorization))
    }
    func setExtendedReadingEnabled(_ enabled: Bool) {
        guard let configuredIdentity, let selectedUUID else { return }
        GS1ExtendedReadingConsent.setEnabled(enabled, identity: configuredIdentity.checkpointIdentity(peripheralID: selectedUUID))
        extendedReadingStore.update(nil)
    }
    private var canOperate: Bool { authorized && configuredIdentity != nil && selectedUUID != nil && delivery.token() != nil }

    init(address: String?, name: String?, code: String?, mac: String?, authorized: Bool,
         bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate) {
        selectedUUID = address.flatMap(UUID.init(uuidString:))
        configuredIdentity = try? GS1CNIdentity(sensorCode: code ?? "", mac: GS1MAC(mac ?? ""))
        self.authorized = authorized
        cgmDelegate = cGMTransmitterDelegate
        let known: DeviceAddressAndName = address.map { .alreadyConnectedBefore(address: $0, name: name ?? "GS1 CN") } ?? .notYetConnected(expectedName: nil)
        super.init(addressAndName: known, CBUUID_Advertisement: GS1ChineseProtocol.serviceUUID,
                   servicesCBUUIDs: [CBUUID(string: GS1ChineseProtocol.serviceUUID), CBUUID(string: "180A")],
                   CBUUID_ReceiveCharacteristic: GS1ChineseProtocol.notifyUUID,
                   CBUUID_WriteCharacteristic: GS1ChineseProtocol.writeUUID,
                   bluetoothTransmitterDelegate: bluetoothTransmitterDelegate)
    }
    func cgmTransmitterType() -> CGMTransmitterType { .sibionicsCN }
    func sensorWarmupDurationInMinutes() -> Double? { GS1Policy.warmup / 60 }
    func getCBUUID_Service() -> String { GS1ChineseProtocol.serviceUUID }
    func getCBUUID_Receive() -> String { GS1ChineseProtocol.notifyUUID }
    func maxSensorAgeInDays() -> Double? { 14 }
    // Existing app contract for already calibrated values; this decoder runs locally.
    func isWebOOPEnabled() -> Bool { true }
    func nonWebOOPAllowed() -> Bool { false }
    func needsSensorStartTime() -> Bool { false }
    func needsSensorStartCode() -> Bool { false }
    func requestNewReading() { runOnCentralQueue { [weak self] in self?.requestHistory() } }
    override func shouldTimeoutStalledConnectionSetup() -> Bool { true }
    override func shouldConnectToDiscoveredPeripheral(_ peripheral: CBPeripheral) -> Bool {
        canOperate && selectedUUID == peripheral.identifier
    }
    override func connect() { if canOperate { super.connect() } }
    override func startScanning() -> BluetoothTransmitter.startScanningResult {
        guard canOperate else { return .other(reason: "GS1 Connect authorization and selected device are required") }
        return super.startScanning()
    }
    override func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard canOperate else { central.stopScan(); return }
        if central.state != .poweredOn { resetTransport(); setStatus("Waiting for Bluetooth") }
        super.centralManagerDidUpdateState(central)
    }
    override func reconnectAfterDisconnect(_ central: CBCentralManager) {
        if canOperate { super.reconnectAfterDisconnect(central) }
    }
    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard canOperate, peripheral.identifier == selectedUUID else { central.cancelPeripheralConnection(peripheral); return }
        resetTransport(); activePeripheral = peripheral
        super.centralManager(central, didConnect: peripheral)
        armConnectionWatchdog()
    }
    override func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selectedUUID else { return }
        resetTransport(); setStatus("GS1 connection failed; retrying")
        guard canOperate, let token = delivery.token() else { return }
        runOnCentralQueue(after: 5) { [weak self, weak central, weak peripheral] in
            guard let self, let central, let peripheral, self.delivery.allows(token), self.canOperate,
                  central.state == .poweredOn, peripheral.state == .disconnected else { return }
            central.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true, CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
        }
    }
    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == selectedUUID else { return }
        resetTransport(); setStatus("GS1 disconnected; waiting to reconnect")
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }
    override func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        // The base class takes its first restored peripheral; filter before calling it.
        for peripheral in restored where !canOperate || peripheral.identifier != selectedUUID {
            central.cancelPeripheralConnection(peripheral)
        }
        guard canOperate, let peripheral = restored.first(where: { $0.identifier == selectedUUID }) else { return }
        resetTransport(); activePeripheral = peripheral
        var filtered = dict
        filtered[CBCentralManagerRestoredStatePeripheralsKey] = [peripheral]
        super.centralManager(central, willRestoreState: filtered)
        // A restored pending connection can legitimately wait while out of range.
        // Start the setup deadline only once connected; didConnect handles that later.
        if peripheral.state == .connected { armConnectionWatchdog() }
    }
    override func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        trace("GS1 services callback current=%{public}@ error=%{public}@", log: statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info, isCurrent(peripheral).description, (error != nil).description)
        guard isCurrent(peripheral) else { return }
        if error != nil { recoverConnection("GS1 service discovery failed"); return }
        deviceInformation["phase"] = "servicesObserved"
        deviceInformation["service180A"] = (peripheral.services?.contains(where: { $0.uuid == deviceInformationService }) == true).description
        saveDeviceInformation()
        guard peripheral.services?.contains(where: { $0.uuid == CBUUID(string: GS1ChineseProtocol.serviceUUID) }) == true else {
            halt("The selected device does not expose the GS1 CN service"); return
        }
        super.peripheral(peripheral, didDiscoverServices: error)
        armConnectionWatchdog()
    }
    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isCurrent(peripheral) else { return }
        if service.uuid == deviceInformationService {
            deviceInformation["phase"] = "characteristicsObserved"
            for value in service.characteristics ?? [] where deviceInformationFields.contains(value.uuid.uuidString) {
                deviceInformation[value.uuid.uuidString + ".readable"] = value.properties.contains(.read).description
                if error == nil, value.properties.contains(.read) { peripheral.readValue(for: value) }
            }
            saveDeviceInformation()
            return
        }
        guard service.uuid == CBUUID(string: GS1ChineseProtocol.serviceUUID) else { return }
        guard error == nil, let characteristics = service.characteristics,
              let write = characteristics.first(where: { $0.uuid == CBUUID(string: GS1ChineseProtocol.writeUUID) }),
              let notify = characteristics.first(where: { $0.uuid == CBUUID(string: GS1ChineseProtocol.notifyUUID) }),
              write.properties.contains(.write) || write.properties.contains(.writeWithoutResponse),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            halt("The selected device does not expose supported GS1 CN characteristics"); return
        }
        writeCharacteristic = write
        super.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        // A restored subscription may already be active without another state callback.
        notifyReady = notify.isNotifying
        if notifyReady { begin() } else { armConnectionWatchdog() }
    }
    override func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == CBUUID(string: GS1ChineseProtocol.notifyUUID) else { return }
        super.peripheral(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
        guard error == nil, characteristic.isNotifying else { recoverConnection("GS1 notification subscription failed"); return }
        notifyReady = true
        if writeCharacteristic != nil { begin() }
    }
    override func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isCurrent(peripheral), characteristic.uuid == CBUUID(string: GS1ChineseProtocol.writeUUID) else { return }
        if error != nil { retryResponse("GS1 request was not acknowledged") }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isCurrent(peripheral), waitingForWriteCapacity else { return }
        waitingForWriteCapacity = false
        requestHistory()
    }
    private func begin() {
        guard canOperate, notifyReady, !beganConnection, let identity = configuredIdentity, let selectedUUID else { return }
        do {
            if session == nil {
                let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("GS1Sessions", isDirectory: true)
                session = try GS1Session(identity: identity.checkpointIdentity(peripheralID: selectedUUID), sensitivity: identity.sensitivity, storage: base)
            }
            beganConnection = true; retries = 0
            requestHistory()
        } catch { halt("GS1 history or checkpoint could not be restored. No readings are being published.") }
    }
    private func requestHistory() {
        guard canOperate, beganConnection, !pacing.isBusy, notifyReady, let peripheral = activePeripheral,
              isCurrent(peripheral), peripheral.state == .connected, let characteristic = writeCharacteristic,
              let identity = configuredIdentity, let session else { return }
        guard session.nextIndex <= 65535 else { halt("Sensor index exhausted"); return }
        do {
            let data = try GS1ChineseProtocol.request(index: session.nextIndex, mac: identity.mac)
            let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
            if type == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
                waitingForWriteCapacity = true; armConnectionWatchdog(); return
            }
            guard pacing.requestSent(at: ProcessInfo.processInfo.systemUptime) else {
                armStreamWatchdog(); return
            }
            waitingForWriteCapacity = false
            // Immediate central-queue write: it cannot survive halt/release in a
            // separate async closure, and the generic logger never sees the MAC.
            peripheral.writeValue(data, for: characteristic, type: type)
            setStatus(session.lastStatus)
            armStreamWatchdog()
        } catch { halt("Unsupported GS1 request") }
    }
    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if isCurrent(peripheral), characteristic.service?.uuid == deviceInformationService,
           deviceInformationFields.contains(characteristic.uuid.uuidString) {
            let key = characteristic.uuid.uuidString
            deviceInformation["phase"] = "fieldRead"
            deviceInformation[key + ".error"] = (error != nil).description
            deviceInformation.removeValue(forKey: key + ".hex")
            deviceInformation.removeValue(forKey: key + ".length")
            deviceInformationValues.removeValue(forKey: key)
            if error == nil, let value = characteristic.value {
                deviceInformationValues[key] = value
                deviceInformation[key + ".hex"] = value.map { String(format: "%02X", $0) }.joined()
                deviceInformation[key + ".length"] = value.count.description
            }
            saveDeviceInformation()
            return
        }
        // Do not pass raw signal payloads to the generic public trace logger.
        guard isCurrent(peripheral), beganConnection, notifyReady,
              characteristic.uuid == CBUUID(string: GS1ChineseProtocol.notifyUUID) else { return }
        guard error == nil, let data = characteristic.value, !data.isEmpty else { retryResponse("GS1 notification failed"); return }
        requestSignalStrengthForTraceIfNeeded(from: peripheral)
        let received = Date()
        pacing.receivedNotificationFragment(at: ProcessInfo.processInfo.systemUptime)
        armStreamWatchdog()
        do {
            for packet in try assembler.append(data) {
                guard canOperate else { return }
                switch packet {
                case .echo: break
                case .encryptedProtocolRequired:
                    halt("This GS1 requires the V120 protocol. This build supports CN AA55 only; no glucose is published.")
                    return
                case .samples(let samples):
                    receiveSamples(samples, received: received)
                }
            }
        } catch is GS1ProtocolError {
            // A malformed frame is a real framing reset. A routine poll or a
            // request retry must not discard a partial following frame.
            assembler.reset()
            retryResponse("Invalid GS1 frame; waiting for the stream to become quiet")
        } catch { halt("GS1 response could not be decoded; no readings are being published.") }
    }
    private func receiveSamples(_ samples: [GS1RawSample], received: Date) {
        guard let session else { return }
        let monotonicNow = ProcessInfo.processInfo.systemUptime
        if pacing.isDraining {
            // Keep consuming complete frames after a failed response. They
            // cannot overwrite the rejection status or advance the saved core.
            pacing.receivedDataFrame(at: monotonicNow, advanced: false)
            armStreamWatchdog()
            return
        }
        let oldIndex = session.nextIndex
        do {
            let authorization = GS1ExtendedReadingConsent.token(session.identity)
            let readings = try session.ingest(samples, received: received, now: Date(), extendedAuthorization: authorization) { [weak self] index, status in
                guard let self else { return }
                trace("GS1 native index=%{public}d status=%{public}@", log: self.statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info, index, status)
            }
            let advanced = session.nextIndex > oldIndex
            pacing.receivedDataFrame(at: monotonicNow, advanced: advanced)
            if advanced { retries = 0 }
            updateExtendedReading(session.extendedReading(at: Date()), start: session.start, authorization: authorization)
            trace("GS1 accepted samples=%{public}d nextIndex=%{public}d historyReady=%{public}@ published=%{public}d", log: statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info, samples.count, session.nextIndex, session.historyReady.description, readings.count)
            setStatus(session.historyReady ? session.lastStatus : "Downloading GS1 history: minute \(session.nextIndex)")
            publish(readings, observation: session.liveObservation(at: Date()))
            // Every valid frame, including a duplicate or empty frame, renews
            // only the quiet poll. Only real progress renews the hard watchdog.
            armStreamWatchdog()
        } catch GS1SessionError.timeline {
            let timing = samples.map { "index=\($0.index),remaining=\($0.remaining),addedSeconds=\($0.addedSeconds)" }.joined(separator: "; ")
            trace("GS1 timing rejected: %{public}@ receivedUnix=%{public}f records=[%{public}@]", log: statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info, session.timelineIssue?.diagnostic ?? "unclassified timeline error", received.timeIntervalSince1970, timing)
            halt("GS1 receive clock or record is invalid. The saved session was kept; no readings are being published.")
        } catch GS1SessionError.conflictingSample {
            halt("GS1 history conflicts with the saved sensor session; no readings are being published.")
        } catch { halt("GS1 history could not be saved or decoded; no readings are being published.") }
    }
    func publish(_ readings: [GS1Session.Reading], observation: GS1Session.Observation?) {
        guard let observation, let token = delivery.token() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.delivery.allows(token) else { return }
            let now = Date()
            guard observation.isCurrent(at: now) else { return }
            self.cgmDelegate?.sensorSessionObserved(startDate: observation.start, from: self)
            self.bluetoothTransmitterDelegate?.heartBeat()
            let current = readings.filter { now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) <= 120 }
            guard let latestDate = current.map(\.date).max() else { return }
            var glucose = current.sorted { $0.date > $1.date }.map { GlucoseData(timeStamp: $0.date, glucoseLevelRaw: $0.mgdl) }
            // The coordinator reconstructs start as latest reading date minus age.
            // Use that same event time so BLE/dispatch latency cannot shift the start.
            self.cgmDelegate?.cgmTransmitterInfoReceived(glucoseData: &glucose, transmitterBatteryInfo: nil, sensorAge: latestDate.timeIntervalSince(observation.start))
        }
    }
    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        canOperate && peripheral.identifier == selectedUUID && activePeripheral === peripheral
    }
    private func resetTransport() {
        watchdog?.cancel(); watchdog = nil; delivery.invalidate()
        extendedReadingStore.update(nil)
        deviceInformation = ["connectionStartedAtUnix": Date().timeIntervalSince1970.description]
        deviceInformationValues.removeAll()
        statusLock.lock(); detectedMAC = nil; statusLock.unlock()
        assembler.reset(); writeCharacteristic = nil; notifyReady = false; beganConnection = false
        pacing = GS1StreamPacing(); waitingForWriteCapacity = false; activePeripheral = nil
    }
    private func retryResponse(_ message: String) {
        guard canOperate else { return }
        extendedReadingStore.update(nil)
        session?.discardExtendedReading()
        waitingForWriteCapacity = false
        pacing.rejectStream(at: ProcessInfo.processInfo.systemUptime)
        retries += 1; setStatus(message)
        if retries > 3 { recoverConnection("GS1 response timed out; reconnecting") }
        else { armStreamWatchdog() }
    }
    private func recoverConnection(_ message: String) {
        guard canOperate else { return }
        resetTransport(); retries = 0; setStatus(message)
        stopConnectAndRestartScanning(forgetDeviceOnTimeout: false)
    }
    private func armConnectionWatchdog() {
        scheduleWatchdog(after: 12) { [weak self] in
            self?.recoverConnection("GS1 connection setup or write capacity timed out")
        }
    }
    private func armStreamWatchdog() {
        guard let deadline = pacing.nextDeadline else { watchdog?.cancel(); watchdog = nil; return }
        scheduleWatchdog(after: max(0, deadline - ProcessInfo.processInfo.systemUptime)) { [weak self] in
            guard let self else { return }
            switch self.pacing.timerFired(at: ProcessInfo.processInfo.systemUptime) {
            case .none: self.armStreamWatchdog()
            case .request: self.requestHistory()
            case .responseTimeout: self.retryResponse("GS1 response timed out; waiting for quiet before retrying")
            case .noProgress: self.recoverConnection("GS1 history made no progress for 3 minutes; reconnecting from the saved minute")
            }
        }
    }
    private func scheduleWatchdog(after interval: TimeInterval, action: @escaping () -> Void) {
        watchdog?.cancel()
        guard let token = delivery.token() else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.canOperate, self.delivery.allows(token) else { return }
            action()
        }
        watchdog = work
        runOnCentralQueue(after: interval) { if !work.isCancelled { work.perform() } }
    }
    private func setStatus(_ value: String) {
        statusLock.lock(); let changed = statusValue != value; statusValue = value; statusLock.unlock()
        if changed { trace("GS1 status: %{public}@", log: statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info, value) }
    }
    private func saveDeviceInformation() {
        // Local read-only hardware investigation. No raw values enter trace,
        // glucose decoding, identity selection, cloud or shared app containers.
        do {
            let resolved = GS1Setup.deviceInformationMAC(deviceInformationValues)
            statusLock.lock(); let changed = detectedMAC != resolved; detectedMAC = resolved; statusLock.unlock()
            if let resolved {
                deviceInformation["detectedMAC"] = resolved.string
                deviceInformation["matchesConfiguredMAC"] = configuredIdentity.map { ($0.mac == resolved).description }
            } else {
                deviceInformation.removeValue(forKey: "detectedMAC")
                deviceInformation.removeValue(forKey: "matchesConfiguredMAC")
            }
            if changed, resolved != nil { trace("GS1 hardware MAC read from Device Information", log: statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info) }
            deviceInformation["capturedAtUnix"] = Date().timeIntervalSince1970.description
            let base = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONSerialization.data(withJSONObject: deviceInformation, options: [.sortedKeys])
            try data.write(to: base.appendingPathComponent("GS1DeviceInformation.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            trace("GS1 device information snapshot unavailable", log: statusLog, category: ConstantsLog.categoryBlueToothTransmitter, type: .info)
        }
    }
    private func halt(_ message: String) {
        delivery.stop(); watchdog?.cancel(); assembler.reset(); pacing = GS1StreamPacing()
        extendedReadingStore.update(nil)
        session?.discardExtendedReading()
        setStatus(message); stopScanning(); disconnect()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.delivery.isReleased else { return }
            self.bluetoothTransmitterDelegate?.error(message: message)
        }
    }
    override func prepareForRelease() {
        delivery.release()
        extendedReadingStore.update(nil)
        runOnCentralQueue { [weak self] in self?.resetTransport() }
        super.prepareForRelease()
    }
}
