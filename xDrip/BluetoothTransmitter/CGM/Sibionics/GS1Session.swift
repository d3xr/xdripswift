import CryptoKit
import Foundation
import GS1Native

/// Factory 14-day GS1 CN only. Sensor index is minutes since the original session start.
enum GS1Policy {
    static let warmup: TimeInterval = 60 * 60
    static let lifetime: TimeInterval = 14 * 24 * 60 * 60
    // JugglucoNG 11e6e29db7d9055c8fd2e96261812e16f2095f3d,
    // SibionicsConstants.kt:15, CN AA55/V115G: software continuation bound only.
    // It is not evidence of accuracy beyond the labelled 14 days.
    static let diagnosticLifetime: TimeInterval = 34301 * 60
    static let revision = "GS1-CN-AA55:11e6e29:115G:1"
    static func mayPublish(index: Int, timestamp: Date, start: Date, now: Date, live: Bool, confirmed: Bool) -> Bool {
        let age = timestamp.timeIntervalSince(start), freshness = now.timeIntervalSince(timestamp)
        return confirmed && live && index >= 60 && index < 20160 && age >= warmup && age < lifetime && freshness >= 0 && freshness <= 120
    }
    static func mayInspectExtended(index: Int, timestamp: Date, start: Date, now: Date, live: Bool, confirmed: Bool) -> Bool {
        let age = timestamp.timeIntervalSince(start), freshness = now.timeIntervalSince(timestamp)
        return confirmed && live && index >= 20160 && index < 34301
            && age >= lifetime && age < diagnosticLifetime && now.timeIntervalSince(start) < diagnosticLifetime
            && freshness >= 0 && freshness <= 120
    }
}

/// Consent belongs to the full code/MAC/Bluetooth identity. A changed switch invalidates
/// already queued diagnostic results, including a quick off/on cycle.
enum GS1ExtendedReadingConsent {
    struct Token: Equatable { let identity: String; let generation: UInt64 }
    private static let lock = NSLock()
    private static var generations: [String: UInt64] = [:]
    private static func key(_ identity: String) -> String { "gs1_extended_readings_" + GS1Journal.hash(Data(identity.utf8)) }
    static func isEnabled(_ identity: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return UserDefaults.standard.bool(forKey: key(identity))
    }
    static func setEnabled(_ enabled: Bool, identity: String) {
        lock.lock(); defer { lock.unlock() }
        generations[identity, default: 0] &+= 1
        if enabled { UserDefaults.standard.set(true, forKey: key(identity)) }
        else { UserDefaults.standard.removeObject(forKey: key(identity)) }
    }
    static func token(_ identity: String) -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard UserDefaults.standard.bool(forKey: key(identity)) else { return nil }
        return Token(identity: identity, generation: generations[identity, default: 0])
    }
    static func allows(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return UserDefaults.standard.bool(forKey: key(token.identity)) && generations[token.identity, default: 0] == token.generation
    }
}

/// The diagnostic value never enters GlucoseData, Core Data glucose, or an export.
final class GS1ExtendedReadingStore {
    struct Value { let reading: GS1Session.Reading; let start: Date; let authorization: GS1ExtendedReadingConsent.Token }
    private let lock = NSLock()
    private var value: Value?
    func update(_ value: Value?) { lock.lock(); self.value = value; lock.unlock() }
    func current(at now: Date = Date()) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let value, GS1ExtendedReadingConsent.allows(value.authorization),
              GS1Policy.mayInspectExtended(index: value.reading.index, timestamp: value.reading.date,
                start: value.start, now: now, live: true, confirmed: true) else { self.value = nil; return nil }
        return value
    }
}

enum GS1SessionError: Error { case journal, checkpoint, conflictingSample, timeline, decoder, persistence }

enum GS1TimelineIssue {
    case invalidClock, invalidRecord
    var diagnostic: String {
        switch self {
        case .invalidClock: return "invalid receive clock"
        case .invalidRecord: return "invalid record clock/index"
        }
    }
}

struct GS1SourceRecord: Codable, Equatable {
    let index: Int
    let chemical: Int
    let temperature: Int
    let impedance: Int
    let status: Int
    let timestamp: Date
    init(_ sample: GS1RawSample, received: Date) {
        index = sample.index; chemical = sample.chemicalSignal; temperature = sample.rawTemperature
        impedance = sample.impedance; status = sample.opaqueStatus; timestamp = sample.timestamp(receivedAt: received)
    }
    func sameSignal(as other: GS1SourceRecord) -> Bool {
        index == other.index && chemical == other.chemical && temperature == other.temperature && impedance == other.impedance && status == other.status
    }
}

