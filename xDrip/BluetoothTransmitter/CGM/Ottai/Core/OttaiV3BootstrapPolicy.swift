//
//  OttaiV3BootstrapPolicy.swift
//  xdrip
//
//  Ottai / Syai CGM driver — how a connection starts when the sensor has no keyA yet.
//

import Foundation

/// Use the same next step in the setup screen and its button handlers.
enum OttaiSetupStep: Equatable {
    case enterID, signIn, fetch, connect, activate, starting, finishingSetup, active, ended
    case warmup(minutes: Int)

    static func resolve(sensorID: String, signedIn: Bool, hasKeys: Bool, bootstrapPending: Bool,
                        pendingBind: Bool, activationRequested: Bool, activationStarted: Bool,
                        commandStatus: Int, savedCommandStatus: Int, startMs: Int64, nowMs: Int64,
                        preheatPeriodMs: Int64 = OttaiConstants.defaultPreheatPeriodMs) -> Self {
        guard OttaiConstants.looksLikeMac(sensorID) else { return .enterID }
        if commandStatus >= 4 || savedCommandStatus >= 4 { return .ended }
        if pendingBind { return signedIn ? .finishingSetup : .signIn }
        if activationStarted || commandStatus == 3 || savedCommandStatus == 3 {
            let warmupMs = max(OttaiConstants.warmupSuppressMs, preheatPeriodMs)
            if startMs > 0, nowMs < startMs + warmupMs {
                let remaining = min(warmupMs, startMs + warmupMs - nowMs)
                return .warmup(minutes: Int((remaining + 59_999) / 60_000))
            }
            return .active
        }
        if !hasKeys && !signedIn { return .signIn }
        if !hasKeys && !bootstrapPending { return .fetch }
        if activationRequested { return .starting }
        if hasKeys && commandStatus < 0 { return .connect }
        return .activate
    }

    var title: String {
        switch self {
        case .enterID: return "Add sensor"
        case .signIn: return "Sign in"
        case .fetch: return "Set up sensor"
        case .connect: return "Connect to sensor"
        case .activate: return "Start sensor"
        case .starting: return "Starting sensor…"
        case .finishingSetup: return "Finish sensor setup"
        case .warmup: return "Sensor warming up"
        case .active: return "Sensor active"
        case .ended: return "Sensor ended"
        }
    }

    var detail: String {
        switch self {
        case .enterID: return "Enter the ID from the sensor box."
        case .signIn: return "Use the account for your sensor region."
        case .fetch: return "Get the settings for this sensor."
        case .connect: return "Check the sensor before starting it."
        case .activate: return "Put the sensor on before starting."
        case .starting: return "Keep the phone nearby. Do not start again."
        case .finishingSetup: return "The sensor has started. Tap to retry setup."
        case .warmup(let minutes): return "About \(minutes) min left. No action needed."
        case .active: return "No action needed."
        case .ended: return "Replace the sensor to continue."
        }
    }

    var hasAction: Bool {
        switch self {
        case .starting, .warmup, .active, .ended: return false
        default: return true
        }
    }
}

/// A running sensor must never receive another activation sequence.
func ottaiCanWriteActivation(commandStatus: Int, activationStarted: Bool) -> Bool {
    (0...2).contains(commandStatus) && !activationStarted
}

enum OttaiAuthEntryMode {
    case storedMaterialAuth
    /// Activated through the server; only the bind (which gives keyA) is missing.
    case awaitingBind
    /// New sensor, the user asked to activate it: the server answers the login.
    case serverAssistedActivation
    case blocked
}

/// A sensor without keyA is only touched when the user asked for activation, the V3
/// check marked it (`bootstrapPending`) and the login is still there.
func ottaiAuthEntryMode(
    hasAuthKeys: Bool,
    pendingBind: Bool,
    bootstrapPending: Bool,
    sessionAvailable: Bool,
    activationRequested: Bool
) -> OttaiAuthEntryMode {
    if hasAuthKeys { return .storedMaterialAuth }
    if pendingBind { return .awaitingBind }
    if bootstrapPending, sessionAvailable, activationRequested { return .serverAssistedActivation }
    return .blocked
}

