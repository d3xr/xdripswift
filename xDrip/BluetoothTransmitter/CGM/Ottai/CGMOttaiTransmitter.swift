//
//  CGMOttaiTransmitter.swift
//  xdrip
//
//  Ottai / Syai CGM Bluetooth transmitter.
//
//  This is a Swift copy of OttaiBleManager.kt from JugglucoNG (the working
//  Android driver), built on xDrip's BluetoothTransmitter class. The
//  encryption, login math, packet parsing and the glucose formula live in the
//  Core/ files. This class talks to the sensor step by step, checks every
//  reading the same way the Android code does, and gives the good readings to
//  xDrip.
//
//  Same as the Kotlin where iOS allows it:
//    - connect -> reset -> find services -> turn on notifications (history,
//      live, cgm-info) -> login (Auth V2) -> read the command byte:
//      3 = streaming, 0..2 = needs activation, 4 or more = sensor ended
//      (read the live buffer only to learn the last dataNo, fetch history, no live)
//    - the live poll time comes from the 0x0777 cgm-info packet (4 or more
//      bytes, 5..3600 s, at most 60 s); the poll waits while live
//      notifications keep coming
//    - sample times come from a "stream anchor" (start = sample - dataNo * 60 s);
//      the start is saved as the activation time only after two anchors agree
//    - a dataNo limit against broken packets, with a "stop trusting the limit" rule
//    - all the checks, in this order: hard reject -> recently rejected -> warmup
//      -> continuity (one-minute jump, lonely spike in history) -> freshness
//    - history comes in blocks of 270 records, 750 ms apart, with a 12 s watchdog
//  Different on purpose (xDrip has no Room database):
//    - the first readings after connect are collected and given to xDrip ONCE,
//      newest first, so its 5-minute filter can fill the chart from empty
//    - after a start, the first backfill asks only for the records after the last
//      one xDrip already has (a saved "delivered" mark; the Kotlin uses
//      previousDataNo the same way). Only a sensor we know nothing about gets the
//      last 24 h. Missing windows are not saved between sessions
//    - NFC wake, connection priority and the outage probe do not exist on iOS
//
//  Threads: everything in this class runs on `workQueue` (one at a time).
//  CoreBluetooth callbacks are sent there in order. The base class helpers
//  (read, write, notify, disconnect) switch to their own queue, so we can call
//  them from `workQueue`. Readings go to xDrip on the main queue (Core Data).
//

import CoreBluetooth
import Foundation
import os

final class CGMOttaiTransmitter: BluetoothTransmitter, CGMTransmitter {