/// Append-only source journal. The checkpoint is replaceable; original source records are not.
final class GS1Journal {
    struct Line: Codable { let record: GS1SourceRecord; let digest: String }
    struct Checkpoint: Codable {
        let identity: String, revision: String, digest: String
        let index: Int
        let start: Date?
        let confirmed: Bool
        let core: Data
    }
    private struct Envelope: Codable { let body: Data; let digest: String }
    let directory: URL
    let identity: String
    private(set) var records: [GS1SourceRecord] = []
    private var digests: [String] = []
    private var initialDigest: String { Self.hash(Data((identity + GS1Policy.revision).utf8)) }
    private var journalURL: URL { directory.appendingPathComponent("source.jsonl") }
    private var checkpointURL: URL { directory.appendingPathComponent("checkpoint.json") }
    init(base: URL, identity: String) throws {
        self.identity = identity
        directory = base.appendingPathComponent(Self.hash(Data(identity.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let data = try Data(contentsOf: journalURL)
        guard data.isEmpty || data.last == 10, data.count <= 32_000_000 else { throw GS1SessionError.journal }
        var previous = initialDigest
        for raw in data.split(separator: 10) {
            let line = try JSONDecoder().decode(Line.self, from: Data(raw))
            guard line.record.index == records.count + 1, line.record.index <= 65535 else { throw GS1SessionError.journal }
            let expected = Self.hash(Data(previous.utf8) + (try Self.encode(line.record)))
            guard expected == line.digest else { throw GS1SessionError.journal }
            // Source times follow the donor remaining/addedSeconds formula.
            // Equal or decreasing times are legal; ordering is by sensor index.
            guard line.record.timestamp.timeIntervalSince1970.isFinite,
                  line.record.timestamp.timeIntervalSince1970 > 946_684_800 else { throw GS1SessionError.journal }
            records.append(line.record); digests.append(expected); previous = expected
        }
    }
    func append(_ record: GS1SourceRecord) throws {
        guard record.index == records.count + 1 else { throw GS1SessionError.journal }
        let digest = Self.hash(Data((digests.last ?? initialDigest).utf8) + (try Self.encode(record)))
        let line = try Self.encode(Line(record: record, digest: digest)) + Data([10])
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            try Data().write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let file = try FileHandle(forWritingTo: journalURL)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: line); try file.synchronize()
        records.append(record); digests.append(digest)
    }
    func loadCheckpoint() -> Checkpoint? {
        guard let data = try? Data(contentsOf: checkpointURL), data.count <= 1_000_000,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), Self.hash(envelope.body) == envelope.digest,
              let value = try? JSONDecoder().decode(Checkpoint.self, from: envelope.body), value.identity == identity,
              value.revision == GS1Policy.revision, value.index >= 1, value.index <= records.count,
              value.digest == digests[value.index - 1] else { return nil }
        return value
    }
    func saveCheckpoint(core: Data, index: Int, start: Date?, confirmed: Bool) throws {
        guard index >= 1, index == records.count else { throw GS1SessionError.checkpoint }
        let value = Checkpoint(identity: identity, revision: GS1Policy.revision, digest: digests[index - 1], index: index, start: start, confirmed: confirmed, core: core)
        let body = try Self.encode(value)
        try Self.encode(Envelope(body: body, digest: Self.hash(body))).write(to: checkpointURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Runs only on the transmitter's serial Bluetooth queue. Historical records reconstruct
/// the exact core; a fresh final correction can enter the app's glucose pipeline only
/// after the contiguous history has caught up to the sensor's live tail.
final class GS1Session {
    struct Reading { let index: Int; let date: Date; let mgdl: Double }
    struct Observation {
        let start: Date
        let latestSampleDate: Date

        func isCurrent(at now: Date) -> Bool {
            let age = now.timeIntervalSince(start), freshness = now.timeIntervalSince(latestSampleDate)
            return age.isFinite && age >= 0 && age < GS1Policy.lifetime
                && freshness.isFinite && freshness >= 0 && freshness <= 120
        }
    }
    let identity: String
    let journal: GS1Journal
    private var engine: GS1V115GEngine
    // The first new contiguous tail after init only establishes a live baseline.
    // Eligibility is never restored from a checkpoint. Historical corrections
    // are not carried across packets or promoted when a later raw tail arrives.
    private(set) var baselineTailIndex: Int?
    private var lastPublishedIndex = 0
    private var diagnosticReading: Reading?
    private var diagnosticAuthorization: GS1ExtendedReadingConsent.Token?
    private(set) var start: Date?
    private(set) var startConfirmed = false
    private(set) var historyReady = false
    var nextIndex: Int { Int(engine.lastAcceptedIndex) < 1 ? 1 : Int(engine.lastAcceptedIndex) + 1 }
    private(set) var lastStatus = "Waiting for complete sensor history"
    private(set) var timelineIssue: GS1TimelineIssue?
    private var checkpointFailed = false

    /// Warm-up has no publishable glucose, but a caught-up history can already prove
    /// the original session start. Restoring a checkpoint alone cannot prove contact.
    func liveObservation(at now: Date) -> Observation? {
        guard !checkpointFailed, startConfirmed, historyReady, let start, let latest = journal.records.last, latest.index < 20160 else { return nil }
        let observation = Observation(start: start, latestSampleDate: latest.timestamp)
        return observation.isCurrent(at: now) ? observation : nil
    }

    func extendedReading(at now: Date) -> Reading? {
        guard !checkpointFailed, let authorization = diagnosticAuthorization, GS1ExtendedReadingConsent.allows(authorization),
              let reading = diagnosticReading, let start,
              GS1Policy.mayInspectExtended(index: reading.index, timestamp: reading.date, start: start,
                now: now, live: historyReady, confirmed: startConfirmed) else { return nil }
        return reading
    }
    func discardExtendedReading() { diagnosticReading = nil }

    init(identity: String, sensitivity: Float, storage: URL) throws {
        self.identity = identity
        journal = try GS1Journal(base: storage, identity: identity)
        engine = GS1V115GEngine(sensorIdentity: identity, factorySensitivity: sensitivity)
        let saved = journal.loadCheckpoint()
        if let saved {
            let candidate = GS1V115GEngine(sensorIdentity: identity, factorySensitivity: sensitivity)
            if candidate.restore(snapshot: Self.kotlin(saved.core)), Int(candidate.lastAcceptedIndex) == saved.index,
               let first = journal.records.first, let savedStart = saved.start,
               abs(savedStart.timeIntervalSince(first.timestamp.addingTimeInterval(-60))) < 0.001,
               !saved.confirmed || saved.index >= 2 {
                engine = candidate; start = savedStart; startConfirmed = saved.confirmed
            }
        }
        // A missing or corrupt checkpoint is rebuilt from the original contiguous journal.
        // Replay does not apply a new-arrival clock test to immutable source times.
        for record in journal.records where record.index >= nextIndex { _ = try advance(record) }
        if !journal.records.isEmpty {
            // Repair the core/checkpoint from immutable records before new input.
            try persistCheckpoint()
        }
    }

    func ingest(_ samples: [GS1RawSample], received: Date, now: Date, extendedAuthorization: GS1ExtendedReadingConsent.Token? = nil, nativeStatus: ((Int, String) -> Void)? = nil) throws -> [Reading] {
        guard !checkpointFailed else { throw GS1SessionError.checkpoint }
        timelineIssue = nil
        // A consent change invalidates the diagnostic observation. Candidates are
        // local to this batch and cannot inherit a later consent generation.
        if diagnosticAuthorization != extendedAuthorization {
            diagnosticReading = nil
            diagnosticAuthorization = extendedAuthorization
        }
        let inspectExtended = extendedAuthorization.map { $0.identity == identity && GS1ExtendedReadingConsent.allows($0) } ?? false
        if !inspectExtended { diagnosticReading = nil }
        guard received.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              received.timeIntervalSince(now) <= 5, received.timeIntervalSince1970 > 946_684_800 else {
            timelineIssue = .invalidClock
            throw GS1SessionError.timeline
        }
        var advanced = false
        var newTail: GS1SourceRecord?
        var tailCorrection: Reading?
        let ordered = samples.sorted { $0.index < $1.index }
        for sample in ordered {
            let incoming = GS1SourceRecord(sample, received: received)
            let record: GS1SourceRecord
            if incoming.index > 0, incoming.index <= journal.records.count {
                let persisted = journal.records[incoming.index - 1]
                guard persisted.sameSignal(as: incoming) else { throw GS1SessionError.conflictingSample }
                // A crash can leave the source journal ahead of the checkpoint/core.
                // Replay exactly the immutable original record, including its timestamp.
                record = persisted
            } else { record = incoming }
            if record.index < nextIndex {
                guard record.index > 0, record.index <= journal.records.count,
                      journal.records[record.index - 1].sameSignal(as: record) else { throw GS1SessionError.conflictingSample }
                continue
            }
            guard record.index == nextIndex else {
                historyReady = false; lastStatus = "Downloading missing history from minute \(nextIndex)"; break
            }
            let isNew = record.index > journal.records.count
            if isNew {
                try validatePersistedRecord(record)
                try journal.append(record)
            }
            let final = try advance(record, nativeStatus: nativeStatus)
            if record.index == 1 { try persistCheckpoint() }
            advanced = true
            historyReady = sample.isLastInHistory
            if isNew, sample.isLastInHistory {
                newTail = record
                tailCorrection = final.map { .init(index: record.index, date: record.timestamp, mgdl: Double($0) * 18) }
            } else { tailCorrection = nil }
        }
        if engine.lastAcceptedIndex >= 1 {
            // Checkpoint failure must prevent publication and further ingestion.
            try persistCheckpoint()
        }
        if let start, historyReady {
            let age = now.timeIntervalSince(start)
            lastStatus = age < GS1Policy.warmup ? "Warming up: \(max(0, Int(ceil((GS1Policy.warmup-age)/60)))) min" : (age >= GS1Policy.lifetime ? (inspectExtended && age < GS1Policy.diagnosticLifetime ? "Past 14 days; experimental readings in device details only" : "14-day sensor session ended") : "Connected; waiting for the next final reading")
        }
        guard advanced, historyReady, let tail = newTail, tail.index == nextIndex - 1 else { return [] }
        guard let baseline = baselineTailIndex else {
            baselineTailIndex = tail.index
            if let start, now.timeIntervalSince(start) >= GS1Policy.warmup, now.timeIntervalSince(start) < GS1Policy.lifetime {
                lastStatus = "History ready; waiting for the next live final reading"
            }
            return []
        }
        guard let reading = tailCorrection, reading.index == tail.index,
              reading.index > baseline, reading.index > lastPublishedIndex, let start else { return [] }
        if inspectExtended, GS1Policy.mayInspectExtended(index: reading.index, timestamp: reading.date, start: start,
            now: now, live: true, confirmed: startConfirmed) {
            diagnosticReading = reading
            lastPublishedIndex = reading.index
            return []
        }
        guard GS1Policy.mayPublish(index: reading.index, timestamp: reading.date, start: start, now: now,
                                  live: true, confirmed: startConfirmed) else { return [] }
        lastPublishedIndex = reading.index
        return [reading]
    }

    private func validatePersistedRecord(_ record: GS1SourceRecord) throws {
        guard record.index == nextIndex, record.index > 0, record.index <= 65535,
              record.timestamp.timeIntervalSince1970.isFinite,
              record.timestamp.timeIntervalSince1970 > 946_684_800 else {
            timelineIssue = .invalidRecord
            throw GS1SessionError.timeline
        }
    }
    private func persistCheckpoint() throws {
        do {
            guard let snapshot = engine.snapshot() else { throw GS1SessionError.checkpoint }
            try journal.saveCheckpoint(core: Self.data(snapshot), index: Int(engine.lastAcceptedIndex), start: start,
                confirmed: startConfirmed)
        } catch {
            checkpointFailed = true
            throw error
        }
    }
    private func advance(_ record: GS1SourceRecord, nativeStatus: ((Int, String) -> Void)? = nil) throws -> Float? {
        try validatePersistedRecord(record)
        let anchor = record.timestamp.addingTimeInterval(-Double(record.index) * 60)
        if start == nil { start = anchor } else if record.index > 1 { startConfirmed = true }
        let result = engine.accept(rawMmol: Float(record.chemical)/10, temperatureC: Float(record.temperature)/10, index: Int32(record.index))
        if record.index % 5 == 0 { nativeStatus?(record.index, result.status.name) }
        guard result.status != .invalidConfiguration, result.status != .invalidInput, result.status != .nonContiguousIndex else { throw GS1SessionError.decoder }
        return result.status == .correction ? result.finalMmol?.floatValue : nil
    }
    static func data(_ value: KotlinByteArray) -> Data { Data((0..<value.size).map { UInt8(bitPattern: value.get(index: $0)) }) }
    static func kotlin(_ data: Data) -> KotlinByteArray {
        let result = KotlinByteArray(size: Int32(data.count))
        for (i, byte) in data.enumerated() { result.set(index: Int32(i), value: Int8(bitPattern: byte)) }
        return result
    }
}