/// Durable intent is distinct from a confirmed activation. An acknowledged GATT write
/// alone must never send an unconfirmed sensor to cloud bind or reset its start time.
struct OttaiActivationAttempt: Codable, Equatable {
    let sensorID: String
    let bluetoothID: String
    let apiBase: String
    let userID: String
    let authorizedAtMs: Int64
    var commandSentAtMs: Int64 = 0
    var commandConnectionID = ""
    var confirmed = false

    func matches(sensorID: String, bluetoothID: String, account: OttaiAccountContext) -> Bool {
        self.sensorID == OttaiConstants.canonicalSensorId(sensorID)
            && self.bluetoothID.caseInsensitiveCompare(bluetoothID) == .orderedSame
            && apiBase == account.apiBase && userID == account.userId
    }

    var isValid: Bool {
        OttaiConstants.looksLikeMac(sensorID) && UUID(uuidString: bluetoothID) != nil
            && !apiBase.isEmpty && !userID.isEmpty && authorizedAtMs > 0
            && commandSentAtMs >= 0 && (!confirmed || commandSentAtMs > 0)
            && (commandSentAtMs == 0 || UUID(uuidString: commandConnectionID) != nil)
    }
}

enum OttaiActivationGate: Equatable {
    case readStatus
    case writeFrames
    case confirmOnly
    /// A different authenticated BLE connection freshly read cmd 0...2. The old
    /// connection cannot deliver its command now, so the authorized attempt may resume.
    case retryConfirmedInactive
    case bind(startMs: Int64)
    case alreadyActive
    case ended

    static func decide(commandStatus: Int, commandSentAtMs: Int64, commandFromCurrentConnection: Bool = true) -> Self {
        if commandStatus < 0 { return .readStatus }
        if commandStatus >= 4 { return .ended }
        if commandStatus == 3 {
            return commandSentAtMs > 0 ? .bind(startMs: commandSentAtMs) : .alreadyActive
        }
        // A command may have landed even without its callback. Read back, do not
        // repeat coefficient/RTC/duration writes during this uncertain state.
        if commandSentAtMs > 0 { return commandFromCurrentConnection ? .confirmOnly : .retryConfirmedInactive }
        return .writeFrames
    }
}

/// Shared by the real GATT writer and its interruption tests.
enum OttaiServerActivationWrite: Int, CaseIterable {
    case coefficient, duration, rtc, activate

    var characteristic: String {
        switch self {
        case .coefficient: return OttaiConstants.charDestructive
        case .duration: return OttaiConstants.charMaxActiveTime
        case .rtc: return OttaiConstants.charCurrentTime
        case .activate: return OttaiConstants.charCommand
        }
    }

    var next: Self? { Self(rawValue: rawValue + 1) }
}

/// Provisioning frames from the Global M8 SDK 1.38.0. Kept separate from the
/// older CN/Syai activation sequence: its retain-time write is not a Global step.
enum OttaiGlobalActivation {
    static let defaultActiveExpireMs: Int64 = 14 * 24 * 3600 * 1000
    enum Failure: String, Error, LocalizedError {
        case firmware = "This Global firmware has no verified activation protocol in this build."
        case coefficients = "The new sensor's factory coefficients are missing or invalid. Fetch them again before activation."
        case calibration = "This sensor requires factory calibration K/B. The cloud did not provide them. No activation was attempted."
        case duration = "The sensor lifetime is missing or invalid."
        case encryption = "The Bluetooth session key is not available for activation."
        var errorDescription: String? { rawValue }
    }

    enum Kind: Equatable { case coefficients, calibration, duration, rtc, activate }
    struct Write: Equatable {
        let kind: Kind
        let characteristic: String
        let bytes: [UInt8]
    }