    // MARK: - constants (same values as OttaiBleManager.kt)

    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryCGMOttai)

    private static let mgdlPerMmoll: Double = 18.0
    private static let recordIntervalMs: Int64 = 60_000
    private static let maxLivePollIntervalMs: Int64 = 60_000
    private static let historyRequestChunkRecords = 270
    private static let historyChunkDelay: TimeInterval = 0.75
    private static let historyPageTimeout: TimeInterval = 12.0
    private static let historyMaxRetries = 3
    private static let historyRequestCooldownMs: Int64 = 60_000
    private static let recentHistoryRecords = 60
    /// xDrip only: how far back the first backfill goes (the Kotlin uses a database diff instead).
    private static let initialBackfillRecords = 24 * 60
    private static let initialHistoryDelay: TimeInterval = 4.0
    private static let initialHistoryMinSensorAgeMs: Int64 = 3 * 60_000
    private static let maxReasonableDataNoAhead = 120
    private static let maxConsecutiveCeilingFullDrops = 3
    private static let currentSampleFreshMs: Int64 = 120_000
    private static let currentSampleFloorGraceMs: Int64 = recordIntervalMs
    private static let confirmedStartAgreementMs: Int64 = 2 * recordIntervalMs
    private static let maxConsecutiveContinuityRejects = 3
    private static let postActivationConfirmDelay: TimeInterval = 1.0
    private static let postActivationConfirmRetry: TimeInterval = 1.5
    private static let postActivationConfirmMaxAttempts = 4
    private static let reauthDelay: TimeInterval = 3.0
    /// Server-assisted activation: connections per user request, as in SyaiKit.
    private static let maxServerActivationStarts = 3
    private static let pendingBindRetryDelay: TimeInterval = 60.0

    // MARK: - identity / materials

    private let sensorId: String
    private var materials: OttaiRegistry.DeviceMaterials
    private var authKeys: [[UInt8]]?
    private var macBytes: [UInt8] { OttaiCrypto.hexToBytes(sensorId) }

    private weak var cgmTransmitterDelegate: CGMTransmitterDelegate?

    /// xDrip only: sends the accepted readings to the Syai cloud when the user turned that on.
    private let cloudUploader: OttaiCloudUploader

    // MARK: - state for one connection (reset on every connect)

    private enum Phase { case idle, enablingNotify, auth, streaming }
    private enum AuthStep { case none, readDeviceTime, readDeviceParam, readDeviceSign, writeAppParam, writeAppSign, done }
    private enum ActStep {
        case none, rtc, maxActive, destruction, command, done, globalM8, globalFirmware, globalCmdGate
        case serverFirmware, serverCmdGate, serverCoefficient, serverDuration, serverRtc, serverActivate
        var isServer: Bool {
            [.serverFirmware, .serverCmdGate, .serverCoefficient, .serverDuration, .serverRtc, .serverActivate].contains(self)
        }
    }

    private var phase: Phase = .idle
    private var authStep: AuthStep = .none
    private var actStep: ActStep = .none
    private let commandStatusLock = NSLock()
    private var storedCommandStatus = -1
    private var commandStatus: Int {
        get {
            commandStatusLock.lock()
            defer { commandStatusLock.unlock() }
            return storedCommandStatus
        }
        set {
            commandStatusLock.lock()
            storedCommandStatus = newValue
            commandStatusLock.unlock()
        }
    }
    private var connectionGeneration = 0
    private var connectionID = UUID().uuidString

    private var characteristics: [String: CBCharacteristic] = [:]
    private var discoveredServices = Set<CBUUID>()
    private weak var connectedPeripheral: CBPeripheral?

    private var deviceTimeBytes: [UInt8] = []
    private var deviceParamIndex = 0
    private var deviceParamTime: [UInt8] = []
    private var devicePubX: [UInt8] = []
    private var devicePubY: [UInt8] = []
    private var appKeyPair: OttaiBleAuth.KeyPair?
    private var appIndex = 0
    private var appTime3: [UInt8] = []
    private var sessionKeyHex = ""
    private var lastAuthDevHex = ""
    // Survives reconnects so two fresh challenges can identify a wrong sensor.
    private var serverAuthSignatureFailures = 0
    private var serverAuthHostBytes: [UInt8]?
    private var serverAuthFlagBytes: [UInt8]?
    private var serverActivating = false
    private var serverFrames: (coefficient: [UInt8], duration: [UInt8], activate: [UInt8])?
    /// Compatibility with 4245: Syai's server owns this session and its activation
    /// frames. It is not the CN/Global 30-day provisioning/read-back operation.
    private var usesLegacySyaiServerActivation: Bool {
        activationAccount?.apiBase == OttaiConstants.apiBaseSyai
            && OttaiRegistry.loadPreparationCheckpoint(sensorId) == nil
    }
    private var preparingSyaiFactory = false
    private var syaiLegacyFirmwareValidated = false


    private var pendingActivation = false
    private var rediscoveredServices = Set<CBUUID>()
    /// How many services the sensor reported in the re-discovery before activation.
    private var expectedRediscoveryCount = 0
    private var activationConfirmAttempt = 0

    /// The three services the normal (streaming) connection needs.
    private static let requiredServices: Set<CBUUID> = [
        CBUUID(string: OttaiConstants.serviceAuth),
        CBUUID(string: OttaiConstants.serviceCgm),
        CBUUID(string: OttaiConstants.serviceDeviceInfo),
    ]

    private var livePollTimer: DispatchSourceTimer?
    private var liveReadInFlight = false

    // history block chain (for one connection)
    private var activeHistoryStart = -1
    private var activeHistoryEndExclusive = -1
    private var pendingHistoryReason: String?
    private var pendingHistoryNextStart = 0
    private var pendingHistoryEndExclusive = 0
    private var historyRetryCount = 0
    private var historyChunkBestDataNo = -1
    private var historyWatchdog: DispatchWorkItem?
    private var historyChunkWork: DispatchWorkItem?
    private var lastHistoryRequestAtMs: Int64 = 0

    // MARK: - state that stays across reconnects

    private var lastDataNo = 0
    /// The last dataNo that xDrip has stored, with no older records still on the way.
    /// Saved, so the next start asks the sensor only for what came after it. It stays
    /// behind `lastDataNo` while a gap fill is planned or history blocks are still coming.
    private var deliveredDataNo = 0
    /// True from the moment a gap fill after a live reading is planned until it has been
    /// sent (or found unnecessary). See `noteDelivered(upTo:)`.
    private var historyGapPending = false
    // The record size (8 or 9 bytes) learned from this sensor. 0 until a big enough
    // packet has shown it. A small live packet (one record) cannot tell the two sizes
    // apart, so it must not choose. See OttaiParser.decisiveRecordSize.
    private var learnedRecordSize = 0
    // Log only once while packets keep disagreeing with the learned size.
    private var recordSizeDisagreementLogged = false
    private var lastGlucoseAtMs: Int64 = 0
    private var lastLiveFrameAtMs: Int64 = 0
    private var lastLiveNotifyAtMs: Int64 = 0
    private var livePollIntervalMs: Int64 = recordIntervalMs
    private var activatedMaxActiveMs: Int64 = 0
    private var activationRequested = false
    private var activationCommandSentAtMs: Int64 = 0
    private var maxActiveCandidatesMs: [Int64] = []
    private var maxActiveCandidateIndex = 0
    private var maxActiveAttemptMs: Int64 = 0
    private var serverActivationStarts = 0
    /// Persisted before sending ACTIVATE; remains uncertain until a fresh command read.
    private var serverActivateAttemptedAtMs: Int64 = 0
    private var pendingBindInFlight = false
    private var activationAccount: OttaiAccountContext?
    private var globalActivationWrites: [OttaiGlobalActivation.Write] = []
    private var globalActivationWriteIndex = 0
    private var globalActivationFirmware = ""
    private var released = false
    private var preparationBindInFlight = false
    private var preparingCNFactory = false
    private var lifetimeTransaction: OttaiLifetimeTransaction?
    private var lifetimeAccount: OttaiAccountContext?
    private var lifetimeBluetoothID = ""
    private var lifetimeConnectionID = ""
    private var lifetimeReadOwner: String?
    private var lifetimeReadsBlocked = false
    private var commandReadOutstanding = false
    #if DEBUG
    var lifetimeTestRead: ((String) -> Void)?
    var lifetimeTestWrite: ((String, [UInt8]) -> Bool)?
    var lifetimeTestReadable: ((String) -> Bool)?
    var preparationTestRediscover: (() -> Void)?
    var activationTestRediscover: (() -> Void)?
    var preparationTestMaterialFetch: ((Bool, () -> Bool) -> OttaiRegistry.DeviceMaterials?)?
    var preparationTestLocalReauth: (() -> Void)?
    var serverActivationTestPendingBind: (() -> Void)?
    var streamingTestNow: (() -> Int64)?
    private var lifetimeTestContext = false
    #endif

    // stream time anchor (see seedStreamTimeAnchor / offerConfirmedActiveTime)
    private var provisionalActiveTimeMs: Int64 = 0
    private var streamStartTimeMs: Int64 = 0
    private var streamStartReliable = false
    private var pendingConfirmedStartMs: Int64 = 0
    private var pendingConfirmedDataNo = -1
    private var arrivalCorrection = OttaiArrivalStartCorrection()
    private var acceptedLiveTimes: [Int: Int64] = [:]
    private var acceptedLiveOrder: [Int] = []

    // dataNo limit
    private var consecutiveCeilingFullDrops = 0
    private var ceilingDistrusted = false

    // wrong-sensor guard. On iOS the stored BLE address is not the sensor id, so it
    // can point to an old sensor while the keys are for a new one. When the login
    // fails twice with a bad device signature, we forget that peripheral and scan
    // again, skipping the rejected one for the rest of this app run.
    private var lastVerifyFailed = false
    private var wrongSensorStrikes = 0
    private var rejectedPeripheralIdentifiers = Set<String>()
    private let rejectedIdentifiersLock = NSLock()

    // continuity check
    private struct RejectedSample { let rawCurrent: Int; let mmol: Float }
    private var recentlyRejectedSamples: [Int: RejectedSample] = [:]
    private var recentlyRejectedOrder: [Int] = []
    private var lastAcceptedDataNo = -1
    private var lastAcceptedSampleMs: Int64 = 0
    private var lastAcceptedMmol: Float = 0
    private var lastAcceptedRawCurrent = 0
    private var lastEvaluatedDataNo = -1
    private var lastEvaluatedSampleMs: Int64 = 0
    private var consecutiveContinuityRejects = 0

    // xDrip only: the last sensor session start reported to xDrip (see reportSensorSessionIfNeeded)
    private var lastReportedSensorStartMs: Int64 = 0

    // xDrip only: the first readings are collected here (see the file header)
    private var initialFlushDone = false
    private var initialHistoryRequested = false
    private var initialBuffer: [Int: GlucoseData] = [:]
    private var flushGeneration = 0

    private let workQueue = DispatchQueue(label: "CGMOttaiTransmitter.work")
    private let delivery = CGMDeliveryGate()

    // MARK: - init

    init(address: String?, name: String?, sensorId: String,
         bluetoothTransmitterDelegate: BluetoothTransmitterDelegate,
         cGMTransmitterDelegate: CGMTransmitterDelegate) {

        let canonical = OttaiConstants.canonicalSensorId(sensorId).isEmpty ? sensorId : OttaiConstants.canonicalSensorId(sensorId)
        self.sensorId = canonical
        self.materials = OttaiRegistry.loadMaterials(sensorId: canonical)
        self.authKeys = materials.authKeys
        self.cgmTransmitterDelegate = cGMTransmitterDelegate
        self.cloudUploader = OttaiCloudUploader(sensorId: canonical)

        // load the saved state (restoreFromPersistence in the Kotlin)
        self.lastDataNo = OttaiRegistry.loadLastDataNo(canonical)
        self.deliveredDataNo = OttaiRegistry.loadDeliveredDataNo(canonical)
        self.learnedRecordSize = OttaiRegistry.loadRecordSize(canonical)
        self.activatedMaxActiveMs = OttaiRegistry.loadAcceptedMaxActive(canonical)
        if materials.activeTimeMs > 0 {
            OttaiRegistry.saveProvisionalActiveTime(canonical, 0)
            self.provisionalActiveTimeMs = 0
        } else {
            self.provisionalActiveTimeMs = OttaiRegistry.loadProvisionalActiveTime(canonical)
        }
        if let b = OttaiRegistry.loadContinuityBaseline(canonical) {
            lastAcceptedDataNo = b.dataNo
            lastAcceptedSampleMs = b.sampleMs
            lastAcceptedMmol = b.mmol
            lastAcceptedRawCurrent = b.rawCurrent
            lastEvaluatedDataNo = b.dataNo
            lastEvaluatedSampleMs = b.sampleMs
        }

        // On iOS the "address" is a CoreBluetooth id, not the sensor MAC. If we have
        // one (reconnect), use it. If not, scan for a new device.
        let storedAddress = address ?? OttaiRegistry.findRecord(canonical)?.address
        let account = OttaiRegistry.accountContext()
        if let checkpoint = OttaiRegistry.loadActivationCheckpoint(canonical),
           checkpoint.matches(sensorID: canonical, bluetoothID: storedAddress ?? "", account: account) {
            self.activationAccount = account
            OttaiRegistry.saveActivationStatus(self.sensorId, nil)
            self.activationRequested = !checkpoint.confirmed
            self.serverActivateAttemptedAtMs = checkpoint.commandSentAtMs
            self.activationCommandSentAtMs = checkpoint.commandSentAtMs
        }
        let newAddressAndName: BluetoothTransmitter.DeviceAddressAndName
        if let a = storedAddress, !a.isEmpty {
            newAddressAndName = .alreadyConnectedBefore(address: a, name: name)
        } else {
            newAddressAndName = .notYetConnected(expectedName: nil)
        }

        super.init(addressAndName: newAddressAndName,
                   CBUUID_Advertisement: "181F",
                   servicesCBUUIDs: [CBUUID(string: OttaiConstants.serviceAuth),
                                     CBUUID(string: OttaiConstants.serviceCgm),
                                     CBUUID(string: OttaiConstants.serviceDeviceInfo)],
                   CBUUID_ReceiveCharacteristic: OttaiConstants.charGlucoseLive,
                   CBUUID_WriteCharacteristic: OttaiConstants.charCommand,
                   bluetoothTransmitterDelegate: bluetoothTransmitterDelegate)
    }

    // MARK: - CGMTransmitter

    func cgmTransmitterType() -> CGMTransmitterType { .ottai }
    func sensorWarmupDurationInMinutes() -> Double? {
        Double(max(OttaiConstants.warmupSuppressMs, materials.preheatPeriodMs)) / 60_000
    }
    func getCBUUID_Service() -> String { OttaiConstants.serviceCgm }
    func getCBUUID_Receive() -> String { OttaiConstants.charGlucoseLive }
    func maxSensorAgeInDays() -> Double? {
        let ms = OttaiConstants.expectedLifetimeMs(cloudActiveExpireMs: materials.activeExpireTimeMs, acceptedMaxActiveMs: activatedMaxActiveMs)
        return Double(ms) / Double(24 * 3600 * 1000)
    }
    func needsSensorStartTime() -> Bool { false }
    func needsSensorStartCode() -> Bool { false }
    /// The sensor sends glucose that is already calibrated (the cloud formula does it).
    /// Without this, xDrip keeps asking the user for a calibration value.
    func isWebOOPEnabled() -> Bool { true }
    /// The user cannot switch the calibrated mode off.
    func nonWebOOPAllowed() -> Bool { false }

    /// xDrip "start sensor" = the Ottai activation. It cannot be undone.
    /// The sensor's last command byte (3 = active, 4+ = ended, 0..2 = not started).
    /// The settings screen uses it to warn before a repeated activation.
    var sensorCommandStatus: Int { commandStatus }
    var isPreparingOrActivating: Bool {
        workQueue.sync { preparationBindInFlight || pendingActivation || serverActivating || lifetimeTransaction != nil || (actStep != .none && actStep != .done) }
    }


    private var activationHasStarted: Bool {
        // A sent command or a cloud-provided start is not physical confirmation.
        // Uncertain commands keep their durable checkpoint and only read back status.
        OttaiRegistry.activationStarted(sensorId) || OttaiRegistry.loadPendingBind(sensorId) > 0
            || OttaiRegistry.loadActivationCheckpoint(sensorId)?.confirmed == true
    }

    /// Remember the user's request until the sensor state is known.
    /// Never restart a sensor that has already started or ended.
    func startSensor(sensorCode: String?, startDate: Date) {
        workQueue.async { [weak self] in
            guard let self = self, !self.released else { return }
            guard self.actStep == .none, !self.pendingActivation else {
                trace("activation is already in progress", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info)
                return
            }
            if self.commandStatus == 3 || self.activationHasStarted {
                trace("activation refused: this sensor has already started", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error)
                return
            }
            if self.commandStatus >= 4 {
                trace("activation refused — the sensor has ended (cmd=%{public}d) and cannot be started again", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error, self.commandStatus)
                return
            }
            guard self.lifetimeTransaction == nil, !self.lifetimeReadsBlocked, self.actStep == .none, !self.pendingActivation, !self.serverActivating, !self.activationRequested else {
                trace("activation already in progress — duplicate request ignored", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info)
                return
            }
            #if DEBUG
            let signedIn = self.lifetimeTestContext || OttaiCloudClient.isSignedIn
            #else
            let signedIn = OttaiCloudClient.isSignedIn
            #endif
            guard OttaiConstants.looksLikeMac(self.sensorId), signedIn,
                  let bluetoothID = self.deviceAddress, UUID(uuidString: bluetoothID) != nil else {
                trace("activation refused — signed-in account, Cloud ID and selected Bluetooth sensor are required", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error)
                return
            }
            #if DEBUG
            let account = self.lifetimeTestContext ? (self.lifetimeAccount ?? OttaiRegistry.accountContext()) : OttaiRegistry.accountContext()
            #else
            let account = OttaiRegistry.accountContext()
            #endif
            let savedPreparation = OttaiRegistry.loadPreparationCheckpoint(self.sensorId)
            guard !OttaiRegistry.hasPreparationCheckpoint(self.sensorId) || savedPreparation != nil else {
                OttaiRegistry.saveActivationStatus(self.sensorId, "The saved preparation checkpoint cannot be read. No activation intent was recorded."); return
            }
            if let savedPreparation, !savedPreparation.matches(sensorID: self.sensorId, bluetoothID: bluetoothID, account: account) {
                OttaiRegistry.saveActivationStatus(self.sensorId, "The unfinished preparation belongs to another account or Bluetooth sensor."); return
            }
            let saved = OttaiRegistry.loadActivationCheckpoint(self.sensorId)
            // Without a fresh status, preserve an uncertain sent command and only read it back.
            let intent: OttaiActivationAttempt
            if let saved, saved.commandSentAtMs > 0,
               saved.matches(sensorID: self.sensorId, bluetoothID: bluetoothID, account: account) {
                intent = saved
            } else {
                intent = OttaiActivationAttempt(sensorID: self.sensorId, bluetoothID: bluetoothID,
                    apiBase: account.apiBase, userID: account.userId, authorizedAtMs: self.nowMs())
            }
            guard !intent.confirmed, OttaiRegistry.saveActivationCheckpoint(intent) else {
                trace("activation refused — could not persist activation intent", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error)
                return
            }
            if account.apiBase != OttaiConstants.apiBaseSyai,
               self.authKeys == nil || account.apiBase == OttaiConstants.apiBase || savedPreparation?.factoryComplete == false {
                var preparation = savedPreparation ?? OttaiPreparationCheckpoint(sensorID: self.sensorId, bluetoothID: bluetoothID,
                    apiBase: account.apiBase, userID: account.userId, authorizedAtMs: self.nowMs())
                if self.authKeys != nil, savedPreparation == nil {
                    preparation.storedMaterials = true
                    let validFactory: Bool
                    if account.apiBase == OttaiConstants.apiBase { validFactory = (try? OttaiCNPreparation.preflight(materials: self.materials)) != nil }
                    else { validFactory = (try? OttaiGlobalActivation.preflight(materials: self.materials)) != nil }
                    preparation.materialsSaved = OttaiCloudClient.materialsAreComplete(self.materials) && validFactory
                } else if savedPreparation != nil, !preparation.factoryComplete {
                    // A new explicit retry refreshes incomplete factory metadata once.
                    // Automatic reconnect never invalidates prepared materials.
                    preparation.materialsSaved = false
                }
                guard OttaiRegistry.savePreparationCheckpoint(preparation) else {
                    OttaiRegistry.saveActivationStatus(self.sensorId, "Could not save the fresh sensor preparation intent."); return
                }
            }
            self.activationAccount = account
            self.serverActivateAttemptedAtMs = intent.commandSentAtMs
            self.activationCommandSentAtMs = intent.commandSentAtMs
            if self.effectiveActiveTimeMs() > 0 || self.activationCommandSentAtMs > 0 {
                trace("activation intent retained; a fresh inactive state is required before writes", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info)
            }
            self.activationRequested = true
            OttaiRegistry.setActivationAttempted(self.sensorId, true)
            // New sensor without keyA: an idle connected link starts the server activation now.
            if self.authKeys == nil {
                self.serverActivationStarts = 0
                if self.phase == .idle, self.connectedPeripheral?.state == .connected,
                   Self.requiredServices.isSubset(of: self.discoveredServices) {
                    self.onServicesDiscovered()
                } else {
                    trace("server-assisted activation deferred until the sensor is connected", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info)
                }
                return
            }
            if self.phase == .streaming, !self.sessionKeyHex.isEmpty, self.commandStatus >= 0 {
                self.requestActivationWithRediscovery()
            } else {
                trace("activation deferred — not authenticated or sensor state unknown (phase=%{public}@, cmd=%{public}d); will run after the next status read", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info, "\(self.phase)", self.commandStatus)
            }
        }
    }

    // MARK: - connect / disconnect

    /// Every connection starts from zero. The sensor gives a new login challenge
    /// each time, and the characteristic objects from the old connection are no
    /// longer valid. Without this reset, a reconnect after a Bluetooth drop kept
    /// the old session key and old handles: no new login, every write failed with
    /// "The handle is invalid", the sensor dropped the link again, and so on until
    /// the user switched the connection off and on by hand.
    func resetConnectionState() {
        interruptLifetimeOperation()
        lifetimeReadOwner = nil
        lifetimeReadsBlocked = false
        commandReadOutstanding = false
        delivery.invalidate()
        lastReportedSensorStartMs = 0
        connectionGeneration += 1
        connectionID = UUID().uuidString
        phase = .idle
        authStep = .none
        actStep = .none
        commandStatus = -1
        discoveredServices.removeAll()
        rediscoveredServices.removeAll()
        characteristics.removeAll()
        connectedPeripheral = nil
        deviceTimeBytes = []
        appKeyPair = nil
        sessionKeyHex = ""
        serverAuthHostBytes = nil
        serverAuthFlagBytes = nil
        serverActivating = false
        serverFrames = nil
        globalActivationWrites = []
        globalActivationWriteIndex = 0
        globalActivationFirmware = ""
        preparingCNFactory = false
        preparingSyaiFactory = false
        syaiLegacyFirmwareValidated = false
        preparationBindInFlight = false
        pendingActivation = false
        expectedRediscoveryCount = 0
        liveReadInFlight = false
        lastVerifyFailed = false
        historyGapPending = false
        livePollTimer?.cancel()
        livePollTimer = nil
        clearPendingHistoryRange()
    }

    override func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // This is queued BEFORE super starts service discovery. The discovery
        // callbacks go to the same queue, so the reset always runs first.
        workQueue.async { [weak self] in self?.resetConnectionState() }
        super.centralManager(central, didConnect: peripheral)
    }

    override func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.connectionGeneration += 1
            self.livePollTimer?.cancel()
            self.livePollTimer = nil
            self.interruptLifetimeOperation()
            self.connectionGeneration += 1
            self.connectedPeripheral = nil
            self.characteristics.removeAll()
            self.lifetimeReadOwner = nil
            self.commandReadOutstanding = false
            self.phase = .idle
            self.sessionKeyHex = ""
            self.clearPendingHistoryRange()
        }
        super.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }

    /// Drop the link, so the base class reconnects and the login starts again.
    /// Does nothing if a newer connection came in the meantime.
    private func recoverAndReconnect(_ reason: String) {
        let gen = connectionGeneration
        trace("%{public}@ — reconnecting", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, reason)
        workQueue.asyncAfter(deadline: .now() + Self.reauthDelay) { [weak self] in
            guard let self = self, self.connectionGeneration == gen else { return }
            self.disconnect()
        }
    }

    /// The sensor refused the auth write. When the device signature also failed, we
    /// are most likely talking to the wrong physical sensor (an old one with the same
    /// name). After two such logins, forget it and scan for another sensor.
    private func handleAuthWriteFailure() {
        if lastVerifyFailed { wrongSensorStrikes += 1 }
        if lastVerifyFailed && wrongSensorStrikes >= 2 {
            rotateAwayFromWrongSensor()
        } else {
            recoverAndReconnect("auth write failed")
        }
    }

    private func rotateAwayFromWrongSensor() {
        wrongSensorStrikes = 0
        serverAuthSignatureFailures = 0
        if let address = deviceAddress {
            rejectedIdentifiersLock.lock()
            rejectedPeripheralIdentifiers.insert(address)
            rejectedIdentifiersLock.unlock()
        }
        trace("login keeps failing with a bad device signature — this looks like the wrong sensor; forgetting it and scanning for another one", log: log, category: ConstantsLog.categoryCGMOttai, type: .error)
        disconnectAndForget()
        workQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            _ = self?.startScanning()
        }
    }

    override func shouldConnectToDiscoveredPeripheral(_ peripheral: CBPeripheral) -> Bool {
        rejectedIdentifiersLock.lock()
        let rejected = rejectedPeripheralIdentifiers.contains(peripheral.identifier.uuidString)
        rejectedIdentifiersLock.unlock()
        return !rejected
    }

    private func afterDelay(_ seconds: TimeInterval, _ block: @escaping () -> Void) {
        let gen = connectionGeneration
        workQueue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.connectionGeneration == gen else { return }
            block()
        }
    }

    // MARK: - service discovery

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Remember how many services the sensor has, so the re-discovery before an
        // activation waits for ALL of them (like Android's all-or-nothing discovery).
        let count = peripheral.services?.count ?? 0
        workQueue.async { [weak self] in
            guard let self = self, self.pendingActivation else { return }
            self.expectedRediscoveryCount = count
        }
        super.peripheral(peripheral, didDiscoverServices: error)
    }

    override func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        let serviceUUID = service.uuid
        workQueue.async { [weak self] in
            guard let self = self else { return }
            if let error = error {
                trace("in didDiscoverCharacteristicsFor, error %{public}@", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error, error.localizedDescription)
            }
            self.connectedPeripheral = peripheral
            for ch in chars { self.characteristics[ch.uuid.full128] = ch }
            if self.phase == .idle {
                self.discoveredServices.insert(serviceUUID)
                if Self.requiredServices.isSubset(of: self.discoveredServices) { self.onServicesDiscovered() }
            } else if self.pendingActivation {
                self.rediscoveredServices.insert(serviceUUID)
                if self.expectedRediscoveryCount > 0, self.rediscoveredServices.count >= self.expectedRediscoveryCount {
                    self.pendingActivation = false
                    trace("post-auth re-discovery complete — starting activation", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info)
                    if self.serverActivating {
                        if self.usesLegacySyaiServerActivation { self.startServerActivationWrites() }
                        else { self.readServerFirmware() }
                    } else { self.startActivationWrites() }
                }
            }
        }
    }

    private func char(_ uuidString: String) -> CBCharacteristic? {
        characteristics[CBUUID(string: uuidString).full128]
    }

    private func onServicesDiscovered() {
        authKeys = materials.authKeys
        switch ottaiAuthEntryMode(
            hasAuthKeys: authKeys != nil,
            pendingBind: OttaiRegistry.loadPendingBind(sensorId) > 0,
            bootstrapPending: OttaiRegistry.isV3CredentialBootstrapPending(sensorId),
            sessionAvailable: OttaiCloudClient.isSignedIn,
            activationRequested: activationRequested && activationContextIsCurrent()
        ) {
        case .storedMaterialAuth:
            phase = .enablingNotify
            // order: history, live, cgm-info
            for uuid in [OttaiConstants.charGlucoseHistory, OttaiConstants.charGlucoseLive, OttaiConstants.charCgmInfoNotify] {
                if let ch = char(uuid) { setNotifyValue(true, for: ch) }
            }
            afterDelay(0.6) { [weak self] in self?.startAuth() }
        case .awaitingBind:
            trace("sensor activated through the server; waiting for the bind", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
            startPendingBind()
        case .serverAssistedActivation:
            guard [OttaiConstants.apiBase, OttaiConstants.apiBaseGlobal, OttaiConstants.apiBaseSyai].contains(OttaiRegistry.loadApiBase()) else {
                giveUpServerActivation("This sensor account has no supported authentication and preparation flow.")
                return
            }
            serverActivationStarts += 1
            if serverActivationStarts > Self.maxServerActivationStarts {
                giveUpServerActivation("no success in \(Self.maxServerActivationStarts) connections")
                return
            }
            trace("starting server-assisted activation attempt=%{public}d/%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, serverActivationStarts, Self.maxServerActivationStarts)
            serverActivating = true
            startAuth()
        case .blocked:
            // No keys yet, or a new sensor waiting for Activate. Stay connected and do nothing.
            trace("no auth keys and no activation request — idle", log: log, category: ConstantsLog.categoryCGMOttai, type: .error)
        }
    }

    // MARK: - login (Auth V2 / V3)

    private func startAuth() {
        phase = .auth
        serverAuthHostBytes = nil
        serverAuthFlagBytes = nil
        authStep = .readDeviceTime
        readChar(OttaiConstants.charCurrentTime)
    }

    override func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.full128
        let value = [UInt8](characteristic.value ?? Data())
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentCallback(peripheral, characteristic) else { return }
            if let error = error {
                if uuid == OttaiConstants.charCommand { self.commandReadOutstanding = false }
                if self.lifetimeTransaction != nil,
                   uuid == OttaiConstants.charMaxActiveTime || uuid == OttaiConstants.charCommand {
                    self.failLifetimeOperation("The sensor lifetime/state read failed. Reconnect and read it again before retrying.")
                    return
                }
                if self.actStep == .globalFirmware || self.actStep == .globalCmdGate {
                    self.failActivation("Could not verify the sensor firmware and state. Reconnect before retrying activation.")
                    return
                }
                trace("read err %{public}@ %{public}@ phase=%{public}@", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error, characteristic.uuid.uuidString, error.localizedDescription, "\(self.phase)")
                // The maxActive read is only for display. Never let it break a stream.
                if uuid == OttaiConstants.charMaxActiveTime { self.lifetimeReadOwner = nil; self.lifetimeReadsBlocked = true; return }
                if self.actStep == .serverFirmware, uuid == OttaiConstants.charSoftwareVersion { self.readServerCmdGate(); return }
                if self.phase == .auth { self.recoverAndReconnect("auth read failed") }
                return
            }
            self.handleValue(uuid: uuid, value: value)
        }
    }

    private func handleValue(uuid: String, value: [UInt8]) {
        switch uuid {
        case OttaiConstants.charCurrentTime:
            deviceTimeBytes = value
            authStep = .readDeviceParam
            readChar(OttaiConstants.charAuthDeviceParam)
        case OttaiConstants.charAuthDeviceParam:
            lastAuthDevHex = OttaiCrypto.bytesToHex(value)
            parseDeviceAuthParam(value)
            authStep = .readDeviceSign
            readChar(OttaiConstants.charAuthSign)
        case OttaiConstants.charAuthSign:
            handleAuthSign(value)
        case OttaiConstants.charCgmInfoNotify:
            handleCgmInfo(value)
        case OttaiConstants.charGlucoseLive:
            // CoreBluetooth gives notifications and read answers the same way. A live
            // value that comes while no read is running must be a notification.
            let notification = !liveReadInFlight
            liveReadInFlight = false
            handleGlucosePayload(value, live: true, notification: notification)
        case OttaiConstants.charGlucoseHistory:
            handleGlucosePayload(value, live: false)
        case OttaiConstants.charCommand:
            commandReadOutstanding = false
            // Only a real command read confirms started/ended state. This is also
            // needed when a lifetime transaction consumes the reply below.
            OttaiRegistry.saveSensorStatus(sensorId, value.first.map { Int($0) } ?? -1)
            if let transaction = lifetimeTransaction {
                let status = value.first.map { Int($0) } ?? -1
                if transaction.mode != .activation, status != 3 {
                    commandStatus = status
                    failLifetimeOperation("The sensor stopped reporting an active state during the lifetime request. No activation was sent."); return
                }
                if transaction.mode == .activation, status >= 3 {
                    commandStatus = status
                    failLifetimeOperation("The sensor is no longer inactive. No activation was sent."); return
                }
            }
            if var transaction = lifetimeTransaction,
               transaction.stage == .freshStatus || transaction.stage == .finalStatus {
                guard lifetimeContextIsCurrent() else { failLifetimeOperation("The account, sensor or Bluetooth session changed."); return }
                let status = value.first.map { Int($0) } ?? -1
                commandStatus = status
                let effect = transaction.status(status)
                lifetimeTransaction = transaction
                runLifetimeEffect(effect)
                return
            }
            if actStep == .globalCmdGate {
                let status = value.first.map { Int($0) } ?? -1
                commandStatus = status
                guard !activationHasStarted, status >= 0, status < 3, activationContextIsCurrent() else {
                    failActivation("The sensor is not confirmed inactive. No factory parameters were written.")
                    return
                }
                if let preparation = OttaiRegistry.loadPreparationCheckpoint(sensorId), !preparation.materialsSaved,
                   preparation.bindAttempted || preparation.storedMaterials {
                    actStep = .none
                    prepareFreshSensorMaterials()
                } else { buildGlobalActivationWrites() }
            } else if actStep == .serverCmdGate {
                handleServerCmdGate(value.first.map { Int($0) } ?? -1)
            } else {
                handleCommandStatus(value.first.map { Int($0) } ?? -1)
            }
        case OttaiConstants.charSoftwareVersion:
            let raw = OttaiCloudClient.softwareRevision(value)
            trace("BLE firmware sensor=%{public}@ version=%{public}@ step=%{public}@",
                  log: log, category: ConstantsLog.categoryCGMOttai, type: .info,
                  sensorId, raw.isEmpty ? "missing" : raw, "\(actStep)")
            if actStep == .globalFirmware {
                if preparingSyaiFactory {
                    if OttaiPreparation.minor(raw) == nil, OttaiRegistry.loadPreparationCheckpoint(sensorId) == nil {
                        // Cached keys for an older Syai revision keep the existing local flow.
                        syaiLegacyFirmwareValidated = true
                        preparingSyaiFactory = false
                        actStep = .none
                        startActivationWrites()
                        return
                    }
                    guard saveSyaiPreparationFirmware(raw) else { return }
                    globalActivationFirmware = raw
                    actStep = .globalCmdGate
                    readChar(OttaiConstants.charCommand)
                    return
                }
                let candidate = preparingCNFactory ? OttaiGlobalContract.preparationBindVersion(raw) : OttaiGlobalActivation.bindFirmware(raw)
                guard activationContextIsCurrent(), let version = candidate,
                      !preparingCNFactory || OttaiCNPreparation.firmwareMinor(version) != nil else {
                    failActivation("The Bluetooth firmware version is missing or unsupported. No factory parameters were written.")
                    return
                }
                if var preparation = OttaiRegistry.loadPreparationCheckpoint(sensorId) {
                    if preparation.liveFirmware.isEmpty {
                        if preparation.storedMaterials, preparation.materialsSaved,
                           !OttaiGlobalContract.preparationVersionMatches(sensor: materials.deviceVersion, cloud: raw) {
                            failActivation("The cached factory materials do not match the live firmware. Retry preparation to refresh its metadata."); return
                        }
                        guard let live = OttaiGlobalContract.preparationBindVersion(raw) else {
                            failActivation("The live firmware revision is malformed. No factory parameters were written."); return
                        }
                        preparation.liveFirmware = live
                        guard OttaiRegistry.savePreparationCheckpoint(preparation) else {
                            failActivation("Could not checkpoint the live firmware. No factory parameters were written."); return
                        }
                    } else if !OttaiGlobalContract.preparationVersionMatches(sensor: preparation.liveFirmware, cloud: raw) {
                        failActivation("The live sensor firmware differs from its prepared materials. No factory parameters were written."); return
                    }
                }
                globalActivationFirmware = version
                // This is flushed with the command checkpoint before activation,
                // so a post-kill bind never falls back to stale cloud firmware.
                OttaiRegistry.saveLastValidatedDeviceVersion(sensorId: sensorId, version: version)
                actStep = .globalCmdGate
                readChar(OttaiConstants.charCommand)
            } else if actStep == .serverFirmware { handleServerFirmware(value) }
        case OttaiConstants.charMaxActiveTime:
            handleMaxActiveRead(value)
        default:
            break
        }
    }

    private func parseDeviceAuthParam(_ v: [UInt8]) {
        guard v.count >= 68 else { return }
        deviceParamIndex = Int(v[0])
        deviceParamTime = Array(v[1 ..< 4])
        devicePubX = Array(v[4 ..< 36])
        devicePubY = Array(v[36 ..< 68])
    }

    private func handleAuthSign(_ value: [UInt8]) {
        let authFlagHex = OttaiCrypto.bytesToHex(value)
        if serverActivating && authKeys == nil {
            guard usesLegacySyaiServerActivation || (deviceTimeBytes.count == 4 && lastAuthDevHex.count == 136 && value.count == 32) else {
                giveUpServerActivation("The fresh sensor authentication fields have invalid lengths."); return
            }
            requestCgmAuthVerify(authDevHex: lastAuthDevHex, authFlagHex: authFlagHex)
            return
        }
        let verified = verifyDeviceSign(value)
        if OttaiRegistry.loadPreparationCheckpoint(sensorId) != nil && !verified {
            rotateAwayFromWrongSensor()
            return
        }
        writeAppParam()
    }

    @discardableResult
    private func verifyDeviceSign(_ deviceSign: [UInt8]) -> Bool {
        guard let keys = authKeys, deviceParamIndex >= 0, deviceParamIndex < keys.count else { return false }
        let ok = OttaiBleAuth.verifyDeviceSign(
            deviceSign: deviceSign,
            authKeyHex: OttaiCrypto.bytesToHex(keys[deviceParamIndex]),
            macHex: OttaiCrypto.bytesToHex(macBytes),
            devPubX: devicePubX, devPubY: devicePubY, devTime: deviceParamTime)
        // The result is not reliable in the original app, so we only log it. But when
        // the login then also fails, a failed verify points to a wrong physical sensor.
        lastVerifyFailed = !ok
        trace("device sign verify=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, ok.description)
        return ok
    }

    private func writeAppParam() {
        if let host = serverAuthHostBytes, !host.isEmpty {
            authStep = .writeAppParam
            writeChar(OttaiConstants.charAuthAppParam, host)
            return
        }
        guard let keys = authKeys, !keys.isEmpty else {
            trace("cannot write auth parameter without stored auth keys", log: log, category: ConstantsLog.categoryCGMOttai, type: .error)
            return
        }
        let kp = OttaiBleAuth.generateKeyPair()
        appKeyPair = kp
        appTime3 = OttaiBleAuth.appTime3(deviceTimeBytes)
        appIndex = Int.random(in: 0 ..< keys.count)
        let param = OttaiBleAuth.appAuthParameter(selectedIndex: appIndex, time3: appTime3, pubX: kp.pubX, pubY: kp.pubY)
        authStep = .writeAppParam
        writeChar(OttaiConstants.charAuthAppParam, param)
    }

    override func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.full128
        workQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isCurrentCallback(peripheral, characteristic) else { return }
            if let error = error {
                if uuid == OttaiConstants.charMaxActiveTime, self.lifetimeTransaction != nil {
                    if self.lifetimeTransaction?.mode == .activation, (error as NSError).domain == CBATTErrorDomain, self.retryMaxActiveTime() { return }
                    self.failLifetimeOperation("The sensor refused the lifetime write: \(error.localizedDescription)")
                    return
                }
                trace("write err %{public}@ %{public}@ authStep=%{public}@ actStep=%{public}@", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error, characteristic.uuid.uuidString, error.localizedDescription, "\(self.authStep)", "\(self.actStep)")
                if self.actStep == .maxActive, uuid == OttaiConstants.charMaxActiveTime, self.retryMaxActiveTime() { return }
                if self.actStep.isServer {
                    self.failServerActivationWrite(error.localizedDescription)
                } else if self.actStep != .none {
                    self.failActivation("aborted after \(self.actStep) write error")
                } else if self.authStep == .writeAppParam || self.authStep == .writeAppSign {
                    self.handleAuthWriteFailure()
                } else if uuid == OttaiConstants.charHistoryRequest, self.activeHistoryEndExclusive > 0 {
                    // The sensor said no to this window (for example the start is past its
                    // last record). Treat it as an empty answer, so the chain goes on.
                    self.cancelHistoryWatchdog()
                    self.historyRetryCount = 0
                    self.advanceHistoryChunkChain()
                }
                return
            }
            self.handleWriteAck(uuid: uuid)
        }
    }

    private func handleWriteAck(uuid: String) {
        if uuid == OttaiConstants.charHistoryRequest { return }
        if authStep == .writeAppParam, uuid == OttaiConstants.charAuthAppParam {
            if let serverFlag = serverAuthFlagBytes, !serverFlag.isEmpty {
                authStep = .writeAppSign
                writeChar(OttaiConstants.charAuthSign, serverFlag)
                return
            }
            guard let keys = authKeys, let kp = appKeyPair else { return }
            let sign = OttaiBleAuth.authSignHex(authKeyHex: OttaiCrypto.bytesToHex(keys[appIndex]),
                                                macHex: OttaiCrypto.bytesToHex(macBytes),
                                                pubX: kp.pubX, pubY: kp.pubY, time3: appTime3)
            authStep = .writeAppSign
            writeChar(OttaiConstants.charAuthSign, sign)
            return
        }
        if authStep == .writeAppSign, uuid == OttaiConstants.charAuthSign {
            if serverAuthFlagBytes != nil {
                serverAuthHostBytes = nil
                serverAuthFlagBytes = nil
                authStep = .done
                sessionKeyHex = ""
                if usesLegacySyaiServerActivation {
                    readServerFirmware()
                } else {
                    trace("server login answer written; waiting for service rebinding before reading the fresh sensor state", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
                    afterDelay(2.5) { [weak self] in self?.requestPreparationRediscovery() }
                }
                return
            }
            deriveSession()
            authStep = .done
            if sessionKeyHex.isEmpty {
                recoverAndReconnect("auth complete; session=FAILED — no session key derived")
                return
            }
            phase = .streaming
            reportSensorSessionIfNeeded()
            lastVerifyFailed = false
            wrongSensorStrikes = 0
            rejectedIdentifiersLock.lock()
            rejectedPeripheralIdentifiers.removeAll()
            rejectedIdentifiersLock.unlock()
            trace("auth complete; session ok", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
            OttaiRegistry.ensureSensorRecord(sensorId: sensorId, address: deviceAddress ?? "", displayName: OttaiConstants.defaultDisplayName)
            // The command byte tells the true state: 0..2 = activate, 3 = stream,
            // 4 or more = the sensor has ended.
            // Fresh status comes before the durable preparation firmware gate.
            readChar(OttaiConstants.charCommand)
            return
        }
        if uuid == OttaiConstants.charMaxActiveTime, var transaction = lifetimeTransaction {
            guard lifetimeContextIsCurrent() else { failLifetimeOperation("The account, sensor or Bluetooth session changed."); return }
            let effect = transaction.acknowledged()
            lifetimeTransaction = transaction
            runLifetimeEffect(effect)
            return
        }
        if actStep == .globalM8 {
            advanceGlobalActivation(acknowledgedUUID: uuid)
        } else if actStep.isServer {
            advanceServerActivation(acknowledgedUUID: uuid)
        } else if actStep != .none {
            advanceActivation(acknowledgedUUID: uuid)
        }
    }

    private func deriveSession() {
        guard let kp = appKeyPair else { return }
        sessionKeyHex = OttaiBleAuth.deriveSessionKey(devPubX: devicePubX, devPubY: devicePubY, ourPrivate: kp.privateKey) ?? ""
        trace("session key derived len=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, "\(sessionKeyHex.count)")
    }

    // MARK: - server-assisted activation (new Syai sensors, as in SyaiKit)
    //
    // The server checks the sensor identity. BindV3 then returns keyA.
    // A new local login writes factory settings and sets the sensor lifetime.

    private func requestCgmAuthVerify(authDevHex: String, authFlagHex: String) {
        if authFlagHex.allSatisfy({ $0 == "0" }) {
            recoverAndReconnect("sensor sent an empty auth challenge")
            return
        }
        let mac = OttaiCrypto.bytesToHex(macBytes)
        let gen = connectionGeneration
        guard let account = activationAccount, activationContextIsCurrent() else {
            giveUpServerActivation("activation account or selected sensor changed")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard OttaiRegistry.isCurrent(account) else { return }
            let result = OttaiCloudClient.perform {
                OttaiCloudClient.cgmAuthVerify(mac: mac, authDevHex: authDevHex, authFlagHex: authFlagHex)
            }
            let material = result.value
            let failure = result.failure
            self?.workQueue.async { [weak self] in
                guard let self = self, self.connectionGeneration == gen, self.phase == .auth,
                      OttaiRegistry.isCurrent(account), self.activationContextIsCurrent() else { return }
                guard let material else {
                    if let code = failure?.code, !code.isEmpty {
                        if code == "DEVICE_AUTH_SIGN_ERROR" { self.serverAuthSignatureFailures += 1 }
                        switch ottaiServerAuthRecovery(code: code,
                                                       signatureFailures: self.serverAuthSignatureFailures,
                                                       activateSent: self.activationCommandSentAtMs > 0) {
                        case .retryConnection:
                            self.recoverAndReconnect("cgmAuth/verify rejected the device signature; retrying with a fresh challenge")
                        case .scanNextSensor:
                            // Keep the user's activation request. The next discovered
                            // device must pass server verification before any writes.
                            self.rotateAwayFromWrongSensor()
                        case .stop:
                            self.giveUpServerActivation("cgmAuth/verify refused: \(failure?.text ?? code)")
                        }
                    } else {
                        self.recoverAndReconnect("cgmAuth/verify gave no answer: \(failure?.text ?? "unknown")")
                    }
                    return
                }
                self.applyServerAuthentication(material)

            }
        }
    }

    private func applyServerAuthentication(_ material: OttaiCloudClient.V3AuthMaterial) {
        guard activationContextIsCurrent(),
              let host = try? OttaiCrypto.hexToBytesStrict(material.authHost),
              let flag = try? OttaiCrypto.hexToBytesStrict(material.authFlag),
              usesLegacySyaiServerActivation ? (!host.isEmpty && !flag.isEmpty) : (host.count == 68 && flag.count == 32) else {
            giveUpServerActivation("The server authentication fields are malformed. No activation frames were sent."); return
        }
        if usesLegacySyaiServerActivation {
            // V3 Syai first returns authentication only; its live firmware selects
            // local factory preparation. Retain opaque frames for older revisions.
            if material.hasActivationFrames,
               let coefficient = try? OttaiCrypto.hexToBytesStrict(material.cf), !coefficient.isEmpty,
               let duration = try? OttaiCrypto.hexToBytesStrict(material.d), !duration.isEmpty,
               let activate = try? OttaiCrypto.hexToBytesStrict(material.c), !activate.isEmpty {
                serverFrames = (coefficient, duration, activate)
            } else {
                guard host.count == 68, flag.count == 32 else {
                    giveUpServerActivation("The Syai V3 authentication fields are malformed."); return
                }
                serverFrames = nil
            }
        } else {
            // CN/Global use cloud authentication only, then derive a locally owned
            // session for factory setup and mandatory 30-day parameter read-back.
            serverFrames = nil
        }
        serverAuthSignatureFailures = 0
        serverAuthHostBytes = host
        serverAuthFlagBytes = flag
        writeAppParam()
    }

    private func requestPreparationRediscovery() {
        guard activationContextIsCurrent(), !released else { return }
        pendingActivation = true
        rediscoveredServices.removeAll()
        expectedRediscoveryCount = 0
        #if DEBUG
        if let discovery = preparationTestRediscover { discovery(); return }
        #endif
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            giveUpServerActivation("Reconnect to finish the fresh sensor preparation. No activation was sent."); return
        }
        peripheral.discoverServices(nil)
        afterDelay(10) { [weak self] in
            guard let self, self.pendingActivation, self.serverActivating else { return }
            self.giveUpServerActivation("Service rebinding timed out after server authentication. No preparation bind or activation was sent.")
        }
    }

    private func readServerFirmware() {
        actStep = .serverFirmware
        if !charIsReadable(OttaiConstants.charSoftwareVersion) {
            if usesLegacySyaiServerActivation { readServerCmdGate(); return }
            giveUpServerActivation("The live firmware characteristic is missing. No factory parameters were written.")
        } else {
            readChar(OttaiConstants.charSoftwareVersion)
            afterDelay(10) { [weak self] in
                guard let self, self.actStep == .serverFirmware || self.actStep == .serverCmdGate else { return }
                self.giveUpServerActivation("The fresh sensor firmware/state read timed out. No preparation bind or activation was sent.")
            }
        }
    }

    private func handleServerFirmware(_ value: [UInt8]) {
        let firmware = OttaiCloudClient.softwareRevision(value)
        if activationAccount?.apiBase == OttaiConstants.apiBaseSyai {
            if OttaiPreparation.minor(firmware) == nil {
                guard usesLegacySyaiServerActivation, serverFrames != nil else {
                    giveUpServerActivation("Syai firmware cannot be verified and no legacy activation frames are available."); return
                }
                syaiLegacyFirmwareValidated = true
                if OttaiRegistry.loadLastValidatedDeviceVersion(sensorId: sensorId) == nil {
                    OttaiRegistry.saveLastValidatedDeviceVersion(sensorId: sensorId,
                        version: OttaiCloudClient.deviceVersion(fromFirmware: firmware))
                }
                readServerCmdGate()
                return
            }
            guard saveSyaiPreparationFirmware(firmware) else { return }
            preparingSyaiFactory = true
            readServerCmdGate()
            return
        }
        guard let version = OttaiGlobalContract.preparationBindVersion(firmware),
              (activationAccount?.apiBase == OttaiConstants.apiBase ? OttaiCNPreparation.firmwareMinor(version) : OttaiGlobalActivation.firmwareMinor(version)) != nil,
              var checkpoint = OttaiRegistry.loadPreparationCheckpoint(sensorId),
              let account = activationAccount,
              checkpoint.matches(sensorID: sensorId, bluetoothID: deviceAddress ?? "", account: account) else {
            giveUpServerActivation("The live firmware or preparation identity cannot be verified. No factory parameters were written."); return
        }
        if checkpoint.bindAttempted, !checkpoint.liveFirmware.isEmpty,
           !OttaiGlobalContract.preparationVersionMatches(sensor: checkpoint.liveFirmware, cloud: version) {
            giveUpServerActivation("The sensor firmware changed during preparation. No bind or activation was sent."); return
        }
        checkpoint.liveFirmware = version
        guard OttaiRegistry.savePreparationCheckpoint(checkpoint) else {
            giveUpServerActivation("Could not persist the live firmware before preparation."); return
        }
        OttaiRegistry.saveLastValidatedDeviceVersion(sensorId: sensorId, version: version)
        readServerCmdGate()
    }

    /// The same account/Bluetooth-bound checkpoint protects both modern Syai and
    /// CN/Global. A cloud bind timestamp is never adopted as physical activation.
    private func saveSyaiPreparationFirmware(_ firmware: String) -> Bool {
        guard activationContextIsCurrent(), let account = activationAccount,
              let bluetoothID = deviceAddress, OttaiPreparation.minor(firmware) != nil else {
            failActivation("The Syai preparation identity or firmware is missing."); return false
        }
        let saved = OttaiRegistry.loadPreparationCheckpoint(sensorId)
        guard !OttaiRegistry.hasPreparationCheckpoint(sensorId) || saved != nil else {
            failActivation("The saved Syai preparation checkpoint is unreadable."); return false
        }
        var checkpoint = saved ?? OttaiPreparationCheckpoint(sensorID: sensorId, bluetoothID: bluetoothID,
            apiBase: account.apiBase, userID: account.userId, authorizedAtMs: nowMs())
        guard checkpoint.matches(sensorID: sensorId, bluetoothID: bluetoothID, account: account),
              checkpoint.liveFirmware.isEmpty || OttaiPreparation.versionMatches(checkpoint.liveFirmware, firmware) else {
            failActivation("Syai preparation belongs to another sensor, account or firmware."); return false
        }
        checkpoint.liveFirmware = firmware
        if saved == nil, authKeys != nil {
            checkpoint.storedMaterials = true
            checkpoint.materialsSaved = syaiFactoryMaterialsReady(materials)
                && OttaiPreparation.versionMatches(firmware, materials.deviceVersion)
        }
        guard OttaiRegistry.savePreparationCheckpoint(checkpoint) else {
            failActivation("Could not save Syai factory preparation intent."); return false
        }
        OttaiRegistry.saveLastValidatedDeviceVersion(sensorId: sensorId, version: firmware)
        return true
    }

    private func syaiFactoryMaterialsReady(_ candidate: OttaiRegistry.DeviceMaterials) -> Bool {
        guard OttaiCloudClient.materialsAreComplete(candidate),
              let minor = OttaiPreparation.minor(candidate.deviceVersion) else { return false }
        if minor >= 6 {
            let fields = candidate.coefficient.split(separator: ",", omittingEmptySubsequences: false)
            let values = fields.compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard values.count == fields.count, (1...255).contains(values.count),
                  values.allSatisfy({ $0.isFinite }) else { return false }
        }
        if minor >= 8 {
            guard let k = candidate.calibrationK, let b = candidate.calibrationB, k.isFinite, b.isFinite else { return false }
        }
        return true
    }

    private func prepareFreshSensorMaterials() {
        guard !preparationBindInFlight, activationContextIsCurrent(), commandStatus >= 0, commandStatus < 3,
              let account = activationAccount,
              var checkpoint = OttaiRegistry.loadPreparationCheckpoint(sensorId),
              checkpoint.matches(sensorID: sensorId, bluetoothID: deviceAddress ?? "", account: account),
              !checkpoint.liveFirmware.isEmpty else {
            giveUpServerActivation("The fresh sensor preparation is not verified. Reconnect and read its state before retrying."); return
        }
        let wasAttempted = checkpoint.bindAttempted
        preparationBindInFlight = true
        let generation = connectionGeneration, id = sensorId, firmware = checkpoint.liveFirmware
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stillAuthorized: () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.workQueue.sync {
                    !self.released && self.connectionGeneration == generation && self.activationContextIsCurrent()
                }
            }
            let willBind: () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.workQueue.sync {
                    guard !self.released, self.connectionGeneration == generation, self.activationContextIsCurrent(),
                          var current = OttaiRegistry.loadPreparationCheckpoint(id), !current.bindAttempted,
                          current.matches(sensorID: id, bluetoothID: self.deviceAddress ?? "", account: account) else { return false }
                    current.bindAttempted = true
                    return OttaiRegistry.savePreparationCheckpoint(current)
                }
            }
            var bindRejected = false
            func fetch() -> OttaiRegistry.DeviceMaterials? {
                if account.apiBase == OttaiConstants.apiBaseSyai {
                    let result = OttaiCloudClient.prepareMaterials(mac: id, version: firmware, allowBind: !wasAttempted,
                        requestedContext: account, stillAuthorized: stillAuthorized, willBind: willBind)
                    bindRejected = result.bindRejected
                    OttaiCloudClient.lastFailure = result.operation.failure
                    return result.operation.value
                }
                return OttaiCloudClient.prepareActivationMaterials(mac: id, liveFirmware: firmware,
                    requestedContext: account, bindAlreadyAttempted: wasAttempted,
                    stillAuthorized: stillAuthorized, willBind: willBind)
            }
            let prepared: OttaiRegistry.DeviceMaterials?
            #if DEBUG
            if let provider = self?.preparationTestMaterialFetch { prepared = provider(wasAttempted, willBind) }
            else { prepared = fetch() }
            #else
            prepared = fetch()
            #endif
            let failure = OttaiCloudClient.lastError
            self?.workQueue.async { [weak self] in
                guard let self, self.connectionGeneration == generation, self.activationContextIsCurrent(),
                      self.preparationAccountIsCurrent(account) else { return }
                self.preparationBindInFlight = false
                if bindRejected, var rejected = OttaiRegistry.loadPreparationCheckpoint(id) {
                    // An explicit business refusal proves that this POST did not bind.
                    // Unknown network results keep bindAttempted and only permit GET.
                    rejected.bindAttempted = false
                    guard OttaiRegistry.savePreparationCheckpoint(rejected) else {
                        self.giveUpServerActivation("Could not save the refused Syai binding result."); return
                    }
                }
                guard var prepared, prepared.authKeys != nil, OttaiCloudClient.materialsAreComplete(prepared),
                      var checkpoint = OttaiRegistry.loadPreparationCheckpoint(id) else {
                    self.giveUpServerActivation(failure.isEmpty ? "Preparation bind is unresolved. Retry reads its result without sending another bind or activation." : failure); return
                }
                prepared.activeTimeMs = 0
                do {
                    if account.apiBase == OttaiConstants.apiBaseSyai {
                        guard self.syaiFactoryMaterialsReady(prepared) else { throw OttaiPreparation.Failure.coefficients }
                    } else if account.apiBase == OttaiConstants.apiBase { try OttaiCNPreparation.preflight(materials: prepared) }
                    else { try OttaiGlobalActivation.preflight(materials: prepared) }
                }
                catch { self.giveUpServerActivation(error.localizedDescription); return }
                guard OttaiRegistry.saveMaterials(sensorId: id, prepared) else {
                    self.giveUpServerActivation("Could not save prepared sensor materials. No activation was sent."); return
                }
                checkpoint.bindAttempted = true
                checkpoint.materialsSaved = true
                guard OttaiRegistry.savePreparationCheckpoint(checkpoint) else {
                    self.giveUpServerActivation("Could not checkpoint prepared materials. No activation was sent."); return
                }
                self.materials = prepared
                self.authKeys = prepared.authKeys
                self.serverActivating = false
                self.serverFrames = nil
                self.actStep = .none
                self.activationRequested = true
                // New local ECDH derives a key owned by xDrip. It must happen before
                // factory parameters, duration read-back and physical activation.
                #if DEBUG
                if let reauth = self.preparationTestLocalReauth { reauth(); return }
                #endif
                self.disconnect()
            }
        }
    }

    private func preparationAccountIsCurrent(_ account: OttaiAccountContext) -> Bool {
        #if DEBUG
        if lifetimeTestContext { return account == activationAccount }
        #endif
        return OttaiRegistry.isCurrent(account)
    }

    private func readServerCmdGate() {
        actStep = .serverCmdGate
        readChar(OttaiConstants.charCommand)
    }

    /// Nothing is written to a sensor with cmd 3 or more.
    private func handleServerCmdGate(_ status: Int) {
        commandStatus = status
        OttaiRegistry.saveSensorStatus(sensorId, status)
        actStep = .none
        trace("server activation: cmd gate status=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, status)
        guard activationContextIsCurrent() else {
            giveUpServerActivation("activation account or selected sensor changed")
            return
        }
        guard status < 0 || status >= 3 || !activationHasStarted else {
            giveUpServerActivation("This sensor was already confirmed started; no activation parameters were sent.")
            return
        }
        let checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId)
        switch OttaiActivationGate.decide(commandStatus: status, commandSentAtMs: serverActivateAttemptedAtMs,
                                          commandFromCurrentConnection: checkpoint?.commandConnectionID == connectionID) {
        case .readStatus:
            recoverAndReconnect("server activation: empty cmd read")
        case .bind(let startMs):
            serverActivationLanded(atMs: startMs)
        case .alreadyActive:
            giveUpServerActivation("sensor already active; fetch its existing materials — activation time is not known")
        case .ended:
            OttaiRegistry.clearActivationCheckpoint(sensorId)
            giveUpServerActivation("the sensor has ended (cmd=\(status))")
        case .confirmOnly:
            guard activationConfirmAttempt < Self.postActivationConfirmMaxAttempts else {
                giveUpServerActivation("activation is not confirmed; reconnect and check the sensor before retrying")
                return
            }
            activationConfirmAttempt += 1
            afterDelay(Self.postActivationConfirmDelay) { [weak self] in self?.readServerCmdGate() }
        case .retryConfirmedInactive:
            guard clearCommandAfterFreshInactiveRead() else {
                giveUpServerActivation("could not checkpoint inactive sensor readback")
                return
            }
            requestActivationWithRediscovery()
        case .writeFrames:
            if usesLegacySyaiServerActivation { requestActivationWithRediscovery() }
            else { prepareFreshSensorMaterials() }
        }
    }

    private func startServerActivationWrites() {
        guard usesLegacySyaiServerActivation else {
            giveUpServerActivation("Opaque activation frames are not used for CN/Global preparation."); return
        }
        guard !activationHasStarted, activationContextIsCurrent(), commandStatus >= 0, commandStatus < 3,
              serverActivateAttemptedAtMs == 0 else {
            readServerCmdGate()
            return
        }
        guard let frames = serverFrames else {
            giveUpServerActivation("the activation frames are gone")
            return
        }
        trace("server activation: writing the frames", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
        writeServerStep(.serverCoefficient, OttaiConstants.charDestructive, frames.coefficient)
    }

    /// Order as in the official app: coefficient -> duration -> RTC(0) -> activate.
    private func advanceServerActivation(acknowledgedUUID: String) {
        guard let frames = serverFrames else { return }
        let expected: OttaiServerActivationWrite?
        switch actStep {
        case .serverCoefficient: expected = .coefficient
        case .serverDuration: expected = .duration
        case .serverRtc: expected = .rtc
        case .serverActivate: expected = .activate
        default: expected = nil
        }
        guard let expected, expected.characteristic.caseInsensitiveCompare(acknowledgedUUID) == .orderedSame,
              activationContextIsCurrent() else { return }
        switch actStep {
        case .serverCoefficient:
            writeServerStep(.serverDuration, OttaiConstants.charMaxActiveTime, frames.duration)
        case .serverDuration:
            writeServerStep(.serverRtc, OttaiConstants.charCurrentTime, [0, 0, 0, 0])
        case .serverRtc:
            // Saved before the answer: a dropped link may never report this write.
            guard persistActivationCommandAttempt() else {
                giveUpServerActivation("could not persist activation command checkpoint")
                return
            }
            writeServerStep(.serverActivate, OttaiConstants.charCommand, frames.activate)
        case .serverActivate:
            // GATT ACK is not activation success. Confirm the sensor's command byte.
            activationConfirmAttempt = 0
            readServerCmdGate()
        default:
            break
        }
    }

    private func writeServerStep(_ step: ActStep, _ characteristic: String, _ value: [UInt8]) {
        guard activationContextIsCurrent() else {
            giveUpServerActivation("activation account or selected sensor changed")
            return
        }
        actStep = step
        if !writeChar(characteristic, value) { failServerActivationWrite("characteristic is missing") }
    }

    /// Usually the link dropped. The cmd gate on the next link tells if the activate landed.
    private func failServerActivationWrite(_ reason: String) {
        trace("server activation write failed at %{public}@: %{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, "\(actStep)", reason)
        let step = actStep
        actStep = .none
        pendingActivation = false
        if serverActivationStarts >= Self.maxServerActivationStarts {
            giveUpServerActivation("write failed at \(step) on the last try")
        } else {
            recoverAndReconnect("server activation interrupted")
        }
    }

    private func serverActivationLanded(atMs startMs: Int64) {
        guard commandStatus == 3, activationContextIsCurrent(),
              var checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId),
              checkpoint.commandSentAtMs == startMs else {
            giveUpServerActivation("activation was not confirmed for this sensor")
            return
        }
        checkpoint.confirmed = true
        guard OttaiRegistry.saveActivationCheckpoint(checkpoint) else {
            giveUpServerActivation("could not persist confirmed activation")
            return
        }
        OttaiRegistry.savePendingBind(sensorId, activatedAtMs: startMs)
        if materials.activeTimeMs <= 0 { setProvisionalActiveTime(startMs, "server-activation") }
        trace("sensor activated through the server; binding", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
        endServerActivation()
        #if DEBUG
        if let pending = serverActivationTestPendingBind { pending(); return }
        #endif
        startPendingBind()
    }

    private func giveUpServerActivation(_ reason: String) {
        trace("server-assisted activation failed: %{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, reason)
        OttaiRegistry.saveActivationStatus(sensorId, reason)
        // An uncertain write stays in its own checkpoint. Only cmd=3 permits cloud bind.
        endServerActivation()
    }

    private func endServerActivation() {
        OttaiRegistry.setActivationAttempted(sensorId, false)
        activationRequested = false
        serverActivating = false
        serverFrames = nil
        serverActivationStarts = 0
        serverActivateAttemptedAtMs = 0
        serverAuthSignatureFailures = 0
        actStep = .none
        pendingActivation = false
        disconnect()
    }

    /// Tried on every connection, and again after a minute when the network failed.
    private func startPendingBind() {
        let id = sensorId
        let activatedAtMs = OttaiRegistry.loadPendingBind(id)
        let globalBind = activationAccount?.apiBase == OttaiConstants.apiBaseGlobal
            && OttaiRegistry.loadSessionProfile() == .globalPhone
        guard !released, activatedAtMs > 0, authKeys == nil || globalBind, !pendingBindInFlight else { return }
        guard let account = activationAccount, activationContextIsCurrent(),
              OttaiRegistry.loadActivationCheckpoint(id)?.confirmed == true else {
            trace("bind deferred — confirmed activation and original account required", log: log, category: ConstantsLog.categoryCGMOttai, type: .error)
            return
        }
        pendingBindInFlight = true
        let version = OttaiCloudClient.serverActivationBindVersion(id)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OttaiCloudClient.perform {
                version.isEmpty || !OttaiRegistry.isCurrent(account) ? nil
                    : OttaiCloudClient.bindAfterServerActivation(mac: id, deviceVersion: version,
                        activatedAtMs: activatedAtMs, requestedContext: account)
            }
            let mats = result.value
            let failure = result.failure
            self?.workQueue.async { [weak self] in
                guard let self = self, !self.released else { return }
                self.pendingBindInFlight = false
                guard OttaiRegistry.isCurrent(account), self.activationContextIsCurrent() else { return }
                guard let mats = mats, OttaiCloudClient.materialsAreComplete(mats), OttaiRegistry.saveMaterials(sensorId: id, mats) else {
                    OttaiRegistry.saveActivationStatus(id, failure?.requiresSignIn == true
                        ? "Sensor started. Sign in again in xDrip and fetch its materials; do not activate it again."
                        : "Sensor started. Account linking is pending; fetch its materials again without reactivating.")
                    trace("bind after server activation failed: %{public}@", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .error,
                          version.isEmpty ? "no deviceVersion" : (failure?.text ?? "unknown"))
                    // A server code (e.g. another sensor still bound) needs the user.
                    if !version.isEmpty, (failure?.code ?? "").isEmpty {
                        self.workQueue.asyncAfter(deadline: .now() + Self.pendingBindRetryDelay) { [weak self] in self?.startPendingBind() }
                    }
                    return
                }
                OttaiRegistry.clearPendingBind(id)
                OttaiRegistry.clearActivationCheckpoint(id)
                OttaiRegistry.saveActivationStatus(id, nil)
                self.materials = OttaiRegistry.loadMaterials(sensorId: id)
                self.authKeys = self.materials.authKeys
                trace("sensor bound, keys saved; reconnecting", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info)
                self.disconnect()
            }
        }
    }

    // MARK: - command byte

    private func handleCommandStatus(_ status: Int) {
        let previous = commandStatus
        commandStatus = status
        OttaiRegistry.saveSensorStatus(sensorId, status)
        trace("cmd/activation status=%{public}d (official: 3=activated, <3=needs activation)", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, status)
        if status < 0 { return }
        if OttaiConstants.commandNeedsActivation(status) {
            livePollTimer?.cancel(); livePollTimer = nil
            guard !activationHasStarted else {
                trace("activation blocked: this sensor was already confirmed started", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
                return
            }
            if activationCommandSentAtMs > 0, activationContextIsCurrent() {
                if OttaiRegistry.loadActivationCheckpoint(sensorId)?.commandConnectionID == connectionID {
                    // A duplicate Activate tap or a delayed ACK must not reset/replay the command.
                    return
                }
                guard clearCommandAfterFreshInactiveRead() else { return }
            }
            // activationRequested is only in memory. If this object is destroyed and created
            // again during a retry (the app came to the foreground, or a reconnect came in
            // between), the flag is lost while the user's request is not finished. The saved
            // flag "activation was requested for this sensor" survives that, so a new object
            // still finishes the job instead of waiting for activation forever.
            let explicitlyRequested = activationRequested && activationContextIsCurrent()
            if OttaiConstants.shouldStartActivation(commandStatus: status, explicitlyRequested: explicitlyRequested),
               actStep == .none, !pendingActivation {
                activationRequested = false
                trace("sensor command status=%{public}d and user requested activation; starting activation sequence", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, status)
                afterDelay(0.25) { [weak self] in self?.requestActivationWithRediscovery() }
            } else {
                trace("sensor needs activation status=%{public}d; awaiting explicit user action", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, status)
            }
            return
        }
        if status == 3 {
            if let checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId), activationContextIsCurrent(),
               checkpoint.commandSentAtMs > 0, authKeys != nil {
                if materials.activeTimeMs <= 0 { setProvisionalActiveTime(checkpoint.commandSentAtMs, "activation-confirmed") }
                OttaiRegistry.setActivationAttempted(sensorId, false)
                activationRequested = false
                if var preparation = OttaiRegistry.loadPreparationCheckpoint(sensorId), preparation.materialsSaved,
                   preparation.factoryComplete, let account = activationAccount,
                   preparation.matches(sensorID: sensorId, bluetoothID: deviceAddress ?? "", account: account) {
                    preparation.confirmedStartMs = checkpoint.commandSentAtMs
                    guard OttaiRegistry.savePreparationCheckpoint(preparation) else {
                        failActivation("The activation landed but its physical start checkpoint could not be saved. Read its state again; do not reactivate."); return
                    }
                    materials.activeTimeMs = checkpoint.commandSentAtMs
                    OttaiRegistry.saveActiveTimeMs(sensorId, checkpoint.commandSentAtMs)
                    OttaiRegistry.clearActivationCheckpoint(sensorId)
                    OttaiRegistry.saveActivationStatus(sensorId, nil)
                } else if activationAccount?.apiBase == OttaiConstants.apiBaseGlobal,
                   OttaiRegistry.loadSessionProfile() == .globalPhone {
                    var confirmed = checkpoint
                    confirmed.confirmed = true
                    if OttaiRegistry.saveActivationCheckpoint(confirmed) {
                        OttaiRegistry.savePendingBind(sensorId, activatedAtMs: checkpoint.commandSentAtMs)
                        startPendingBind()
                    }
                } else {
                    OttaiRegistry.clearActivationCheckpoint(sensorId)
                }
            }
            actStep = .none
            pendingActivation = false
            activationRequested = false
            globalActivationWrites.removeAll()
            // activationCommandSentAtMs is kept on purpose (same as the Kotlin): it is the
            // warmup anchor for a sensor we just started, until the real start is confirmed.
            if previous >= 4 { trace("ended-sensor recovery accepted; normal streaming restored", log: log, category: ConstantsLog.categoryCGMOttai, type: .info) }
            if previous != 3 { startStreamingAfterCommandStatus() }
            return
        }
        // 4 or more = the sensor has ended. We do not try to restart it: the sensor refused
        // every restart in the logs we have (the lifetime write always fails). We only read
        // the live buffer once, to learn the last dataNo, and fetch the history up to it. No
        // glucose is shown from this read. The user needs a new sensor.
        livePollTimer?.cancel(); livePollTimer = nil
        actStep = .none
        pendingActivation = false
        activationRequested = false
        trace("sensor ended cmd=%{public}d; no lifetime write will be attempted automatically", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, status)
        afterDelay(0.5) { [weak self] in
            guard let self = self, self.commandStatus >= 4 else { return }
            self.readLiveGlucose("ended-history-index")
        }
    }

    private func startStreamingAfterCommandStatus() {
        afterDelay(0.25) { [weak self] in self?.readChar(OttaiConstants.charCgmInfoNotify) }
        afterDelay(0.7) { [weak self] in
            self?.readLiveGlucose("command-status-3")
            self?.scheduleLivePoll()
        }
        // Read once on entering streaming, including after our own activation. A write
        // acknowledgement is not a read-back or evidence of actual usable lifetime.
        afterDelay(1.2) { [weak self] in self?.readLifetimeForDisplay() }
        // History backfill that does not wait for the first live reading.
        afterDelay(Self.initialHistoryDelay) { [weak self] in self?.runInitialHistoryBackfill() }
    }

    /// The first history backfill. Only runs if the live path did not do it already.
    private func runInitialHistoryBackfill() {
        guard phase == .streaming, !sessionKeyHex.isEmpty, commandStatus == 3 else { return }
        guard !initialHistoryRequested, !initialFlushDone else { return }
        let sensorAgeMs = warmupAnchorMs() > 0 ? nowMs() - warmupAnchorMs() : -1
        if sensorAgeMs >= 0 && sensorAgeMs < Self.initialHistoryMinSensorAgeMs {
            let wait = Double(Self.initialHistoryMinSensorAgeMs - sensorAgeMs) / 1000.0
            trace("initial history backfill deferred %{public}ds — sensor is %{public}ds old", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, Int(wait), Int(sensorAgeMs / 1000))
            afterDelay(wait) { [weak self] in self?.runInitialHistoryBackfill() }
            return
        }
        guard lastDataNo > 0 else {
            readLiveGlucose("initial-history-probe")
            return
        }
        // Without a live reading we only know the last record we saw. Ask for the part
        // of it xDrip never got; the live path asks for anything newer later.
        guard let range = Self.startupBackfillRange(liveDataNo: lastDataNo + 1, lastDataNo: lastDataNo, deliveredDataNo: deliveredDataNo) else { return }
        if requestHistoryRange("initial", start: range.start, count: range.count) { initialHistoryRequested = true }
    }

    // MARK: - live and history packets

    private func handleGlucosePayload(_ cipher: [UInt8], live: Bool, notification: Bool = false) {
        if sessionKeyHex.isEmpty { return }
        if live && commandStatus >= 4 {
            handleEndedLiveBuffer(cipher)
            return
        }
        let receivedAtMs = nowMs()
        let kind = live ? "live" : "history"
        guard let payload = OttaiCrypto.decryptPayload(cipher, sessionKeyHex: sessionKeyHex) else {
            trace("%{public}@ decrypt failed len=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, kind, cipher.count)
            return
        }
        let widthBeforeFrame = learnedRecordSize
        learnRecordSize(payload)
        let records = OttaiParser.frameRecords(payload, deviceVersion: materials.deviceVersion, learned: heldRecordSize())
        if records.isEmpty {
            trace("%{public}@ no records payloadLen=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, kind, payload.count)
            if live {
                afterDelay(1.8) { [weak self] in _ = self?.requestRecentHistory("empty-live") }
            } else if activeHistoryEndExclusive > 0 {
                // An empty answer is still an answer. Do not let it stop the chain.
                cancelHistoryWatchdog()
                historyRetryCount = 0
                advanceHistoryChunkChain()
            }
            return
        }
        let activeMs = effectiveActiveTimeMs()
        let readings: [OttaiReading]
        if live {
            readings = [OttaiParser.toReading(records.last!, method: materials.method, coefficients: materials.coefficients, activeTimeMs: activeMs)]
        } else {
            readings = records.map { OttaiParser.toReading($0, method: materials.method, coefficients: materials.coefficients, activeTimeMs: activeMs) }
        }
        if !live && OttaiOutputFilter.isMisframedFrame(readings) {
            learnedRecordSize = widthBeforeFrame
            OttaiRegistry.saveRecordSize(sensorId, widthBeforeFrame)
            trace("discarding misframed history; restoring record width=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, widthBeforeFrame)
            if activeHistoryEndExclusive > 0 {
                cancelHistoryWatchdog()
                historyRetryCount = 0
                advanceHistoryChunkChain()
            }
            return
        }
        let previousDataNo = lastDataNo
        // A dataNo far past the sensor's real position means a broken packet.
        // Throw those records away before we change any state.
        let ceiling = dataNoCeiling(live: live)
        let plausible = ceiling == Int.max ? readings : readings.filter { $0.record.dataNo <= ceiling }
        if plausible.count < readings.count {
            trace("%{public}@ dropped %{public}d corrupt records dataNo>ceiling=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, kind, readings.count - plausible.count, ceiling)
        }
        noteCeilingOutcome(offered: readings.count, kept: plausible.count, ceiling: ceiling)
        if live && !plausible.isEmpty { lastLiveFrameAtMs = receivedAtMs }
        if live, notification, let reading = plausible.last, reading.valid, reading.record.rawCurrent > 0 {
            lastLiveNotifyAtMs = receivedAtMs
        }

        var emitted: [(dataNo: Int, glucose: GlucoseData)] = []
        for (index, r) in plausible.enumerated() {
            if !r.valid {
                trace("%{public}@ record rejected dataNo=%{public}d runtime=%{public}d raw=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, kind, r.record.dataNo, r.record.runtimeSec, r.record.rawCurrent)
                continue
            }
            if materials.method.isEmpty {
                trace("no method — skipping emit dataNo=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, r.record.dataNo)
                continue
            }
            if let e = emitReading(r, live: live, receivedAtMs: receivedAtMs, batch: plausible, batchIndex: index) {
                emitted.append(e)
            }
        }
        let newestDataNo = records.map { OttaiParser.parseRecord($0).dataNo }.max() ?? -1
        trace("%{public}@ decoded records=%{public}d newestDataNo=%{public}d emitted=%{public}d activeMs=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, kind, records.count, newestDataNo, emitted.count, "\(effectiveActiveTimeMs())")

        if !emitted.isEmpty { deliverOrBuffer(emitted) }

        if live {
            let liveDataNo = lastDataNo
            let previousForHistory = previousDataNoForHistory(previousDataNo, liveDataNo)
            if !initialFlushDone && !initialHistoryRequested && liveDataNo > 0 {
                // First live reading after a start: ask only for what xDrip is missing.
                if let range = Self.startupBackfillRange(liveDataNo: liveDataNo, lastDataNo: previousForHistory, deliveredDataNo: deliveredDataNo) {
                    if requestHistoryRange("room-backfill", start: range.start, count: range.count) { initialHistoryRequested = true }
                } else {
                    initialHistoryRequested = true
                    trace("skip history reason=room-backfill previous=%{public}d delivered=%{public}d live=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, previousForHistory, deliveredDataNo, liveDataNo)
                }
            } else if previousForHistory < 0 || liveDataNo - previousForHistory - 1 > 0 {
                historyGapPending = true
                afterDelay(1.5) { [weak self] in self?.requestHistoryAfterLive(previousForHistory, liveDataNo) }
            }
        } else {
            if !continueHistoryAfterPayload(plausible) {
                // A long history burst can end a few minutes behind the clock. Read
                // live right after it, unless live is already fresh.
                if shouldReadLiveAfterHistory(receivedAtMs) {
                    afterDelay(1.0) { [weak self] in
                        guard let self = self, self.commandStatus < 4 else { return }
                        self.readLiveGlucose("post-history")
                        self.scheduleLivePoll()
                    }
                }
            }
        }
    }

    /// An ended sensor gives no live readings. We only take the last dataNo from
    /// the live buffer and fetch history up to it. No glucose is published.
    private func handleEndedLiveBuffer(_ cipher: [UInt8]) {
        guard let payload = OttaiCrypto.decryptPayload(cipher, sessionKeyHex: sessionKeyHex) else { return }
        let latest = OttaiParser.frameRecords(payload, deviceVersion: materials.deviceVersion, learned: heldRecordSize())
            .map(OttaiParser.parseRecord).max { $0.dataNo < $1.dataNo }
        guard let latest = latest else {
            trace("ended live buffer has no records", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
            return
        }
        let previousDataNo = lastDataNo
        noteSeenDataNo(latest.dataNo)
        // Only a confirmed activation time may date this backfill. A guessed time
        // would give wrong dates.
        if streamStartTimeMs <= 0 && materials.activeTimeMs > 0 {
            _ = seedStreamTimeAnchor(latest.dataNo, materials.activeTimeMs + Int64(latest.runtimeSec) * 1000, "ended-live")
        }
        trace("ended live buffer indexed dataNo=%{public}d; glucose suppressed", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, latest.dataNo)
        afterDelay(4.5) { [weak self] in
            guard let self = self, self.commandStatus >= 4, self.phase == .streaming, !self.sessionKeyHex.isEmpty else { return }
            guard !self.initialHistoryRequested else { return }
            // Include the last record itself: an ended sensor sends no live reading that would bring it.
            guard let range = Self.startupBackfillRange(liveDataNo: self.lastDataNo + 1, lastDataNo: previousDataNo, deliveredDataNo: self.deliveredDataNo) else {
                self.initialHistoryRequested = true
                trace("skip history reason=ended-backfill previous=%{public}d delivered=%{public}d last=%{public}d", log: self.log, category: ConstantsLog.categoryCGMOttai, type: .info, previousDataNo, self.deliveredDataNo, self.lastDataNo)
                return
            }
            if self.requestHistoryRange("ended-backfill", start: range.start, count: range.count) { self.initialHistoryRequested = true }
        }
    }

    /// The learned layout to frame with, or nil while nothing has proved one.
    private func heldRecordSize() -> Int? { learnedRecordSize > 0 ? learnedRecordSize : nil }

    /// Learn the record size from a packet that is big enough to prove it. If a packet
    /// would choose a different size, log it once, with the counts for both sizes, so the
    /// log shows why. Only once, so a strange sensor cannot fill the log.
    private func learnRecordSize(_ payload: [UInt8]) {
        let decisive = learnedRecordSize == 0
            ? OttaiParser.decisiveRecordSize(payload, deviceVersion: materials.deviceVersion)
            : OttaiParser.contentRecordSize(payload)
        if let decisive = decisive {
            recordSizeDisagreementLogged = false
            if decisive != learnedRecordSize {
                let previous = learnedRecordSize
                learnedRecordSize = decisive
                OttaiRegistry.saveRecordSize(sensorId, decisive)
                trace("record size learned=%{public}d previous=%{public}d len=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, decisive, previous, payload.count)
            }
            return
        }
        guard learnedRecordSize > 0 else { return }
        let wouldChoose = OttaiParser.chooseRecordSize(payload, deviceVersion: materials.deviceVersion)
        if wouldChoose == learnedRecordSize {
            recordSizeDisagreementLogged = false
            return
        }
        if recordSizeDisagreementLogged { return }
        recordSizeDisagreementLogged = true
        let (nine, eight) = OttaiParser.recordSizeEvidence(payload)
        trace("record size held=%{public}d payloadWould=%{public}d nine=%{public}d eight=%{public}d len=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, learnedRecordSize, wouldChoose, nine, eight, payload.count)
    }

    // MARK: - one reading and all its checks (same order as the Kotlin)

    private func emitReading(_ r: OttaiReading, live: Bool, receivedAtMs: Int64, batch: [OttaiReading], batchIndex: Int) -> (dataNo: Int, glucose: GlucoseData)? {
        let mmol = Float(r.adjustGlucose)
        let mgdl = Double(mmol) * Self.mgdlPerMmoll
        if let reason = OttaiOutputFilter.hardRejectReason(record: r.record, mmol: mmol) {
            return rejectReading(r, mmol: mmol, live: live, reason: "hard-\(reason)")
        }
        if mgdl <= 1 { return rejectReading(r, mmol: mmol, live: live, reason: "mgdl=\(mgdl)") }
        if let reason = recentRejectedSampleReason(r, mmol: mmol) {
            return rejectReading(r, mmol: mmol, live: live, reason: reason)
        }
        repairAheadLastDataNoIfNeeded(acceptedDataNo: r.record.dataNo, live: live)
        let advancesDataNo = r.record.dataNo > lastDataNo
        let sampleMs = resolveSampleTimeMs(r, live: live, receivedAtMs: receivedAtMs)
        if sampleMs <= 0 {
            trace("no active-time anchor — skipping emit dataNo=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, r.record.dataNo)
            return nil
        }
        if OttaiRegistry.loadApiBase() == OttaiConstants.apiBaseGlobal, warmupAnchorMs() <= 0 {
            return rejectReading(r, mmol: mmol, live: live, reason: "activation-time unknown")
        }
        if OttaiConstants.isWithinWarmup(activationStartMs: warmupAnchorMs(), sampleMs: sampleMs, preheatPeriodMs: materials.preheatPeriodMs) {
            return rejectReading(r, mmol: mmol, live: live, reason: "warmup")
        }
        if let reason = continuityRejectReason(r, mmol: mmol, sampleMs: sampleMs, live: live, batch: batch, batchIndex: batchIndex) {
            noteContinuityRejection(dataNo: r.record.dataNo, sampleMs: sampleMs)
            return rejectReading(r, mmol: mmol, live: live, reason: reason)
        }
        if live && acceptedLiveTimes[r.record.dataNo] == nil {
            // Only accepted, new counters can confirm the sensor start time.
            let monitorMs = r.monitorTimeMs
            let hintMs = monitorMs > 0 && monitorMs <= receivedAtMs && receivedAtMs - monitorMs <= Self.currentSampleFreshMs
                ? monitorMs : receivedAtMs
            offerConfirmedActiveTime(hintMs - Int64(r.record.dataNo) * Self.recordIntervalMs, dataNo: r.record.dataNo)
            if let corrected = arrivalCorrection.accept(anchor: streamStartTimeMs, counter: r.record.dataNo, received: receivedAtMs) {
                streamStartTimeMs = corrected
            }
            acceptedLiveTimes[r.record.dataNo] = sampleMs
            acceptedLiveOrder.append(r.record.dataNo)
            if acceptedLiveOrder.count > 64 {
                acceptedLiveTimes.removeValue(forKey: acceptedLiveOrder.removeFirst())
            }
        }
        let previousGlucoseAtMs = lastGlucoseAtMs
        let freshLiveSample = live && isFreshLiveSample(receivedAtMs: receivedAtMs, sampleMs: sampleMs)
        let newest = sampleMs >= previousGlucoseAtMs
        if newest && (!live || freshLiveSample) {
            lastGlucoseAtMs = sampleMs
        }
        rememberAcceptedReading(r, mmol: mmol, sampleMs: sampleMs)
        if advancesDataNo { noteSeenDataNo(r.record.dataNo) }
        trace("BG dataNo=%{public}d mmol=%{public}@ mgdl=%{public}@ raw=%{public}d T=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, r.record.dataNo, String(format: "%.2f", Double(mmol)), String(format: "%.0f", mgdl), r.record.rawCurrent, String(format: "%.1f", r.record.temperatureC))
        // Like the Kotlin: history is always kept. A live reading is kept only when
        // it is fresh and newer than the last one. An old record that comes from the
        // live characteristic is never shown as the current value.
        let shouldPersist = !live || (freshLiveSample && sampleMs > previousGlucoseAtMs)
        if !shouldPersist {
            trace("live sample not persisted (fresh=%{public}@ newer=%{public}@) dataNo=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, freshLiveSample.description, (sampleMs > previousGlucoseAtMs).description, r.record.dataNo)
            return nil
        }
        // xDrip only: the same reading also goes to the Syai cloud (if turned on)
        cloudUploader.enqueue(reading: r, mmol: Double(mmol), sampleMs: sampleMs, receivedAtMs: receivedAtMs, live: live)
        return (r.record.dataNo, GlucoseData(timeStamp: Date(timeIntervalSince1970: Double(sampleMs) / 1000.0), glucoseLevelRaw: mgdl))
    }

    private func rejectReading(_ r: OttaiReading, mmol: Float, live: Bool, reason: String) -> (dataNo: Int, glucose: GlucoseData)? {
        rememberRejectedReading(r, mmol: mmol)
        trace("%{public}@ BG rejected reason=%{public}@ dataNo=%{public}d mmol=%{public}@ raw=%{public}d T=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, live ? "live" : "history", reason, r.record.dataNo, String(format: "%.2f", Double(mmol)), r.record.rawCurrent, String(format: "%.1f", r.record.temperatureC))
        return nil
    }

    private func rememberRejectedReading(_ r: OttaiReading, mmol: Float) {
        let key = r.record.dataNo
        if recentlyRejectedSamples[key] == nil {
            recentlyRejectedOrder.append(key)
            if recentlyRejectedOrder.count > 64 {
                recentlyRejectedSamples.removeValue(forKey: recentlyRejectedOrder.removeFirst())
            }
        }
        recentlyRejectedSamples[key] = RejectedSample(rawCurrent: r.record.rawCurrent, mmol: mmol)
    }

    private func recentRejectedSampleReason(_ r: OttaiReading, mmol: Float) -> String? {
        guard let rejected = recentlyRejectedSamples[r.record.dataNo] else { return nil }
        let sameRaw = rejected.rawCurrent == r.record.rawCurrent
        let sameValue = abs(rejected.mmol - mmol) < 0.05
        return (sameRaw || sameValue) ? "recent-rejected raw=\(rejected.rawCurrent) mmol=\(rejected.mmol)" : nil
    }

    private func isFreshLiveSample(receivedAtMs: Int64, sampleMs: Int64) -> Bool {
        receivedAtMs > 0 && sampleMs > 0 &&
            abs(receivedAtMs - sampleMs) <= Self.currentSampleFreshMs + Self.currentSampleFloorGraceMs
    }

    private func shouldReadLiveAfterHistory(_ receivedAtMs: Int64) -> Bool {
        if lastLiveFrameAtMs <= 0 { return true }
        let since = receivedAtMs - lastLiveFrameAtMs
        return since < 0 || since >= Self.recordIntervalMs
    }

    // MARK: - dataNo bookkeeping

    private func noteSeenDataNo(_ dataNo: Int) {
        if dataNo <= lastDataNo { return }
        lastDataNo = dataNo
        OttaiRegistry.saveLastDataNo(sensorId, dataNo)
    }

    private func isPersistedDataNoAheadOfLive(_ previousDataNo: Int, _ liveDataNo: Int) -> Bool {
        previousDataNo >= 0 && liveDataNo >= 0 && previousDataNo > liveDataNo + Self.maxReasonableDataNoAhead
    }

    private func previousDataNoForHistory(_ previousDataNo: Int, _ liveDataNo: Int) -> Int {
        isPersistedDataNoAheadOfLive(previousDataNo, liveDataNo) ? -1 : previousDataNo
    }

    private func repairAheadLastDataNoIfNeeded(acceptedDataNo: Int, live: Bool) {
        guard live, isPersistedDataNoAheadOfLive(lastDataNo, acceptedDataNo) else { return }
        trace("reset ahead lastDataNo previous=%{public}d acceptedLive=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, lastDataNo, acceptedDataNo)
        lastDataNo = acceptedDataNo - 1
        OttaiRegistry.saveLastDataNo(sensorId, lastDataNo)
        if deliveredDataNo > lastDataNo {
            deliveredDataNo = 0
            OttaiRegistry.saveDeliveredDataNo(sensorId, 0)
        }
    }

    /// The highest dataNo we accept. Only a real activation time (from the cloud
    /// or confirmed by two anchors) may set this limit.
    private func dataNoCeiling(live: Bool) -> Int {
        if ceilingDistrusted { return Int.max }
        let start = materials.activeTimeMs
        let now = nowMs()
        if start > 0 && start < now {
            let elapsed = Int(min((now - start) / Self.recordIntervalMs, Int64(Int.max / 2)))
            return elapsed + Self.maxReasonableDataNoAhead
        }
        if live { return Int.max }
        return lastDataNo > 0 ? lastDataNo + Self.maxReasonableDataNoAhead : Int.max
    }

    private func noteCeilingOutcome(offered: Int, kept: Int, ceiling: Int) {
        if offered <= 0 || ceiling == Int.max { return }
        if kept > 0 { consecutiveCeilingFullDrops = 0; return }
        consecutiveCeilingFullDrops += 1
        if !ceilingDistrusted && consecutiveCeilingFullDrops >= Self.maxConsecutiveCeilingFullDrops {
            ceilingDistrusted = true
            trace("dataNo ceiling=%{public}d rejected %{public}d payloads in a row — distrusting it for this session", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, ceiling, consecutiveCeilingFullDrops)
        }
    }

    // MARK: - continuity check (spike filter)

    private func rememberAcceptedReading(_ r: OttaiReading, mmol: Float, sampleMs: Int64) {
        recentlyRejectedSamples.removeValue(forKey: r.record.dataNo)
        noteContinuityEvaluated(dataNo: r.record.dataNo, sampleMs: sampleMs)
        // The baseline only moves forward. An old history record must not replace
        // a newer baseline.
        if lastAcceptedDataNo >= 0 && r.record.dataNo < lastAcceptedDataNo { return }
        lastAcceptedDataNo = r.record.dataNo
        lastAcceptedSampleMs = sampleMs
        lastAcceptedMmol = mmol
        lastAcceptedRawCurrent = r.record.rawCurrent
        consecutiveContinuityRejects = 0
        OttaiRegistry.saveContinuityBaseline(sensorId, dataNo: r.record.dataNo, sampleMs: sampleMs, mmol: mmol, rawCurrent: r.record.rawCurrent)
    }

    private func noteContinuityRejection(dataNo: Int, sampleMs: Int64) {
        consecutiveContinuityRejects += 1
        noteContinuityEvaluated(dataNo: dataNo, sampleMs: sampleMs)
    }

    private func noteContinuityEvaluated(dataNo: Int, sampleMs: Int64) {
        if dataNo < lastEvaluatedDataNo { return }
        lastEvaluatedDataNo = dataNo
        lastEvaluatedSampleMs = sampleMs
    }

    private func isAdjacentSample(previousDataNo: Int, previousSampleMs: Int64, dataNo: Int, sampleMs: Int64) -> Bool {
        if previousDataNo < 0 { return false }
        if (1 ... 2).contains(dataNo - previousDataNo) { return true }
        if previousSampleMs <= 0 || sampleMs <= previousSampleMs { return false }
        return (1 ... (2 * Self.recordIntervalMs + 15_000)).contains(sampleMs - previousSampleMs)
    }

    private func isAdjacentToLastEvaluated(dataNo: Int, sampleMs: Int64) -> Bool {
        isAdjacentSample(previousDataNo: lastEvaluatedDataNo, previousSampleMs: lastEvaluatedSampleMs, dataNo: dataNo, sampleMs: sampleMs)
    }

    private func isImmediatelyBeforeLastAccepted(dataNo: Int, sampleMs: Int64) -> Bool {
        let nextDataNo = lastAcceptedDataNo
        if nextDataNo < 0 { return false }
        if (1 ... 2).contains(nextDataNo - dataNo) { return true }
        let nextMs = lastAcceptedSampleMs
        if nextMs <= 0 || sampleMs >= nextMs { return false }
        return (1 ... (2 * Self.recordIntervalMs + 15_000)).contains(nextMs - sampleMs)
    }

    private func continuityRejectReason(_ r: OttaiReading, mmol: Float, sampleMs: Int64, live: Bool, batch: [OttaiReading], batchIndex: Int) -> String? {
        // After a few rejections in a row, give up and take the next sample as the
        // new baseline (the sensor may really have jumped, e.g. an electrode restart).
        if consecutiveContinuityRejects >= Self.maxConsecutiveContinuityRejects {
            trace("continuity gate yielding after %{public}d consecutive rejections; re-baselining on dataNo=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, consecutiveContinuityRejects, r.record.dataNo)
            return nil
        }
        if isAdjacentToLastEvaluated(dataNo: r.record.dataNo, sampleMs: sampleMs),
           OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: mmol, candidateRaw: r.record.rawCurrent, baselineMmol: lastAcceptedMmol, baselineRaw: lastAcceptedRawCurrent) {
            return "continuity-prev dataNo=\(lastAcceptedDataNo) mmol=\(lastAcceptedMmol) raw=\(lastAcceptedRawCurrent)"
        }
        if !live,
           isImmediatelyBeforeLastAccepted(dataNo: r.record.dataNo, sampleMs: sampleMs),
           OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: mmol, candidateRaw: r.record.rawCurrent, baselineMmol: lastAcceptedMmol, baselineRaw: lastAcceptedRawCurrent) {
            return "continuity-next dataNo=\(lastAcceptedDataNo) mmol=\(lastAcceptedMmol) raw=\(lastAcceptedRawCurrent)"
        }
        if !live, let reason = historyIsolatedSpikeReason(batch, batchIndex, r, mmol) { return reason }
        return nil
    }

    private struct NeighborSample { let dataNo: Int; let mmol: Float; let rawCurrent: Int }

    private func historyIsolatedSpikeReason(_ batch: [OttaiReading], _ batchIndex: Int, _ candidate: OttaiReading, _ candidateMmol: Float) -> String? {
        let previous = neighborSample(batch, start: batchIndex - 1, step: -1)
        let next = neighborSample(batch, start: batchIndex + 1, step: 1)
        let previousAdjacent = previous.map { (1 ... 2).contains(candidate.record.dataNo - $0.dataNo) } ?? false
        let nextAdjacent = next.map { (1 ... 2).contains($0.dataNo - candidate.record.dataNo) } ?? false
        if previousAdjacent, nextAdjacent, let p = previous, let n = next {
            let neighborsAgree = abs(p.mmol - n.mmol) < OttaiOutputFilter.singleSampleDeltaMmol
            if neighborsAgree,
               OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: candidateMmol, candidateRaw: candidate.record.rawCurrent, baselineMmol: p.mmol, baselineRaw: p.rawCurrent),
               OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: candidateMmol, candidateRaw: candidate.record.rawCurrent, baselineMmol: n.mmol, baselineRaw: n.rawCurrent) {
                return "history-isolated prev=\(p.dataNo) next=\(n.dataNo)"
            }
        }
        if !previousAdjacent, nextAdjacent, candidate.record.dataNo <= 5, let n = next,
           OttaiOutputFilter.isOneMinuteRawExcursion(candidateMmol: candidateMmol, candidateRaw: candidate.record.rawCurrent, baselineMmol: n.mmol, baselineRaw: n.rawCurrent) {
            return "history-start next=\(n.dataNo)"
        }
        return nil
    }

    private func neighborSample(_ batch: [OttaiReading], start: Int, step: Int) -> NeighborSample? {
        var index = start
        while batch.indices.contains(index) {
            let reading = batch[index]
            if reading.valid {
                let mmol = Float(reading.adjustGlucose)
                if OttaiOutputFilter.hardRejectReason(record: reading.record, mmol: mmol) == nil {
                    return NeighborSample(dataNo: reading.record.dataNo, mmol: mmol, rawCurrent: reading.record.rawCurrent)
                }
            }
            index += step
        }
        return nil
    }

    // MARK: - sample times

    private func effectiveActiveTimeMs() -> Int64 {
        if materials.activeTimeMs > 0 { return materials.activeTimeMs }
        if streamStartTimeMs > 0 { return streamStartTimeMs }
        return provisionalActiveTimeMs > 0 ? provisionalActiveTimeMs : 0
    }

    /// The start time the warmup check may trust: the cloud time, or else the
    /// moment we sent the activation command. Never a guessed time.
    private func warmupAnchorMs() -> Int64 {
        materials.activeTimeMs > 0 ? materials.activeTimeMs : (activationCommandSentAtMs > 0 ? activationCommandSentAtMs : 0)
    }

    private func resolveSampleTimeMs(_ r: OttaiReading, live: Bool, receivedAtMs: Int64) -> Int64 {
        if live, let accepted = acceptedLiveTimes[r.record.dataNo] { return accepted }
        if streamStartTimeMs > 0 && (streamStartReliable || !live) {
            let anchored = streamStartTimeMs + Int64(r.record.dataNo) * Self.recordIntervalMs
            return live && receivedAtMs > 0 ? min(anchored, receivedAtMs) : anchored
        }
        if live && receivedAtMs > 0 && r.record.dataNo >= 0 {
            let monitorMs = r.monitorTimeMs
            if monitorMs > 0 && monitorMs <= receivedAtMs && receivedAtMs - monitorMs <= Self.currentSampleFreshMs {
                return seedStreamTimeAnchor(r.record.dataNo, monitorMs, "monitor-live", reliable: true, receivedAtMs: receivedAtMs)
            }
            if monitorMs > 0 {
                trace("ignore stale live monitor timestamp dataNo=%{public}d delta=%{public}ds", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, r.record.dataNo, Int(abs(receivedAtMs - monitorMs) / 1000))
            }
            return seedStreamTimeAnchor(r.record.dataNo, receivedAtMs, "live", reliable: true, receivedAtMs: receivedAtMs)
        }
        if r.monitorTimeMs > 0 {
            return seedStreamTimeAnchor(r.record.dataNo, r.monitorTimeMs, "monitor")
        }
        let activeMs = effectiveActiveTimeMs()
        if activeMs > 0 {
            return seedStreamTimeAnchor(r.record.dataNo, activeMs + Int64(r.record.runtimeSec) * 1000, "active")
        }
        return r.monitorTimeMs
    }

    private func seedStreamTimeAnchor(_ dataNo: Int, _ sampleHintMs: Int64, _ reason: String, reliable: Bool = false, receivedAtMs: Int64 = 0) -> Int64 {
        if dataNo < 0 || sampleHintMs <= 0 { return sampleHintMs }
        let sampleMs = sampleHintMs
        let start = sampleMs - Int64(dataNo) * Self.recordIntervalMs
        if start > 0 {
            let old = streamStartTimeMs
            // A time from the real clock is never replaced by a guessed time.
            if old > 0 && streamStartReliable && !reliable {
                return old + Int64(dataNo) * Self.recordIntervalMs
            }
            streamStartTimeMs = start
            streamStartReliable = reliable
            arrivalCorrection.seed(start: start, arrivalStart: reliable && receivedAtMs > 0 ? receivedAtMs - Int64(dataNo) * Self.recordIntervalMs : 0)
            if old == 0 || abs(old - start) > Self.recordIntervalMs {
                trace("stream time anchor dataNo=%{public}d start=%{public}@ source=%{public}@ reliable=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, dataNo, "\(start / 1000)", reason, reliable.description)
            }
        }
        return sampleMs
    }

    /// Two start times, found on their own, must agree before we save the
    /// activation time. A broken dataNo gives a time far away; a real pair is
    /// within a minute or two.
    private func offerConfirmedActiveTime(_ startMs: Int64, dataNo: Int) {
        if startMs <= 0 || materials.activeTimeMs > 0 { return }
        let now = nowMs()
        if startMs > now || now - startMs > OttaiConstants.extendedLifetimeMs {
            trace("implausible activation start=%{public}@ ignored", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, "\(startMs / 1000)")
            return
        }
        let pending = pendingConfirmedStartMs
        if pending <= 0 {
            pendingConfirmedStartMs = startMs
            pendingConfirmedDataNo = dataNo
            trace("activation start candidate=%{public}@ awaiting corroboration", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, "\(startMs / 1000)")
            return
        }
        guard pendingConfirmedDataNo != dataNo else { return }
        if abs(pending - startMs) <= Self.confirmedStartAgreementMs {
            materials.activeTimeMs = startMs
            provisionalActiveTimeMs = 0
            OttaiRegistry.saveActiveTimeMs(sensorId, startMs)
            OttaiRegistry.saveProvisionalActiveTime(sensorId, 0)
            trace("confirmed activeTime=%{public}@ persisted from live anchor", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, "\(startMs / 1000)")
            reportSensorSessionIfNeeded()
            return
        }
        trace("activation start candidates disagree: %{public}@ vs %{public}@; re-arming corroboration", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, "\(pending / 1000)", "\(startMs / 1000)")
        pendingConfirmedStartMs = startMs
        pendingConfirmedDataNo = dataNo
    }

    private func setProvisionalActiveTime(_ activeTimeMs: Int64, _ reason: String) {
        if activeTimeMs <= 0 || materials.activeTimeMs > 0 { return }
        // The guessed time may only move to an earlier moment.
        if provisionalActiveTimeMs > 0 && activeTimeMs >= provisionalActiveTimeMs { return }
        provisionalActiveTimeMs = activeTimeMs
        OttaiRegistry.saveProvisionalActiveTime(sensorId, activeTimeMs)
        trace("provisional activeTime set source=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, reason)
    }

    /// The delegate reconstructs the start from the newest measurement, not delivery time.
    /// A delayed/backfilled batch must retain the original session and warm-up boundary.
    static func sensorAge(for readings: [GlucoseData], activeTimeMs: Int64) -> TimeInterval? {
        guard activeTimeMs > 0, !readings.isEmpty,
              readings.allSatisfy({ $0.timeStamp.timeIntervalSince1970.isFinite }),
              let latest = readings.map(\.timeStamp).max() else { return nil }
        let age = latest.timeIntervalSince1970 - Double(activeTimeMs) / 1000.0
        return age.isFinite && age >= 0 ? age : nil
    }

    /// xDrip only: tell xDrip when this sensor started, so the home screen shows the
    /// warm-up countdown and the sensor age. Without this, the session is only created
    /// when the first reading is processed — and during the warm-up no reading is
    /// processed, so the screen said "waiting for data" with no countdown.
    /// Reports each start once. Does nothing when xDrip already has a session within
    /// 10 minutes of ours (a report stops and starts the xDrip sensor session).
    func reportSensorSessionIfNeeded() {
        let startMs = effectiveActiveTimeMs()
        guard startMs > 0, startMs != lastReportedSensorStartMs, let token = delivery.token() else { return }
        lastReportedSensorStartMs = startMs
        if let existing = UserDefaults.standard.activeSensorStartDate,
           abs(existing.timeIntervalSince1970 - Double(startMs) / 1000.0) < 10 * 60 {
            return
        }
        trace("reporting sensor session start=%{public}@ to xDrip", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, "\(startMs / 1000)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.delivery.allows(token) else { return }
            self.cgmTransmitterDelegate?.newSensorDetected(sensorStartDate: Date(timeIntervalSince1970: Double(startMs) / 1000.0))
        }
    }

    // MARK: - giving readings to xDrip (see the file header)

    private func deliverOrBuffer(_ emitted: [(dataNo: Int, glucose: GlucoseData)]) {
        if !initialFlushDone {
            for p in emitted { initialBuffer[p.dataNo] = p.glucose }
            flushGeneration += 1
            let gen = flushGeneration
            workQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in self?.flushInitialBufferIfIdle(gen) }
        } else {
            deliver(emitted.map { $0.glucose }.sorted { $0.timeStamp > $1.timeStamp }, upTo: emitted.map { $0.dataNo }.max() ?? 0)
        }
    }

    private func flushInitialBufferIfIdle(_ generation: Int) {
        guard !initialFlushDone, flushGeneration == generation else { return }
        initialFlushDone = true
        let arr = Array(initialBuffer.values).sorted { $0.timeStamp > $1.timeStamp }
        let newestDataNo = initialBuffer.keys.max() ?? 0
        initialBuffer.removeAll()
        guard !arr.isEmpty else { return }
        trace("flushing initial backfill count=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, arr.count)
        deliver(arr, upTo: newestDataNo)
    }

    /// Gives the readings to xDrip on the main queue. `newestDataNo` is the highest
    /// dataNo in the batch. Once xDrip has stored the batch, it can become the saved
    /// "delivered" mark (see `noteDelivered(upTo:)`).
    func deliver(_ readings: [GlucoseData], upTo newestDataNo: Int) {
        guard !readings.isEmpty, let token = delivery.token() else { return }
        let sensorAge = Self.sensorAge(for: readings, activeTimeMs: effectiveActiveTimeMs())
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.delivery.allows(token) else { return }
            var arr = readings
            self.cgmTransmitterDelegate?.cgmTransmitterInfoReceived(glucoseData: &arr, transmitterBatteryInfo: nil, sensorAge: sensorAge)
            self.workQueue.async { [weak self] in
                guard let self, self.delivery.allows(token) else { return }
                self.noteDelivered(upTo: newestDataNo)
            }
        }
    }

    /// Moves the saved "delivered" mark forward. Not while older records are still on
    /// the way (a gap fill is planned or history blocks are still coming): the next
    /// start would then not see the hole.
    private func noteDelivered(upTo dataNo: Int) {
        guard dataNo > deliveredDataNo else { return }
        guard !historyGapPending, activeHistoryEndExclusive <= 0, pendingHistoryReason == nil else { return }
        deliveredDataNo = dataNo
        OttaiRegistry.saveDeliveredDataNo(sensorId, dataNo)
    }

    // MARK: - cgm-info packets

    private func handleCgmInfo(_ value: [UInt8]) {
        let head = value.prefix(2).map { String(format: "%02x", $0) }.joined()
        trace("cgm-info len=%{public}d head=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, value.count, head)
        // Note: the 0x0477 packet is NOT glucose. Nothing is published from cgm-info.
        guard value.count >= 4, value[0] == 0x07, value[1] == 0x77 else { return }
        let seconds = Int(value[2]) | (Int(value[3]) << 8)
        guard seconds >= 5, seconds <= 3600 else { return }
        let next = min(Int64(seconds) * 1000, Self.maxLivePollIntervalMs)
        if next == livePollIntervalMs { return }
        livePollIntervalMs = next
        trace("live poll interval=%{public}ds from cgm-info raw=%{public}ds", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, Int(next / 1000), seconds)
        if phase == .streaming, !sessionKeyHex.isEmpty { scheduleLivePoll() }
    }

    private func handleMaxActiveRead(_ value: [UInt8]) {
        guard let owner = lifetimeReadOwner else { return }
        lifetimeReadOwner = nil
        let duration = OttaiLifetimeTransaction.decode(value, sessionKeyHex: sessionKeyHex)
        if var transaction = lifetimeTransaction {
            guard owner == transaction.id, lifetimeContextIsCurrent() else {
                failLifetimeOperation("The lifetime reply belongs to another operation or session."); return
            }
            let effect = transaction.duration(duration)
            lifetimeTransaction = transaction
            runLifetimeEffect(effect)
        } else if owner == "display", let duration {
            adoptActivatedMaxActive(duration, evidence: .sensorReadback)
        }
    }

    private func readLifetimeForDisplay() {
        guard lifetimeTransaction == nil, lifetimeReadOwner == nil, !lifetimeReadsBlocked,
              !sessionKeyHex.isEmpty, actStep == .none || actStep == .done else { return }
        lifetimeReadOwner = "display"
        readChar(OttaiConstants.charMaxActiveTime)
        afterDelay(10) { [weak self] in
            guard let self, self.lifetimeReadOwner == "display" else { return }
            self.lifetimeReadOwner = nil
            self.lifetimeReadsBlocked = true
        }
    }

    /// Explicit user action only. A remaining durable intent is reconciled using reads;
    /// reconnect, restart and app upgrade never submit a second write.
    func extendActiveSensorLifetime() {
        workQueue.async { [weak self] in self?.beginActiveLifetimeOperation() }
    }

    private func beginActiveLifetimeOperation() {
        guard lifetimeTransaction == nil, lifetimeReadOwner == nil, !lifetimeReadsBlocked,
              !commandReadOutstanding, actStep == .none || actStep == .done,
              !pendingActivation, !activationRequested, !serverActivating,
              phase == .streaming, !sessionKeyHex.isEmpty, authKeys != nil else {
            OttaiRegistry.saveLifetimeStatus(sensorId, "Lifetime is busy or the connection is not ready. Reconnect and retry."); return
        }
        #if DEBUG
        let account = lifetimeTestContext ? (lifetimeAccount ?? OttaiRegistry.accountContext()) : OttaiRegistry.accountContext()
        #else
        let account = OttaiRegistry.accountContext()
        #endif
        #if DEBUG
        let sessionAvailable = lifetimeTestContext || OttaiCloudClient.isSignedIn
        #else
        let sessionAvailable = OttaiCloudClient.isSignedIn
        #endif
        guard sessionAvailable, let bluetoothID = deviceAddress, UUID(uuidString: bluetoothID) != nil else {
            OttaiRegistry.saveLifetimeStatus(sensorId, "Sign in and connect to this sensor before changing its lifetime."); return
        }
        let pending = OttaiRegistry.loadLifetimeIntent(sensorId)
        guard !OttaiRegistry.hasLifetimeIntent(sensorId) || pending != nil else {
            OttaiRegistry.saveLifetimeStatus(sensorId, "The saved lifetime request is unreadable. No new write was sent."); return
        }
        if let pending, !pending.matches(sensorID: sensorId, bluetoothID: bluetoothID, account: account) {
            OttaiRegistry.saveLifetimeStatus(sensorId, "An unresolved lifetime request belongs to another account or Bluetooth sensor. Restore that connection and read its result first."); return
        }
        lifetimeAccount = account
        lifetimeBluetoothID = bluetoothID
        lifetimeConnectionID = connectionID
        let transaction = OttaiLifetimeTransaction(mode: pending == nil ? .extendActive : .reconcile)
        lifetimeTransaction = transaction
        OttaiRegistry.saveLifetimeStatus(sensorId, pending == nil ? "Checking the active sensor before requesting 30 days total…" : "Reading the previous request result; no lifetime write will be sent…")
        runLifetimeEffect(transaction.firstEffect)
    }

    private func beginActivationLifetime(_ targetMs: Int64) {
        guard lifetimeTransaction == nil, lifetimeReadOwner == nil, !lifetimeReadsBlocked,
              activationContextIsCurrent(), !sessionKeyHex.isEmpty else {
            failActivation("The lifetime read-back is busy or unavailable. Reconnect before starting the sensor."); return
        }
        lifetimeAccount = activationAccount
        lifetimeBluetoothID = deviceAddress ?? ""
        lifetimeConnectionID = connectionID
        let transaction = OttaiLifetimeTransaction(mode: .activation, targetMs: targetMs)
        lifetimeTransaction = transaction
        runLifetimeEffect(transaction.firstEffect)
    }

    private func lifetimeContextIsCurrent() -> Bool {
        #if DEBUG
        if lifetimeTestContext {
            return !released && lifetimeConnectionID == connectionID && lifetimeBluetoothID == deviceAddress
                && !sessionKeyHex.isEmpty && (lifetimeTransaction?.mode != .activation || activationContextIsCurrent())
        }
        #endif
        guard !released, let account = lifetimeAccount, OttaiRegistry.isCurrent(account),
              lifetimeBluetoothID == deviceAddress, lifetimeConnectionID == connectionID,
              !sessionKeyHex.isEmpty, connectedPeripheral?.state == .connected else { return false }
        if lifetimeTransaction?.mode == .activation { return activationContextIsCurrent() }
        return true
    }

    private func runLifetimeEffect(_ effect: OttaiLifetimeTransaction.Effect) {
        guard let transaction = lifetimeTransaction else { return }
        switch effect {
        case .none: return
        case .failed(let message):
            failLifetimeOperation(message); return
        case .activationVerified(let duration):
            guard lifetimeContextIsCurrent() else { failLifetimeOperation("The activation session changed during read-back."); return }
            lifetimeTransaction = nil
            adoptActivatedMaxActive(duration, evidence: .sensorReadback)
            if actStep == .globalM8 {
                globalActivationWriteIndex += 1
                writeGlobalActivationStep()
            } else { advanceActivation() }
            return
        case .activeVerified(let duration, let wrote):
            guard lifetimeContextIsCurrent() else { failLifetimeOperation("The active sensor session changed during read-back."); return }
            lifetimeTransaction = nil
            adoptActivatedMaxActive(duration, evidence: .sensorReadback)
            OttaiRegistry.clearLifetimeIntent(sensorId)
            let days = duration / 86_400_000
            OttaiRegistry.saveLifetimeStatus(sensorId, "Lifetime parameter read from the active sensor: \(days) days total from its original start. \(wrote ? "Requested parameter confirmed." : "Read-only check completed.") Actual operation beyond the original expiry is unverified.")
            return
        case .readStatus:
            guard lifetimeContextIsCurrent(), charIsReadable(OttaiConstants.charCommand) else {
                failLifetimeOperation("The sensor status cannot be read on this connection."); return
            }
            readChar(OttaiConstants.charCommand)
        case .readDuration:
            guard lifetimeContextIsCurrent(), lifetimeReadOwner == nil, charIsReadable(OttaiConstants.charMaxActiveTime) else {
                failLifetimeOperation("The lifetime characteristic cannot be read. No activation was sent."); return
            }
            lifetimeReadOwner = transaction.id
            readChar(OttaiConstants.charMaxActiveTime)
        case .persistAndWrite:
            guard lifetimeContextIsCurrent(), (transaction.mode == .activation || commandStatus == 3),
                  charIsReadable(OttaiConstants.charMaxActiveTime),
                  charIsWritable(OttaiConstants.charMaxActiveTime),
                  let encrypted = OttaiCrypto.encryptPayload(longToBytesLE(transaction.targetMs / 1000), sessionKeyHex: sessionKeyHex) else {
                failLifetimeOperation("The lifetime characteristic or authenticated encryption is unavailable. No activation was sent."); return
            }
            if transaction.mode == .extendActive {
                let originalStart = effectiveActiveTimeMs()
                guard originalStart <= 0 || nowMs() - originalStart < transaction.targetMs else {
                    failLifetimeOperation("This sensor has already reached 30 days from its original start. No lifetime write was sent."); return
                }
                guard let account = lifetimeAccount else { failLifetimeOperation("The account changed."); return }
                let intent = OttaiLifetimeIntent(sensorID: sensorId, bluetoothID: lifetimeBluetoothID,
                    apiBase: account.apiBase, userID: account.userId, targetMs: transaction.targetMs, requestedAtMs: nowMs())
                guard OttaiRegistry.saveLifetimeIntent(intent) else { failLifetimeOperation("Could not save the lifetime request. No write was sent."); return }
            }
            lifetimeTransaction?.writeIssued()
            guard writeChar(OttaiConstants.charMaxActiveTime, encrypted) else {
                failLifetimeOperation("The lifetime write could not be submitted. Reconnect and read its result."); return
            }
        }
        armLifetimeTimeout()
    }

    private func armLifetimeTimeout() {
        guard let transaction = lifetimeTransaction else { return }
        let id = transaction.id, stage = transaction.stage
        afterDelay(10) { [weak self] in
            guard let self, self.lifetimeTransaction?.id == id, self.lifetimeTransaction?.stage == stage else { return }
            self.failLifetimeOperation("The lifetime operation timed out. Reconnect and read its result; no activation was sent.")
        }
    }

    private func failLifetimeOperation(_ message: String) {
        let activation = lifetimeTransaction?.mode == .activation
        lifetimeTransaction = nil
        lifetimeReadOwner = nil
        // Late ATT replies in this connection must not satisfy another operation.
        lifetimeReadsBlocked = true
        OttaiRegistry.saveLifetimeStatus(sensorId, message)
        if activation { failActivation(message) }
    }

    private func interruptLifetimeOperation() {
        guard lifetimeTransaction != nil else { return }
        failLifetimeOperation("The connection ended before lifetime verification. Reconnect and read the result; no request will be replayed automatically.")
    }

    private func charIsReadable(_ uuid: String) -> Bool {
        #if DEBUG
        if let availability = lifetimeTestReadable { return availability(uuid) }
        if lifetimeTestRead != nil { return true }
        #endif
        return char(uuid)?.properties.contains(.read) == true
    }

    private func charIsWritable(_ uuid: String) -> Bool {
        #if DEBUG
        if lifetimeTestWrite != nil { return true }
        #endif
        return char(uuid)?.properties.contains(.write) == true
    }

    private func isCurrentCallback(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) -> Bool {
        !released && peripheral.state == .connected && connectedPeripheral === peripheral
            && char(characteristic.uuid.full128) === characteristic
    }

    // MARK: - live poll

    private func scheduleLivePoll() {
        livePollTimer?.cancel()
        guard phase == .streaming, !sessionKeyHex.isEmpty else { return }
        let delayMs = min(max(livePollIntervalMs, 5_000), 3_600_000)
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + .milliseconds(Int(delayMs)))
        timer.setEventHandler { [weak self] in self?.livePollFired() }
        timer.resume()
        livePollTimer = timer
    }

    private func livePollFired() {
        guard phase == .streaming, !sessionKeyHex.isEmpty, commandStatus < 4 else { return }
        // Wait while notifications keep coming on time.
        let sinceNotifyMs = nowMs() - lastLiveNotifyAtMs
        if lastLiveNotifyAtMs > 0 && sinceNotifyMs < livePollIntervalMs {
            scheduleLivePoll()
            return
        }
        readLiveGlucose("poll")
        scheduleLivePoll()
    }

    // MARK: - history requests, block chain and watchdog

    /// What to ask the sensor for right after a start. `liveDataNo` is the record that
    /// just came in (the range ends before it). `lastDataNo` is the last record we saw
    /// before it (0 or less = nothing known). `deliveredDataNo` is the saved mark of what
    /// xDrip already has. Nil when nothing is missing. The Kotlin uses previousDataNo the
    /// same way; the delivered mark also covers readings that were still in the start
    /// buffer when the app died. A sensor we know nothing about gets the last 24 h. That
    /// is also the most one start ever asks for.
    static func startupBackfillRange(liveDataNo: Int, lastDataNo: Int, deliveredDataNo: Int) -> (start: Int, count: Int)? {
        guard liveDataNo > 0 else { return nil }
        let oldest = max(0, liveDataNo - initialBackfillRecords)
        guard lastDataNo > 0 else { return (oldest, liveDataNo - oldest) }
        var basis = lastDataNo
        if deliveredDataNo > 0 && deliveredDataNo < basis { basis = deliveredDataNo }
        let start = max(basis + 1, oldest)
        let count = liveDataNo - start
        return count > 0 ? (start, count) : nil
    }

    @discardableResult
    private func requestRecentHistory(_ reason: String) -> Bool {
        let endExclusive = lastDataNo
        guard endExclusive > 0 else { return false }
        let start = max(0, endExclusive - Self.recentHistoryRecords)
        return requestHistoryRange(reason, start: start, count: endExclusive - start)
    }

    private func requestHistoryAfterLive(_ previousDataNo: Int, _ liveDataNo: Int) {
        historyGapPending = false
        guard liveDataNo > 0 else { return }
        let missingBeforeLive = liveDataNo - previousDataNo - 1
        if previousDataNo >= 0 && missingBeforeLive <= 0 { return }
        let count = previousDataNo < 0 ? liveDataNo : missingBeforeLive
        guard count > 0, count <= 0xFFFF else { return }
        let start = previousDataNo < 0 ? 0 : previousDataNo + 1
        _ = requestHistoryRange("post-live", start: start, count: count)
    }

    @discardableResult
    private func requestHistoryRange(_ reason: String, start: Int, count: Int) -> Bool {
        if start < 0 || count <= 0 || count > 0xFFFF { return false }
        let bypassCooldown = reason == "manual" || reason == "room-backfill" || reason == "initial" || reason == "ended-backfill"
        if !bypassCooldown && nowMs() - lastHistoryRequestAtMs < Self.historyRequestCooldownMs { return false }
        clearPendingHistoryRange()
        let requestCount = min(count, Self.historyRequestChunkRecords)
        let issued = issueHistoryRequest(reason, start: start, count: requestCount)
        if issued && requestCount < count {
            pendingHistoryReason = reason
            pendingHistoryNextStart = start + requestCount
            pendingHistoryEndExclusive = start + count
            trace("history chunked reason=%{public}@ start=%{public}d count=%{public}d first=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, reason, start, count, requestCount)
        }
        return issued
    }

    private func issueHistoryRequest(_ reason: String, start: Int, count: Int) -> Bool {
        guard phase == .streaming, !sessionKeyHex.isEmpty, start >= 0, count > 0 else { return false }
        let payload = shortLE(start) + shortLE(count)
        guard writeChar(OttaiConstants.charHistoryRequest, payload) else { return false }
        lastHistoryRequestAtMs = nowMs()
        if start != activeHistoryStart || start + count != activeHistoryEndExclusive { historyChunkBestDataNo = -1 }
        activeHistoryStart = start
        activeHistoryEndExclusive = start + count
        armHistoryWatchdog()
        trace("request history reason=%{public}@ start=%{public}d count=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, reason, start, count)
        return true
    }

    private func requestPendingHistoryChunk() {
        guard let reason = pendingHistoryReason else { return }
        let start = pendingHistoryNextStart
        let endExclusive = pendingHistoryEndExclusive
        let remaining = endExclusive - start
        if remaining <= 0 { clearPendingHistoryRange(); return }
        let count = min(remaining, Self.historyRequestChunkRecords)
        guard issueHistoryRequest("\(reason)-chunk", start: start, count: count) else {
            clearPendingHistoryRange()
            return
        }
        pendingHistoryNextStart = start + count
        if pendingHistoryNextStart >= endExclusive {
            pendingHistoryReason = nil
            pendingHistoryNextStart = 0
            pendingHistoryEndExclusive = 0
        }
    }

    /// Returns true while the chain is still running.
    private func continueHistoryAfterPayload(_ readings: [OttaiReading]) -> Bool {
        let activeEnd = activeHistoryEndExclusive
        if activeEnd <= 0 { return pendingHistoryReason != nil }
        guard let maxDataNo = readings.map({ $0.record.dataNo }).max() else { return false }
        if maxDataNo > historyChunkBestDataNo { historyRetryCount = 0; historyChunkBestDataNo = maxDataNo }
        if maxDataNo + 1 < activeEnd {
            armHistoryWatchdog() // only part of the block came
            return true
        }
        cancelHistoryWatchdog()
        activeHistoryEndExclusive = -1
        activeHistoryStart = -1
        if pendingHistoryReason == nil { return false }
        scheduleNextChunk()
        trace("history chunk complete through=%{public}d next=%{public}d end=%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, maxDataNo, pendingHistoryNextStart, pendingHistoryEndExclusive)
        return true
    }

    private func advanceHistoryChunkChain() {
        activeHistoryEndExclusive = -1
        activeHistoryStart = -1
        if pendingHistoryReason == nil { return }
        scheduleNextChunk()
    }

    private func scheduleNextChunk() {
        historyChunkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestPendingHistoryChunk() }
        historyChunkWork = work
        workQueue.asyncAfter(deadline: .now() + Self.historyChunkDelay, execute: work)
    }

    private func armHistoryWatchdog() {
        historyWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkHistoryWatchdog() }
        historyWatchdog = work
        workQueue.asyncAfter(deadline: .now() + Self.historyPageTimeout, execute: work)
    }

    private func cancelHistoryWatchdog() {
        historyWatchdog?.cancel()
        historyWatchdog = nil
    }

    private func checkHistoryWatchdog() {
        guard phase == .streaming, !sessionKeyHex.isEmpty else { return }
        let end = activeHistoryEndExclusive
        let start = activeHistoryStart
        if end <= 0 { return }
        if start < 0 || end <= start { historyRetryCount = 0; advanceHistoryChunkChain(); return }
        if historyRetryCount < Self.historyMaxRetries {
            historyRetryCount += 1
            trace("history page watchdog: no progress for chunk [%{public}d,%{public}d) — retry %{public}d/%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, start, end, historyRetryCount, Self.historyMaxRetries)
            if !issueHistoryRequest("watchdog-retry", start: start, count: end - start) { advanceHistoryChunkChain() }
        } else {
            trace("history page watchdog: chunk [%{public}d,%{public}d) failed after retries — skipping", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, start, end)
            historyRetryCount = 0
            advanceHistoryChunkChain()
        }
    }

    private func clearPendingHistoryRange() {
        historyChunkWork?.cancel(); historyChunkWork = nil
        cancelHistoryWatchdog()
        historyRetryCount = 0
        historyChunkBestDataNo = -1
        pendingHistoryReason = nil
        pendingHistoryNextStart = 0
        pendingHistoryEndExclusive = 0
        activeHistoryEndExclusive = -1
        activeHistoryStart = -1
    }

    // MARK: - activation (cannot be undone)

    private func activationContextIsCurrent() -> Bool {
        guard !released else { return false }
        #if DEBUG
        if lifetimeTestContext {
            guard let account = activationAccount, let checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId) else { return false }
            return checkpoint.matches(sensorID: sensorId, bluetoothID: deviceAddress ?? "", account: account)
        }
        #endif
        guard let account = activationAccount, OttaiRegistry.isCurrent(account),
              let checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId) else { return false }
        return checkpoint.matches(sensorID: sensorId, bluetoothID: deviceAddress ?? "", account: account)
    }

    /// Persist the original uncertain-write timestamp before CoreBluetooth sees the command.
    private func persistActivationCommandAttempt() -> Bool {
        guard activationContextIsCurrent(), var checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId) else { return false }
        if checkpoint.commandSentAtMs == 0 {
            checkpoint.commandSentAtMs = nowMs()
            checkpoint.commandConnectionID = connectionID
        }
        guard OttaiRegistry.saveActivationCheckpoint(checkpoint) else { return false }
        serverActivateAttemptedAtMs = checkpoint.commandSentAtMs
        activationCommandSentAtMs = checkpoint.commandSentAtMs
        return true
    }

    private func clearCommandAfterFreshInactiveRead() -> Bool {
        guard commandStatus >= 0, commandStatus < 3, activationContextIsCurrent(),
              var checkpoint = OttaiRegistry.loadActivationCheckpoint(sensorId),
              checkpoint.commandConnectionID != connectionID, !checkpoint.confirmed else { return false }
        checkpoint.commandSentAtMs = 0
        checkpoint.commandConnectionID = ""
        guard OttaiRegistry.saveActivationCheckpoint(checkpoint) else { return false }
        serverActivateAttemptedAtMs = 0
        activationCommandSentAtMs = 0
        return true
    }

    /// Android looks up the services again before the activation writes. The
    /// handles found before login gave "invalid handle" for b8fd9848 / 6aa799b6.
    /// We do the same and start the writes when all services are back.
    private func requestActivationWithRediscovery() {
        guard actStep == .none, !pendingActivation else { return }
        guard !activationHasStarted, activationContextIsCurrent(), commandStatus >= 0, commandStatus < 3 else {
            trace("activation rediscovery refused — account, selected sensor or command state changed", log: log, category: ConstantsLog.categoryCGMOttai, type: .error)
            return
        }
        #if DEBUG
        if let discovery = activationTestRediscover {
            pendingActivation = true
            discovery()
            return
        }
        #endif
        guard let peripheral = connectedPeripheral else {
            trace("activation refused — no connected peripheral", log: log, category: ConstantsLog.categoryCGMOttai, type: .error)
            return
        }
        pendingActivation = true
        rediscoveredServices.removeAll()
        expectedRediscoveryCount = 0
        trace("re-discovering services before activation", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
        // All services, like Android's gatt.discoverServices(); this also brings in the
        // destruction service (84c5b711), which the normal connection does not look up.
        peripheral.discoverServices(nil)
        afterDelay(10.0) { [weak self] in
            guard let self = self, self.pendingActivation else { return }
            // Same as Android: a discovery that does not finish means the link is bad.
            // Reconnect and try again after the next login (activationRequested stays set).
            self.pendingActivation = false
            self.activationRequested = true
            if self.serverActivating, self.serverActivationStarts >= Self.maxServerActivationStarts {
                self.giveUpServerActivation("service discovery did not finish on the last attempt")
                return
            }
            self.recoverAndReconnect("service discovery callback timeout")
        }
    }

    private func startActivationWrites() {
        guard !activationHasStarted, activationContextIsCurrent(), commandStatus >= 0, commandStatus < 3,
              activationCommandSentAtMs == 0 else {
            activationRequested = false
            activationConfirmAttempt = 0
            activationConfirmTick()
            return
        }
        guard !OttaiRegistry.hasPreparationCheckpoint(sensorId) || OttaiRegistry.loadPreparationCheckpoint(sensorId) != nil else {
            failActivation("The saved preparation checkpoint is unreadable. No activation parameters were written."); return
        }
        if let preparation = OttaiRegistry.loadPreparationCheckpoint(sensorId) {
            guard let account = activationAccount,
                  preparation.matches(sensorID: sensorId, bluetoothID: deviceAddress ?? "", account: account) else {
                failActivation("The preparation belongs to another account or Bluetooth sensor."); return
            }
        }
        if maxActiveCandidatesMs.isEmpty {
            maxActiveCandidatesMs = OttaiConstants.activationMaxActiveCandidatesMs(cloudActiveExpireMs: materials.activeExpireTimeMs)
            maxActiveCandidateIndex = 0
        }
        preparingCNFactory = activationAccount?.apiBase == OttaiConstants.apiBase
        preparingSyaiFactory = activationAccount?.apiBase == OttaiConstants.apiBaseSyai && !syaiLegacyFirmwareValidated
        if activationAccount?.apiBase == OttaiConstants.apiBaseGlobal || preparingCNFactory || preparingSyaiFactory {
            guard preparingCNFactory || preparingSyaiFactory || OttaiRegistry.loadSessionProfile() == .globalPhone else {
                failActivation("Sign in again to Global in xDrip before starting a new sensor.")
                return
            }
            readGlobalActivationFirmware()
            return
        }
        if maxActiveCandidatesMs.isEmpty {
            let cloudExpireMs = materials.activeExpireTimeMs > 0 ? materials.activeExpireTimeMs : OttaiConstants.defaultActiveExpireMs
            maxActiveCandidatesMs = OttaiConstants.activationMaxActiveCandidatesMs(cloudActiveExpireMs: cloudExpireMs)
            maxActiveCandidateIndex = 0
        }
        trace("starting activation sequence attempt=%{public}d/%{public}d", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, maxActiveCandidateIndex + 1, maxActiveCandidatesMs.count)
        actStep = .rtc
        writeRtc()
    }

    private func readGlobalActivationFirmware() {
        guard charIsReadable(OttaiConstants.charSoftwareVersion) else {
            failActivation("The sensor firmware characteristic is missing. No factory parameters were written.")
            return
        }
        actStep = .globalFirmware
        readChar(OttaiConstants.charSoftwareVersion)
        afterDelay(10) { [weak self] in
            guard let self, self.actStep == .globalFirmware || self.actStep == .globalCmdGate else { return }
            self.failActivation("Sensor firmware or state read timed out. Reconnect and retry activation.")
        }
    }

    private func buildGlobalActivationWrites() {
        do {
            var liveMaterials = materials
            liveMaterials.deviceVersion = globalActivationFirmware
            let target = maxActiveCandidatesMs.indices.contains(maxActiveCandidateIndex) ? maxActiveCandidatesMs[maxActiveCandidateIndex] : OttaiConstants.extendedLifetimeMs
            maxActiveAttemptMs = target
            let writes: [OttaiGlobalActivation.Write]
            if preparingSyaiFactory {
                guard syaiFactoryMaterialsReady(liveMaterials) else { throw OttaiPreparation.Failure.coefficients }
                let packets = try OttaiPreparation.packets(version: globalActivationFirmware, coefficients: liveMaterials.coefficient,
                    k: liveMaterials.calibrationK, b: liveMaterials.calibrationB, session: sessionKeyHex)
                writes = packets.map { packet in
                    .init(kind: packet.first == 0x0b ? .calibration : .coefficients,
                          characteristic: OttaiConstants.charDestructive, bytes: packet)
                }
                // Modern Syai uses its cloud-defined duration; the separate CN/Global
                // 30-day control is not an entitlement for a Syai sensor.
                let duration = liveMaterials.activeExpireTimeMs > 0 ? liveMaterials.activeExpireTimeMs : OttaiConstants.defaultActiveExpireMs
                guard (10 * 86_400_000...45 * 86_400_000).contains(duration), duration % 1000 == 0 else {
                    throw OttaiGlobalActivation.Failure.duration
                }
                maxActiveCandidatesMs = [duration]
                maxActiveCandidateIndex = 0
                maxActiveAttemptMs = duration
            } else {
                writes = try preparingCNFactory
                    ? OttaiCNPreparation.writes(materials: liveMaterials, sessionKeyHex: sessionKeyHex, durationMs: target).filter { $0.kind != .duration }
                    : OttaiGlobalActivation.writes(materials: liveMaterials, sessionKeyHex: sessionKeyHex, durationMs: target)
            }
            #if DEBUG
            let maximum = lifetimeTestWrite == nil ? (connectedPeripheral?.maximumWriteValueLength(for: .withResponse) ?? 0) : 512
            #else
            let maximum = connectedPeripheral?.maximumWriteValueLength(for: .withResponse) ?? 0
            #endif
            // Validate the complete plan before the first factory parameter is written.
            guard writes.allSatisfy({ frame in
                charIsWritable(frame.characteristic) && frame.bytes.count <= maximum
            }) else {
                failActivation("The sensor does not expose the required writable characteristics or Bluetooth packet capacity.")
                return
            }
            globalActivationWrites = writes
            globalActivationWriteIndex = 0
            actStep = .globalM8
            if preparingCNFactory || preparingSyaiFactory, writes.isEmpty { finishCNFactoryPreparation() }
            else { writeGlobalActivationStep() }
        } catch {
            failActivation(error.localizedDescription)
        }
    }

    private func finishCNFactoryPreparation() {
        guard preparingCNFactory || preparingSyaiFactory, commandStatus >= 0, commandStatus < 3, activationContextIsCurrent() else {
            failActivation("The factory preparation state changed. No activation was sent."); return
        }
        if var preparation = OttaiRegistry.loadPreparationCheckpoint(sensorId) {
            guard preparation.materialsSaved else { failActivation("Factory Bluetooth materials are missing."); return }
            preparation.factoryComplete = true
            guard OttaiRegistry.savePreparationCheckpoint(preparation) else {
                failActivation("Could not save factory preparation completion."); return
            }
        }
        globalActivationWrites = []
        actStep = .rtc
        writeRtc()
    }

    private func writeGlobalActivationStep() {
        guard !activationHasStarted, activationContextIsCurrent(), commandStatus >= 0, commandStatus < 3,
              globalActivationWrites.indices.contains(globalActivationWriteIndex) else {
            failActivation("Activation account, selected sensor or command state changed.")
            return
        }
        let frame = globalActivationWrites[globalActivationWriteIndex]
        if frame.kind == .duration {
            if var checkpoint = OttaiRegistry.loadPreparationCheckpoint(sensorId) {
                guard checkpoint.materialsSaved else { failActivation("Prepared sensor materials are missing."); return }
                checkpoint.factoryComplete = true
                guard OttaiRegistry.savePreparationCheckpoint(checkpoint) else { failActivation("Could not save factory preparation completion."); return }
            }
            beginActivationLifetime(maxActiveAttemptMs)
            return
        }
        if frame.kind == .activate, !persistActivationCommandAttempt() {
            failActivation("Could not save the activation checkpoint. No activation command was sent.")
            return
        }
        guard writeChar(frame.characteristic, frame.bytes) else {
            failActivation("The sensor refused a required activation parameter.")
            return
        }
    }

    private func advanceGlobalActivation(acknowledgedUUID: String) {
        guard globalActivationWrites.indices.contains(globalActivationWriteIndex), activationContextIsCurrent() else { return }
        let frame = globalActivationWrites[globalActivationWriteIndex]
        guard frame.characteristic.caseInsensitiveCompare(acknowledgedUUID) == .orderedSame else { return }
        if frame.kind == .activate {
            globalActivationWrites = []
            actStep = .done
            markActivationCommandSent()
            return
        }
        globalActivationWriteIndex += 1
        if preparingCNFactory || preparingSyaiFactory, globalActivationWriteIndex == globalActivationWrites.count { finishCNFactoryPreparation() }
        else { writeGlobalActivationStep() }
    }

    private func advanceActivation(acknowledgedUUID: String? = nil) {
        guard (commandStatus >= 0 && commandStatus < 3) || actStep == .command || actStep == .done else {
            failActivation("The sensor is no longer inactive. No further activation parameters were sent."); return
        }
        guard activationContextIsCurrent() else {
            failActivation("activation account or selected sensor changed")
            return
        }
        if let acknowledgedUUID {
            let expected: String?
            switch actStep {
            case .rtc: expected = OttaiConstants.charCurrentTime
            case .maxActive: expected = OttaiConstants.charMaxActiveTime
            case .destruction: expected = OttaiConstants.charDestructive
            case .command: expected = OttaiConstants.charCommand
            default: expected = nil
            }
            guard expected?.caseInsensitiveCompare(acknowledgedUUID) == .orderedSame else { return }
        }
        switch actStep {
        case .rtc: actStep = .maxActive; writeMaxActiveTime()
        case .maxActive: actStep = .destruction; writeDestructionTime()
        case .destruction: actStep = .command; writeActivateCmd()
        case .command: actStep = .done; markActivationCommandSent()
        default: break
        }
    }

    private func writeRtc() {
        guard commandStatus >= 0, commandStatus < 3, activationContextIsCurrent() else {
            failActivation("The sensor is no longer inactive. No clock write was sent."); return
        }
        let secs = Int32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970))
        if !writeChar(OttaiConstants.charCurrentTime, OttaiBleAuth.intToBytesLE(secs)) {
            failActivation("RTC characteristic is unavailable")
        }
    }

    private func writeMaxActiveTime() {
        guard maxActiveCandidatesMs.indices.contains(maxActiveCandidateIndex) else {
            failActivation("No supported lifetime candidate remains."); return
        }
        maxActiveAttemptMs = maxActiveCandidatesMs[maxActiveCandidateIndex]
        beginActivationLifetime(maxActiveAttemptMs)
    }

    /// The sensor said no to this lifetime. Try the next shorter one on a new connection.
    private func retryMaxActiveTime() -> Bool {
        let nextIndex = maxActiveCandidateIndex + 1
        guard maxActiveCandidatesMs.indices.contains(nextIndex) else { return false }
        trace("maxActive rejected duration=%{public}ds; will reconnect and retry %{public}ds", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, Int(maxActiveAttemptMs / 1000), Int(maxActiveCandidatesMs[nextIndex] / 1000))
        lifetimeTransaction = nil
        lifetimeReadOwner = nil
        lifetimeReadsBlocked = true
        maxActiveCandidateIndex = nextIndex
        maxActiveAttemptMs = 0
        actStep = .none
        activationRequested = true
        afterDelay(0.2) { [weak self] in self?.disconnect() }
        return true
    }


    private func writeDestructionTime() {
        guard commandStatus >= 0, commandStatus < 3, activationContextIsCurrent() else {
            failActivation("The sensor is no longer inactive. No retain parameter was written."); return
        }
        // retainTime is a short DURATION, not a date. Writing a date made the sensor drop the link.
        let retainMs = materials.retainTimeMs > 0 ? materials.retainTimeMs : OttaiConstants.defaultRetainTimeMs
        let payload = longToBytesLE(retainMs / 1000) + [0x04]
        if !writeChar(OttaiConstants.charDestructive, payload) {
            failActivation("destruction characteristic is unavailable")
        }
    }

    private func writeActivateCmd() {
        guard !activationHasStarted, commandStatus >= 0, commandStatus < 3, activationContextIsCurrent() else {
            failActivation("The sensor is no longer inactive. No activation command was sent."); return
        }
        guard let cmd = OttaiCrypto.encryptActivateCmd([OttaiConstants.activateCmd], sessionKeyHex: sessionKeyHex) else {
            failActivation("activation command encryption failed"); return
        }
        guard persistActivationCommandAttempt() else {
            failActivation("could not persist activation command checkpoint"); return
        }
        if !writeChar(OttaiConstants.charCommand, cmd) {
            failActivation("activation command characteristic is unavailable")
        }
    }

    private func markActivationCommandSent() {
        guard activationCommandSentAtMs > 0 else {
            failActivation("activation command checkpoint is missing"); return
        }
        maxActiveCandidatesMs = []
        maxActiveCandidateIndex = 0
        // The ACK records a sent attempt, not physical activation. The durable
        // checkpoint survives failure/restart until a fresh command-status read.
        OttaiRegistry.setActivationAttempted(sensorId, true)
        activationRequested = false
        if materials.activeTimeMs <= 0 { setProvisionalActiveTime(activationCommandSentAtMs, "activation-command") }
        reportSensorSessionIfNeeded()
        trace("activation command sent; sensor accepted activation writes", log: log, category: ConstantsLog.categoryCGMOttai, type: .info)
        // Check that the activation worked. Send nothing else in the meantime (only one
        // Bluetooth operation at a time).
        activationConfirmAttempt = 0
        afterDelay(Self.postActivationConfirmDelay) { [weak self] in self?.activationConfirmTick() }
    }

    private func activationConfirmTick() {
        if commandStatus == 3 { return }
        if activationConfirmAttempt >= Self.postActivationConfirmMaxAttempts {
            failActivation("Activation is not yet confirmed. Reconnecting to read the sensor state; do not start it again.")
            recoverAndReconnect("activation confirmation timed out")
            return
        }
        activationConfirmAttempt += 1
        readChar(OttaiConstants.charCommand)
        afterDelay(Self.postActivationConfirmRetry) { [weak self] in self?.activationConfirmTick() }
    }

    private func adoptActivatedMaxActive(_ ms: Int64, evidence: OttaiRegistry.LifetimeEvidence) {
        guard OttaiConstants.sanitizeActiveExpireMs(ms) > 0 else { return }
        // A matching read-back still upgrades provenance; do not skip equal values.
        activatedMaxActiveMs = ms
        OttaiRegistry.saveAcceptedMaxActive(sensorId, ms, evidence: evidence)
        trace("lifetime parameter = %{public}dd source=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, Int(ms / 86_400_000), evidence.rawValue)
    }

    private func failActivation(_ reason: String) {
        trace("activation failed: %{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, reason)
        actStep = .none
        pendingActivation = false
        activationRequested = false
        OttaiRegistry.setActivationAttempted(sensorId, false)
        maxActiveCandidatesMs = []
        maxActiveCandidateIndex = 0
        globalActivationWrites = []
        OttaiRegistry.saveActivationStatus(sensorId, reason)
    }

    // MARK: - Bluetooth helpers

    private func readLiveGlucose(_ reason: String) {
        guard !sessionKeyHex.isEmpty else { return }
        trace("read live glucose reason=%{public}@", log: log, category: ConstantsLog.categoryCGMOttai, type: .info, reason)
        liveReadInFlight = true
        readChar(OttaiConstants.charGlucoseLive)
    }

    private func readChar(_ characteristic: String) {
        if characteristic == OttaiConstants.charCommand { commandReadOutstanding = true }
        #if DEBUG
        if let hook = lifetimeTestRead { hook(characteristic); return }
        #endif
        guard let ch = char(characteristic) else {
            trace("read skipped: characteristic %{public}@ not discovered", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, String(characteristic.prefix(8)))
            return
        }
        readValueForCharacteristic(for: ch)
    }

    @discardableResult
    private func writeChar(_ characteristic: String, _ value: [UInt8]) -> Bool {
        #if DEBUG
        if let hook = lifetimeTestWrite { return hook(characteristic, value) }
        #endif
        guard let ch = char(characteristic) else {
            trace("write skipped: characteristic %{public}@ not discovered", log: log, category: ConstantsLog.categoryCGMOttai, type: .error, String(characteristic.prefix(8)))
            return false
        }
        return writeDataToPeripheral(data: Data(value), characteristicToWriteTo: ch, type: .withResponse)
    }

    override func prepareForRelease() {
        delivery.release()
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.released = true
            self.connectionGeneration += 1
            self.interruptLifetimeOperation()
            self.connectedPeripheral = nil
            self.characteristics.removeAll()
            self.phase = .idle
            self.actStep = .none
            self.pendingActivation = false
            self.activationRequested = false
            self.sessionKeyHex = ""
            self.livePollTimer?.cancel()
            self.livePollTimer = nil
            self.clearPendingHistoryRange()
        }
        super.prepareForRelease()
    }

    #if DEBUG
    /// File-local protocol seams. Tests supply a transport only; all advancement,
    /// persistence and reply handling still runs through the production methods.
    func configureLifetimeTest(sessionKeyHex: String, account: OttaiAccountContext) {
        workQueue.sync {
            lifetimeTestContext = true
            self.sessionKeyHex = sessionKeyHex
            lifetimeAccount = account
            activationAccount = account
            authKeys = [[UInt8](repeating: 0, count: 16)]
            phase = .streaming
            authStep = .done
        }
    }

    func beginLifetimeTest(activation: Bool, targetMs: Int64 = OttaiConstants.extendedLifetimeMs) {
        workQueue.sync {
            if activation {
                commandStatus = 2
                actStep = .maxActive
                maxActiveAttemptMs = targetMs
                beginActivationLifetime(targetMs)
            } else { beginActiveLifetimeOperation() }
        }
    }

    func beginActivationTransportTest(global: Bool, materials: OttaiRegistry.DeviceMaterials) throws {
        try workQueue.sync {
            self.materials = materials
            commandStatus = 2
            maxActiveCandidatesMs = [OttaiConstants.extendedLifetimeMs]
            maxActiveCandidateIndex = 0
            maxActiveAttemptMs = OttaiConstants.extendedLifetimeMs
            if global {
                globalActivationWrites = try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: sessionKeyHex,
                    durationMs: OttaiConstants.extendedLifetimeMs)
                globalActivationWriteIndex = 0
                actStep = .globalM8
                writeGlobalActivationStep()
            } else {
                actStep = .rtc
                writeRtc()
            }
        }
    }

    func prepareLegacySyaiColdStartTest() {
        workQueue.sync {
            activationAccount = nil
            authKeys = nil
            materials.keyAHex = ""
            phase = .idle
            commandStatus = 2
        }
    }

    func beginLegacySyaiAuthenticationTest(material: OttaiCloudClient.V3AuthMaterial) {
        workQueue.sync {
            guard usesLegacySyaiServerActivation else { return }
            authKeys = nil
            serverActivating = true
            phase = .auth
            sessionKeyHex = ""
            applyServerAuthentication(material)
        }
    }

    func beginPreparationProofTest() {
        workQueue.sync {
            authKeys = nil
            serverActivating = true
            phase = .auth
            serverAuthFlagBytes = [UInt8](repeating: 1, count: 32)
            authStep = .writeAppSign
            sessionKeyHex = ""
            handleWriteAck(uuid: OttaiConstants.charAuthSign)
        }
    }

    func finishActivationDiscoveryTest() {
        workQueue.sync {
            guard pendingActivation else { return }
            pendingActivation = false
            if serverActivating {
                if usesLegacySyaiServerActivation { startServerActivationWrites() }
                else { readServerFirmware() }
            } else { startActivationWrites() }
        }
    }

    func finishPreparationDiscoveryTest() {
        workQueue.sync {
            guard pendingActivation, serverActivating else { return }
            pendingActivation = false
            readServerFirmware()
        }
    }

    func resumeActivationTransportTest(materials: OttaiRegistry.DeviceMaterials) {
        workQueue.sync {
            self.materials = materials
            commandStatus = 2
            actStep = .none
            startActivationWrites()
        }
    }

    func receiveLifetimeTest(uuid: String, value: [UInt8]) {
        workQueue.sync { handleValue(uuid: uuid, value: value) }
    }

    func acknowledgeLifetimeTest(uuid: String) {
        workQueue.sync { handleWriteAck(uuid: uuid) }
    }

    func failLifetimeTest() {
        workQueue.sync { failLifetimeOperation("The lifetime operation timed out. Reconnect and read its result; no activation was sent.") }
    }

    func disconnectLifetimeTest() { workQueue.sync { resetConnectionState() } }

    struct StreamingTestSnapshot {
        let lastLiveNotifyAtMs: Int64
        let lastLiveFrameAtMs: Int64
        let streamStartTimeMs: Int64
        let acceptedLiveTimes: [Int: Int64]
        let confirmedActiveTimeMs: Int64
        let learnedRecordSize: Int
    }

    /// Only supplies a deterministic transport state; encrypted frames still enter
    /// handleValue/handleGlucosePayload and the production acceptance pipeline.
    func configureStreamingTest(materials: OttaiRegistry.DeviceMaterials) {
        workQueue.sync {
            self.materials = materials
            authKeys = materials.authKeys
            phase = .streaming
            commandStatus = 3
            authStep = .done
            initialFlushDone = true
            initialHistoryRequested = true
            liveReadInFlight = false
        }
    }

    func streamingTestSnapshot() -> StreamingTestSnapshot {
        workQueue.sync {
            StreamingTestSnapshot(lastLiveNotifyAtMs: lastLiveNotifyAtMs, lastLiveFrameAtMs: lastLiveFrameAtMs,
                streamStartTimeMs: streamStartTimeMs, acceptedLiveTimes: acceptedLiveTimes,
                confirmedActiveTimeMs: materials.activeTimeMs, learnedRecordSize: learnedRecordSize)
        }
    }

    func pollStreamingTest() {
        workQueue.sync { livePollFired() }
    }
    #endif

    // MARK: - small helpers

    private func nowMs() -> Int64 {
        #if DEBUG
        if let clock = streamingTestNow { return clock() }
        #endif
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
    private func shortLE(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func longToBytesLE(_ v: Int64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8)
        for i in 0 ..< 8 { out[i] = UInt8((v >> (i * 8)) & 0xFF) }
        return out
    }
}

private extension CBUUID {
    /// The full 128-bit UUID as lower-case text, so short (16-bit) and long forms compare equal.
    var full128: String {
        let s = uuidString.lowercased()
        switch s.count {
        case 4: return "0000\(s)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(s)-0000-1000-8000-00805f9b34fb"
        default: return s
        }
    }
}