    static func firmwareMinor(_ version: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"V1\.([0-9]+)\."#) else { return nil }
        let matches = regex.matches(in: version, range: NSRange(version.startIndex..., in: version))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: version),
              ["6", "7", "8"].contains(String(version[range])), let minor = Int(version[range]) else { return nil }
        return minor
    }

    /// The Global bind API expects the live SDK software version, including its
    /// E...(V1...) wrapper. Only the comma suffix is removed by the official reader.
    static func bindFirmware(_ raw: String) -> String? {
        let version = String(raw.split(separator: ",", omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return firmwareMinor(version) == nil ? nil : version
    }

    static func preflight(materials: OttaiRegistry.DeviceMaterials) throws {
        guard let minor = firmwareMinor(materials.deviceVersion) else { throw Failure.firmware }
        guard materials.coefficient.split(separator: ",", omittingEmptySubsequences: false).count == materials.coefficients.count else { throw Failure.coefficients }
        _ = try coefficientFrame(materials.coefficients)
        if minor == 8 {
            guard let k = materials.calibrationValueK, let b = materials.calibrationValueB,
                  k.isFinite, b.isFinite else { throw Failure.calibration }
        }
        _ = try totalDurationMs(materials)
    }

    static func coefficientFrame(_ coefficients: [Double]) throws -> [UInt8] {
        guard (1...255).contains(coefficients.count), coefficients.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw Failure.coefficients }
        var bytes: [UInt8] = [0x09, UInt8(coefficients.count)]
        for value in coefficients {
            let bits = Float(value).bitPattern
            bytes += (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        }
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return bytes + [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
    }

    static func writes(materials: OttaiRegistry.DeviceMaterials, sessionKeyHex: String, durationMs: Int64? = nil) throws -> [Write] {
        try preflight(materials: materials)
        guard let minor = firmwareMinor(materials.deviceVersion) else { throw Failure.firmware }
        var result = [Write(kind: .coefficients, characteristic: OttaiConstants.charDestructive,
                            bytes: try coefficientFrame(materials.coefficients))]
        if minor == 8 {
            guard let k = materials.calibrationValueK, let b = materials.calibrationValueB,
                  k.isFinite, b.isFinite else { throw Failure.calibration }
            let plain = [k, b].flatMap { value in (0..<8).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) } }
            guard let cipher = OttaiCrypto.encryptPayload(plain, sessionKeyHex: sessionKeyHex) else { throw Failure.encryption }
            result.append(Write(kind: .calibration, characteristic: OttaiConstants.charDestructive, bytes: [0x0b] + cipher))
        }
        let duration = try durationMs ?? totalDurationMs(materials)
        if durationMs != nil, !(10 * 86_400_000...OttaiConstants.extendedLifetimeMs).contains(duration) { throw Failure.duration }
        let seconds = duration / 1000
        guard seconds > 0, seconds <= Int64(UInt32.max), duration % 1000 == 0 else { throw Failure.duration }
        let durationBytes = (0..<4).map { UInt8(truncatingIfNeeded: UInt32(seconds) >> ($0 * 8)) }
        guard let encryptedDuration = OttaiCrypto.encryptPayload(durationBytes, sessionKeyHex: sessionKeyHex),
              let activate = OttaiCrypto.encryptActivateCmd([0x03], sessionKeyHex: sessionKeyHex) else { throw Failure.encryption }
        result += [Write(kind: .duration, characteristic: OttaiConstants.charMaxActiveTime, bytes: encryptedDuration),
                   Write(kind: .rtc, characteristic: OttaiConstants.charCurrentTime, bytes: [0, 0, 0, 0]),
                   Write(kind: .activate, characteristic: OttaiConstants.charCommand, bytes: activate)]
        return result
    }

    static func totalDurationMs(_ materials: OttaiRegistry.DeviceMaterials) throws -> Int64 {
        // Missing Global metadata is defaulted when authInfo is decoded (14d/0/0).
        // Explicit invalid/zero expiry must never silently become the CN 15d default.
        guard materials.activeExpireTimeMs > 0 else { throw Failure.duration }
        let parts = [materials.activeExpireTimeMs, materials.preheatPeriodMs, materials.gracePeriodMs]
        var total: Int64 = 0
        for part in parts {
            guard part >= 0 else { throw Failure.duration }
            let sum = total.addingReportingOverflow(part)
            guard !sum.overflow else { throw Failure.duration }
            total = sum.partialValue
        }
        guard total > 0, total % 1000 == 0, total / 1000 <= Int64(UInt32.max) else { throw Failure.duration }
        return total
    }
}


/// One duration operation, used by the BLE runtime and interruption tests. It emits no
/// RTC, retain, activation or cloud effects. Confirmation means parameter read-back,
/// never a claim that the firmware's expiry loop will actually run for that long.
struct OttaiLifetimeTransaction {
    enum Mode: Equatable { case activation, extendActive, reconcile }
    enum Stage: Equatable { case freshStatus, baseline, write, readback, finalStatus, complete, failed }
    enum Effect: Equatable {
        case none, readStatus, readDuration, persistAndWrite, activationVerified(Int64)
        case activeVerified(Int64, wrote: Bool), failed(String)
    }
    let id = UUID().uuidString
    let mode: Mode
    let targetMs: Int64
    private(set) var stage: Stage
    private(set) var wrote = false
    private var observedMs: Int64 = 0

    init(mode: Mode, targetMs: Int64 = OttaiConstants.extendedLifetimeMs) {
        self.mode = mode
        self.targetMs = targetMs
        stage = mode == .activation ? .write : .freshStatus
    }

    var firstEffect: Effect { mode == .activation ? .persistAndWrite : .readStatus }
    var isPending: Bool { stage != .complete && stage != .failed }

    mutating func status(_ status: Int) -> Effect {
        guard stage == .freshStatus || stage == .finalStatus else { return .none }
        guard status == 3 else { return fail("The sensor is not active (status \(status)). No activation or restart was sent.") }
        if stage == .freshStatus { stage = .baseline; return .readDuration }
        stage = .complete
        return .activeVerified(observedMs, wrote: wrote)
    }

    mutating func duration(_ ms: Int64?) -> Effect {
        guard stage == .baseline || stage == .readback else { return .none }
        guard let ms, OttaiConstants.sanitizeActiveExpireMs(ms) > 0 else {
            return fail("Could not decode the sensor lifetime. Reconnect and read it again; activation was not sent.")
        }
        if stage == .baseline {
            observedMs = ms
            if mode == .reconcile || ms >= targetMs { stage = .finalStatus; return .readStatus }
            stage = .write
            return .persistAndWrite
        }
        guard ms == targetMs else { return fail("Lifetime read-back differs from the requested value. No activation was sent; read the sensor again before retrying.") }
        observedMs = ms
        if mode == .activation { stage = .complete; return .activationVerified(ms) }
        stage = .finalStatus
        return .readStatus
    }

    mutating func writeIssued() { if stage == .write { wrote = true } }
    mutating func acknowledged() -> Effect {
        guard stage == .write, wrote else { return .none }
        stage = .readback
        return .readDuration
    }
    mutating func fail(_ message: String) -> Effect {
        guard isPending else { return .none }
        stage = .failed
        return .failed(message)
    }

    /// The known wire forms are LE32/LE64 plaintext, or exactly one AES block.
    /// A failed decrypt must never turn ciphertext into a plaintext duration.
    static func decode(_ value: [UInt8], sessionKeyHex: String) -> Int64? {
        let plain: [UInt8]
        if value.count == 4 || value.count == 8 { plain = value }
        else if value.count == 16, let key = try? OttaiCrypto.hexToBytesStrict(sessionKeyHex), key.count == 16,
                // decryptPayload trims a zero 8-byte trailer for glucose records.
                // Lifetime validation needs the entire block to verify padding.
                let decoded = OttaiCrypto.aesECB(.decrypt, key: key, data: value, pkcs7Padded: false), decoded.count == 16,
                decoded.dropFirst(8).allSatisfy({ $0 == 0 }) { plain = Array(decoded.prefix(8)) }
        else { return nil }
        var seconds: UInt64 = 0
        for (index, byte) in plain.enumerated() { seconds |= UInt64(byte) << (index * 8) }
        guard seconds >= 10 * 86_400, seconds <= 45 * 86_400 else { return nil }
        return Int64(seconds) * 1000
    }
}

/// Saved before an active lifetime write. A remaining intent only permits read-only
/// reconciliation after a crash/disconnect; it never authorizes an automatic replay.
struct OttaiLifetimeIntent: Codable, Equatable {
    let sensorID: String
    let bluetoothID: String
    let apiBase: String
    let userID: String
    let targetMs: Int64
    let requestedAtMs: Int64

    func matches(sensorID: String, bluetoothID: String, account: OttaiAccountContext) -> Bool {
        self.sensorID == OttaiConstants.canonicalSensorId(sensorID)
            && self.bluetoothID.caseInsensitiveCompare(bluetoothID) == .orderedSame
            && self.apiBase == account.apiBase && self.userID == account.userId
    }
}


/// Fresh-sensor provisioning is not physical activation. The bind checkpoint is
/// durable before POST; a saved key alone cannot skip incomplete factory writes.
struct OttaiPreparationCheckpoint: Codable, Equatable {
    let sensorID: String
    let bluetoothID: String
    let apiBase: String
    let userID: String
    let authorizedAtMs: Int64
    var liveFirmware = ""
    var bindAttempted = false
    var materialsSaved = false
    var storedMaterials = false
    var factoryComplete = false
    var confirmedStartMs: Int64 = 0

    func matches(sensorID: String, bluetoothID: String, account: OttaiAccountContext) -> Bool {
        self.sensorID == OttaiConstants.canonicalSensorId(sensorID)
            && self.bluetoothID.caseInsensitiveCompare(bluetoothID) == .orderedSame
            && self.apiBase == account.apiBase && self.userID == account.userId
    }
}


/// Fresh CN preparation shares the modern factory frame format, but older V1.4/5
/// have no factory writes. Its later RTC/retain sequence remains the CN sequence.
enum OttaiCNPreparation {
    static func firmwareMinor(_ version: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"V1\.([0-9]+)\."#) else { return nil }
        let matches = regex.matches(in: version, range: NSRange(version.startIndex..., in: version))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: version),
              let minor = Int(version[range]), (4...8).contains(minor) else { return nil }
        return minor
    }

    static func preflight(materials: OttaiRegistry.DeviceMaterials) throws {
        guard let minor = firmwareMinor(materials.deviceVersion) else { throw OttaiGlobalActivation.Failure.firmware }
        if minor >= 6 { try OttaiGlobalActivation.preflight(materials: materials) }
    }

    static func writes(materials: OttaiRegistry.DeviceMaterials, sessionKeyHex: String, durationMs: Int64) throws -> [OttaiGlobalActivation.Write] {
        try preflight(materials: materials)
        guard let minor = firmwareMinor(materials.deviceVersion) else { throw OttaiGlobalActivation.Failure.firmware }
        if minor >= 6 {
            return try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: sessionKeyHex, durationMs: durationMs)
                .filter { $0.kind != .rtc && $0.kind != .activate }
        }
        guard (10 * 86_400_000...OttaiConstants.extendedLifetimeMs).contains(durationMs), durationMs % 1000 == 0 else { throw OttaiGlobalActivation.Failure.duration }
        let seconds = UInt64(durationMs / 1000)
        let plain = (0..<8).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) }
        guard let encrypted = OttaiCrypto.encryptPayload(plain, sessionKeyHex: sessionKeyHex) else { throw OttaiGlobalActivation.Failure.encryption }
        return [.init(kind: .duration, characteristic: OttaiConstants.charMaxActiveTime, bytes: encrypted)]
    }
}

enum OttaiServerAuthRecovery: Equatable {
    case stop
    case retryConnection
    case scanNextSensor
}

/// An old sensor can advertise the same name as the replacement. Its challenge
/// cannot be verified against the replacement's Cloud ID. Retry with a fresh
/// challenge once before excluding that Bluetooth device for this transmitter.
func ottaiServerAuthRecovery(code: String, signatureFailures: Int, activateSent: Bool) -> OttaiServerAuthRecovery {
    guard !activateSent, code == "DEVICE_AUTH_SIGN_ERROR" else { return .stop }
    return signatureFailures >= 2 ? .scanNextSensor : .retryConnection
}

/// Move the live start time back only when two accepted readings agree.
struct OttaiArrivalStartCorrection {
    private var lowest: Int64 = 0
    private var latestArrival: Int64 = 0
    private var pending: (start: Int64, counter: Int, received: Int64)?

    mutating func seed(start: Int64, arrivalStart: Int64) {
        lowest = start - 60_000
        latestArrival = max(0, arrivalStart)
        pending = nil
    }

    mutating func accept(anchor: Int64, counter: Int, received: Int64) -> Int64? {
        guard anchor > 0, counter >= 0, received > 0 else {
            pending = nil
            return nil
        }
        let implied = received - Int64(counter) * 60_000
        if latestArrival > 0 { latestArrival = max(latestArrival, implied) }
        guard implied < anchor else {
            pending = nil
            return nil
        }
        guard let previous = pending, counter > previous.counter,
              received > previous.received, received - previous.received <= 180_000,
              abs(previous.start - implied) <= 60_000 else {
            pending = (implied, counter, received)
            return nil
        }
        pending = nil
        let agreed = max(previous.start, implied)
        guard lowest > 0, latestArrival > 0, agreed >= max(lowest, latestArrival - 120_000) else { return nil }
        return agreed
    }
}

/// Build factory settings before sending any activation commands.
enum OttaiPreparation {
    enum Failure: Error { case firmware, coefficients, calibration }

    static func minor(_ version: String) -> Int? {
        guard let range = version.range(of: "V1.", options: .caseInsensitive) else { return nil }
        return Int(version[range.upperBound...].prefix { $0.isNumber })
    }
    static func versionMatches(_ sensor: String, _ cloud: String) -> Bool {
        let a = sensor.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = cloud.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if a.contains("("), b.contains("(") {
            return (!a.contains(",") || !b.contains(",")) && a.split(separator: ",").first == b.split(separator: ",").first
        }
        return OttaiCloudClient.deviceVersion(fromFirmware: a) == b || OttaiCloudClient.deviceVersion(fromFirmware: b) == a
    }
    static func packets(version: String, coefficients: String, k: Double?, b: Double?, session: String) throws -> [[UInt8]] {
        guard let minor = minor(version) else { throw Failure.firmware }
        var packets: [[UInt8]] = []
        if minor >= 6 {
            let fields = coefficients.split(separator: ",", omittingEmptySubsequences: false)
            let values = fields.compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard values.count == fields.count, (1...255).contains(values.count),
                  values.allSatisfy({ $0.isFinite }) else { throw Failure.coefficients }
            var packet: [UInt8] = [0x09, UInt8(values.count)]
            for value in values {
                packet += (0..<4).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
            }
            let crc = coefficientCRC(packet)
            packet += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8)]
            packets.append(packet)
        }
        if minor >= 8 {
            guard let k = k, let b = b, k.isFinite, b.isFinite else { throw Failure.calibration }
            let plain = [k, b].flatMap { value in
                (0..<8).map { UInt8(truncatingIfNeeded: value.bitPattern >> ($0 * 8)) }
            }
            guard let encrypted = OttaiCrypto.encryptPayload(plain, sessionKeyHex: session), encrypted.count == 16 else {
                throw Failure.calibration
            }
            packets.append([0x0b] + encrypted)
        }
        return packets
    }

    private static func coefficientCRC(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1
            }
        }
        return crc
    }
}
