import Foundation
import XCTest
import CoreBluetooth
import CoreData
import UserNotifications
@testable import xdrip

final class GS1IntegrationTests: XCTestCase {
    private let baseTime = Date(timeIntervalSince1970: 1_790_000_000)
    private func folder() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: value) }
        return value
    }
    private func sample(_ index: Int, tail: Int, chemical: Int = 100) -> GS1RawSample {
        .init(index: index, rawTemperature: 320, impedance: 80, chemicalSignal: chemical, opaqueStatus: 0, remaining: tail-index, addedSeconds: 0)
    }
    private func session(_ folder: URL, identity: String = "GS1-CN|GEPD802J|11:22:33:44:55:66|fixture-UUID") throws -> GS1Session {
        try GS1Session(identity: identity, sensitivity: 1.27, storage: folder)
    }
    private func feed(_ session: GS1Session, through index: Int) throws -> [GS1Session.Reading] {
        let received = baseTime.addingTimeInterval(Double(index)*60)
        return try session.ingest((session.nextIndex...index).map { sample($0, tail: index) }, received: received, now: received)
    }
    private func legacyStore(_ seconds: [TimeInterval], checkpointIndex: Int? = nil) throws -> (URL, GS1Journal) {
        let index = checkpointIndex ?? seconds.count
        let native = try session(folder())
        _ = try feed(native, through: index)
        let core = try XCTUnwrap(native.journal.loadCheckpoint()).core
        let base = try folder(), journal = try GS1Journal(base: base, identity: native.identity)
        for (offset, time) in seconds.enumerated() {
            try journal.append(GS1SourceRecord(sample(offset + 1, tail: offset + 1), received: baseTime.addingTimeInterval(time)))
            if offset + 1 == index {
                try journal.saveCheckpoint(core: core, index: index, start: seconds.first.map { baseTime.addingTimeInterval($0 - 60) }, confirmed: index >= 2)
            }
        }
        return (base, journal)
    }
    private func rewriteCheckpoint(_ journal: GS1Journal, change: (inout [String: Any]) -> Void) throws {
        let url = journal.directory.appendingPathComponent("checkpoint.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let body = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["body"] as? String)))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        change(&fields)
        let updated = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        envelope["body"] = updated.base64EncodedString(); envelope["digest"] = GS1Journal.hash(updated)
        try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: url)
    }
    func testLegacyCheckpointAheadReplaysExactSourceAndNativeCoreWithoutClockForecast() throws {
        let (base, journal) = try legacyStore([60, 120, 180, 240, 300, 240, 220], checkpointIndex: 5)
        let sourceURL = journal.directory.appendingPathComponent("source.jsonl"), source = try Data(contentsOf: sourceURL)
        let value = try session(base)
        XCTAssertEqual(value.nextIndex, 8)
        XCTAssertEqual(value.start, baseTime)
        XCTAssertNil(value.baselineTailIndex)
        XCTAssertEqual(value.journal.records, journal.records)
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        let control = try session(folder()); _ = try feed(control, through: 7)
        XCTAssertEqual(try XCTUnwrap(value.journal.loadCheckpoint()).core, try XCTUnwrap(control.journal.loadCheckpoint()).core)
    }
    func testObsoleteReferenceFieldsAreIgnoredWithoutInvalidatingNativeCheckpoint() throws {
        for reference: Any in [NSNull(), "obsolete", ["index": 0, "timestamp": -1], ["index": 999, "timestamp": 0]] {
            let (base, journal) = try legacyStore([60, 120, 120, 119])
            let saved = try XCTUnwrap(journal.loadCheckpoint())
            try rewriteCheckpoint(journal) { $0["timelineReference"] = reference }
            XCTAssertNotNil(journal.loadCheckpoint())
            let restored = try session(base)
            XCTAssertEqual(try XCTUnwrap(restored.journal.loadCheckpoint()).core, saved.core)
            XCTAssertEqual(restored.start, saved.start)
            XCTAssertNil(restored.baselineTailIndex)
            XCTAssertEqual(restored.journal.records, journal.records)
        }
    }
    func testBadNativeCheckpointReplaysEqualAndDecreasingTimesWithoutChangingCore() throws {
        let (base, journal) = try legacyStore([60, 120, 360.11, 360.11, 300, 299])
        let saved = try XCTUnwrap(journal.loadCheckpoint())
        try rewriteCheckpoint(journal) {
            $0["timelineReference"] = ["index": 6, "timestamp": 0]
            $0["core"] = Data("invalid native core".utf8).base64EncodedString()
        }
        let restored = try session(base)
        XCTAssertEqual(try XCTUnwrap(restored.journal.loadCheckpoint()).core, saved.core)
        XCTAssertEqual(restored.journal.records, journal.records)
        XCTAssertEqual(restored.start, baseTime)
    }
    func testEqualAndDecreasingIncomingDatesReplayExactlyWithoutChangingOriginalStart() throws {
        let base = try folder(), value = try session(base); _ = try feed(value, through: 64)
        for (offset, seconds) in [5000.0, 5000, 4990, 4980, 4990, 5000].enumerated() {
            let index = 65 + offset, received = baseTime.addingTimeInterval(seconds)
            _ = try value.ingest([sample(index, tail: index)], received: received, now: received)
        }
        let saved = try XCTUnwrap(value.journal.loadCheckpoint())
        let sourceURL = value.journal.directory.appendingPathComponent("source.jsonl"), source = try Data(contentsOf: sourceURL)
        let restored = try session(base)
        XCTAssertEqual(try XCTUnwrap(restored.journal.loadCheckpoint()).core, saved.core)
        try FileManager.default.removeItem(at: value.journal.directory.appendingPathComponent("checkpoint.json"))
        let replayed = try session(base)
        XCTAssertEqual(try XCTUnwrap(replayed.journal.loadCheckpoint()).core, saved.core)
        XCTAssertEqual(replayed.journal.records, value.journal.records)
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
        XCTAssertEqual(replayed.start, baseTime)
        let control = try session(folder()); _ = try feed(control, through: 70)
        XCTAssertEqual(try XCTUnwrap(control.journal.loadCheckpoint()).core, saved.core)
    }
    func testExactPositive127TimingFixtureDoesNotInventTimestampOrdering() throws {
        let received = baseTime.addingTimeInterval(67 * 60)
        let exact = [16796, 16797].map {
            GS1RawSample(index: $0, rawTemperature: 320, impedance: 80, chemicalSignal: 100,
                opaqueStatus: 0, remaining: 16798 - $0, addedSeconds: 127)
        }
        XCTAssertEqual(exact.map { $0.timestamp(receivedAt: received) }, [received, received])
        let value = try session(folder()); _ = try feed(value, through: 64)
        let sameTiming = [65, 66].map {
            GS1RawSample(index: $0, rawTemperature: 320, impedance: 80, chemicalSignal: 100,
                opaqueStatus: 0, remaining: 67 - $0, addedSeconds: 127)
        }
        XCTAssertTrue(try value.ingest(sameTiming, received: received, now: received).isEmpty)
        XCTAssertEqual(value.nextIndex, 67)
        XCTAssertEqual(value.journal.records.suffix(2).map(\.timestamp), [received, received])
        XCTAssertTrue(try value.ingest([sample(67, tail: 67)], received: received, now: received).isEmpty)
        XCTAssertEqual(try feed(value, through: 70).map(\.index), [70])
        XCTAssertEqual(value.start, baseTime)
    }
    func testFirstBacklogFinalTailOnlyEstablishesBaselineAndNextFreshFinalTailEmitsOnce() throws {
        let value = try session(folder())
        let firstReceipt = baseTime.addingTimeInterval(65 * 60)
        var firstTailStatus: String?
        XCTAssertTrue(try value.ingest((1...65).map { sample($0, tail: 65) }, received: firstReceipt, now: firstReceipt) { index, status in
            if index == 65 { firstTailStatus = status }
        }.isEmpty)
        XCTAssertEqual(firstTailStatus, "CORRECTION")
        XCTAssertEqual(value.baselineTailIndex, 65)
        XCTAssertTrue(try feed(value, through: 66).isEmpty)
        let readings = try feed(value, through: 70)
        XCTAssertEqual(readings.map(\.index), [70])
        XCTAssertEqual(readings.first?.date, baseTime.addingTimeInterval(70 * 60))
        let received = baseTime.addingTimeInterval(70 * 60)
        XCTAssertTrue(try value.ingest([sample(70, tail: 70)], received: received, now: received).isEmpty)
        XCTAssertTrue(try value.ingest([], received: received, now: received).isEmpty)
    }
    func testRestartRequiresANewTailAndCannotUseDuplicateOrRestoredCorrectionAsBaseline() throws {
        let base = try folder(), original = try session(base); _ = try feed(original, through: 64)
        let restored = try session(base), received = baseTime.addingTimeInterval(65 * 60)
        XCTAssertNil(restored.baselineTailIndex)
        XCTAssertTrue(try restored.ingest([sample(64, tail: 64)], received: received, now: received).isEmpty)
        XCTAssertTrue(try restored.ingest([], received: received, now: received).isEmpty)
        XCTAssertNil(restored.baselineTailIndex)
        XCTAssertTrue(try restored.ingest([sample(65, tail: 65)], received: received, now: received).isEmpty)
        XCTAssertEqual(restored.baselineTailIndex, 65)
        XCTAssertEqual(try feed(restored, through: 70).map(\.index), [70])
    }
    func testFailedBatchDoesNotEstablishBaselineOrPublishItsAcceptedFinalPrefix() throws {
        let base = try folder(), original = try session(base); _ = try feed(original, through: 64)
        let value = try session(base), received = baseTime.addingTimeInterval(65 * 60)
        XCTAssertThrowsError(try value.ingest([sample(65, tail: 65), sample(65, tail: 65, chemical: 101)], received: received, now: received))
        XCTAssertEqual(value.nextIndex, 66)
        XCTAssertNil(value.baselineTailIndex)
        XCTAssertEqual(try XCTUnwrap(value.journal.loadCheckpoint()).index, 64)
        let restored = try session(base)
        XCTAssertEqual(restored.nextIndex, 66)
        XCTAssertNil(restored.baselineTailIndex)
        XCTAssertTrue(try feed(restored, through: 66).isEmpty)
        XCTAssertEqual(try feed(restored, through: 70).map(\.index), [70])
    }
    func testInitialCheckpointWriteFailureStopsBeforeSecondRecordAndNeverEstablishesBaseline() throws {
        let base = try folder(), value = try session(base)
        let checkpoint = value.journal.directory.appendingPathComponent("checkpoint.json")
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        let received = baseTime.addingTimeInterval(120)
        XCTAssertThrowsError(try value.ingest([sample(1, tail: 2), sample(2, tail: 2)], received: received, now: received))
        XCTAssertEqual(value.journal.records.count, 1)
        XCTAssertEqual(value.nextIndex, 2)
        XCTAssertNil(value.baselineTailIndex)
        XCTAssertThrowsError(try value.ingest([sample(2, tail: 2)], received: received, now: received))
        XCTAssertEqual(value.journal.records.count, 1)
        try FileManager.default.removeItem(at: checkpoint)
        let restored = try session(base)
        XCTAssertNil(restored.baselineTailIndex)
        _ = try restored.ingest([sample(2, tail: 2)], received: received, now: received)
        XCTAssertEqual(restored.baselineTailIndex, 2)
        XCTAssertEqual(restored.start, baseTime)
    }
    func testRecoveryCheckpointWriteFailurePreventsSessionFromAcceptingNewRecords() throws {
        let (base, journal) = try legacyStore([60, 120, 180])
        let sourceURL = journal.directory.appendingPathComponent("source.jsonl"), source = try Data(contentsOf: sourceURL)
        let checkpoint = journal.directory.appendingPathComponent("checkpoint.json")
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        XCTAssertThrowsError(try session(base))
        XCTAssertEqual(try Data(contentsOf: sourceURL), source)
    }
    func testTailCheckpointWriteFailureCannotPublishAndRestartDropsEligibility() throws {
        let base = try folder(), value = try session(base); _ = try feed(value, through: 64)
        let checkpoint = value.journal.directory.appendingPathComponent("checkpoint.json"), saved = try Data(contentsOf: checkpoint)
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        let received = baseTime.addingTimeInterval(65 * 60)
        XCTAssertThrowsError(try value.ingest([sample(65, tail: 65)], received: received, now: received))
        XCTAssertEqual(value.baselineTailIndex, 64)
        XCTAssertEqual(value.nextIndex, 66)
        XCTAssertThrowsError(try value.ingest([sample(66, tail: 66)], received: received.addingTimeInterval(60), now: received.addingTimeInterval(60)))
        XCTAssertEqual(value.journal.records.count, 65)
        try FileManager.default.removeItem(at: checkpoint); try saved.write(to: checkpoint)
        let restored = try session(base)
        XCTAssertNil(restored.baselineTailIndex)
        XCTAssertTrue(try restored.ingest([sample(65, tail: 65)], received: received, now: received).isEmpty)
        XCTAssertNil(restored.baselineTailIndex)
    }
    func testFirstTailCheckpointFailureCannotEstablishBaseline() throws {
        let base = try folder(), original = try session(base); _ = try feed(original, through: 64)
        let value = try session(base), checkpoint = value.journal.directory.appendingPathComponent("checkpoint.json")
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        let received = baseTime.addingTimeInterval(65 * 60)
        XCTAssertThrowsError(try value.ingest([sample(65, tail: 65)], received: received, now: received))
        XCTAssertNil(value.baselineTailIndex)
        XCTAssertEqual(value.nextIndex, 66)
    }
    func testNativeStatusDistinguishesNoCorrectionAndInvalidOutputWithoutPublishingEither() throws {
        var sawInvalidOutput = false, sawNoCorrection = false
        for chemical in [0, 700] {
            let value = try session(folder())
            for index in 1...120 {
                let received = baseTime.addingTimeInterval(Double(index) * 60)
                var status: String?
                let readings = try value.ingest([sample(index, tail: index, chemical: chemical)], received: received, now: received) { processed, result in
                    XCTAssertEqual(processed, index)
                    status = result
                }
                if index % 5 != 0 { XCTAssertNil(status) }
                if status == "NO_CORRECTION" { sawNoCorrection = true; XCTAssertTrue(readings.isEmpty) }
                if status == "INVALID_OUTPUT" { sawInvalidOutput = true; XCTAssertTrue(readings.isEmpty) }
            }
        }
        XCTAssertTrue(sawNoCorrection)
        XCTAssertTrue(sawInvalidOutput)
    }
    func testBaselinePreservesWarmupAndEndedStatus() throws {
        let warmup = try session(folder()); _ = try feed(warmup, through: 2)
        XCTAssertTrue(warmup.lastStatus.hasPrefix("Warming up:"))
        let ended = try session(folder())
        let received = baseTime.addingTimeInterval(120)
        _ = try ended.ingest([sample(1, tail: 2), sample(2, tail: 2)], received: received,
            now: baseTime.addingTimeInterval(GS1Policy.lifetime))
        XCTAssertEqual(ended.lastStatus, "Sensor session reading limit reached")
    }
#if targetEnvironment(simulator)
    @MainActor func testPrivateGS1CheckpointRestoreAndFullReplayPreserveExactSourceAndCore() throws {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let input = documents.appendingPathComponent("GS1PrivateReplayInput", isDirectory: true)
        guard FileManager.default.fileExists(atPath: input.path) else { throw XCTSkip("Private replay input is not installed") }
        let candidates = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("source.jsonl").path) }
        guard candidates.count == 1, let original = candidates.first else { return XCTFail("Expected one isolated replay input") }
        struct Envelope: Decodable { let body: Data; let digest: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: original.appendingPathComponent("checkpoint.json")))
        XCTAssertTrue(GS1Journal.hash(envelope.body) == envelope.digest)
        let saved = try JSONDecoder().decode(GS1Journal.Checkpoint.self, from: envelope.body)
        let parts = saved.identity.components(separatedBy: "|")
        guard parts.count == 4, let identity = try? GS1CNIdentity(sensorCode: parts[1], mac: GS1MAC(parts[2])) else {
            return XCTFail("Replay identity is not a supported GS1 CN identity")
        }
        let source = try Data(contentsOf: original.appendingPathComponent("source.jsonl"))
        var results: [GS1Session] = []
        for fullReplay in [false, true] {
            let base = try folder(), destination = base.appendingPathComponent(GS1Journal.hash(Data(saved.identity.utf8)))
            try FileManager.default.copyItem(at: original, to: destination)
            if fullReplay { try FileManager.default.removeItem(at: destination.appendingPathComponent("checkpoint.json")) }
            let value = try GS1Session(identity: saved.identity, sensitivity: identity.sensitivity, storage: base)
            XCTAssertTrue(try Data(contentsOf: destination.appendingPathComponent("source.jsonl")) == source)
            results.append(value)
        }
        XCTAssertTrue(results[0].start == results[1].start)
        XCTAssertTrue(results[0].start == saved.start)
        XCTAssertTrue(results[0].journal.records == results[1].journal.records)
        guard saved.index >= 1, saved.index <= results[0].journal.records.count else {
            return XCTFail("Replay input checkpoint index is outside its immutable journal")
        }
        XCTAssertEqual(results[0].nextIndex, results[0].journal.records.count + 1)
        XCTAssertEqual(results[1].nextIndex, results[1].journal.records.count + 1)
        let restored = try XCTUnwrap(results[0].journal.loadCheckpoint()), replayed = try XCTUnwrap(results[1].journal.loadCheckpoint())
        XCTAssertTrue(restored.core == replayed.core)
        // A crash prefix ahead of the old checkpoint legitimately advances the
        // core; otherwise compare the original bytes as well as the two paths.
        if saved.index == results[0].journal.records.count { XCTAssertTrue(restored.core == saved.core) }
        XCTAssertNil(results[0].baselineTailIndex)
        XCTAssertNil(results[1].baselineTailIndex)
        XCTAssertTrue(try Data(contentsOf: original.appendingPathComponent("source.jsonl")) == source)
    }
#endif
    func testWarmupObservationNeedsCorroboratedCaughtUpHistoryAndSurvivesReconnect() throws {
        let base = try folder(), value = try session(base)
        let firstTime = baseTime.addingTimeInterval(60)
        XCTAssertTrue(try value.ingest([sample(1, tail: 1)], received: firstTime, now: firstTime).isEmpty)
        XCTAssertNil(value.liveObservation(at: firstTime))
        let secondTime = baseTime.addingTimeInterval(120)
        XCTAssertTrue(try value.ingest([sample(2, tail: 3)], received: secondTime.addingTimeInterval(60), now: secondTime.addingTimeInterval(60)).isEmpty)
        XCTAssertNil(value.liveObservation(at: secondTime.addingTimeInterval(60)))
        let now = baseTime.addingTimeInterval(180)
        XCTAssertTrue(try value.ingest([sample(3, tail: 3)], received: now, now: now).isEmpty)
        XCTAssertEqual(value.liveObservation(at: now)?.start, baseTime)
        let records = value.journal.records
        XCTAssertNil(value.liveObservation(at: now.addingTimeInterval(121)))

        let restored = try session(base)
        XCTAssertNil(restored.liveObservation(at: now), "A checkpoint alone is not fresh contact")
        XCTAssertTrue(try restored.ingest([sample(4, tail: 4)], received: now.addingTimeInterval(60), now: now.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(restored.liveObservation(at: now.addingTimeInterval(60))?.start, baseTime)
        XCTAssertEqual(Array(restored.journal.records.prefix(3)), records)
    }

    func testWarmupDeliveryReportsOriginalSessionWithoutInventingGlucose() throws {
        let delegate = GS1SessionDelegateSpy(), uuid = UUID()
        let identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 test", code: "GEPD802J", mac: "11:22:33:44:55:66", authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        let value = try session(folder(), identity: identity.checkpointIdentity(peripheralID: uuid))
        let now = Date(), start = now.addingTimeInterval(-120)
        let readings = try value.ingest([sample(1, tail: 2), sample(2, tail: 2)], received: now, now: now)
        XCTAssertTrue(readings.isEmpty)
        let observation = try XCTUnwrap(value.liveObservation(at: now))
        delegate.observed = expectation(description: "Warm-up session metadata delivered")
        transmitter.publish(readings, observation: observation)
        wait(for: [delegate.observed!], timeout: 2)
        XCTAssertEqual(delegate.starts, [start])
        XCTAssertEqual(delegate.glucoseBatches, 0)
        XCTAssertEqual(delegate.heartbeats, 1)

        delegate.observed = expectation(description: "Reconnect keeps the original start")
        transmitter.publish([], observation: observation)
        wait(for: [delegate.observed!], timeout: 2)
        XCTAssertEqual(delegate.starts, [start, start])
        XCTAssertEqual(delegate.glucoseBatches, 0)
        transmitter.prepareForRelease()
    }

    func testStaleOrCancelledWarmupDeliveryCannotPublishSession() {
        let delegate = GS1SessionDelegateSpy()
        let transmitter = CGMSibionicsTransmitter(address: UUID().uuidString, name: "GS1 test", code: "GEPD802J", mac: "11:22:33:44:55:66", authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        let now = Date()
        transmitter.publish([], observation: .init(start: now.addingTimeInterval(-600), latestSampleDate: now.addingTimeInterval(-121)))
        transmitter.publish([], observation: .init(start: now.addingTimeInterval(-600), latestSampleDate: now))
        transmitter.prepareForRelease()
        let drained = expectation(description: "Main delivery queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(delegate.starts.isEmpty)
        XCTAssertEqual(delegate.glucoseBatches, 0)
        XCTAssertEqual(delegate.heartbeats, 0)
    }

    func testCheckpointFailureCannotPublishFreshWarmupMetadata() throws {
        let value = try session(folder()); _ = try feed(value, through: 2)
        let prior = baseTime.addingTimeInterval(120)
        XCTAssertNotNil(value.liveObservation(at: prior))
        let checkpoint = value.journal.directory.appendingPathComponent("checkpoint.json")
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
        let received = baseTime.addingTimeInterval(180)
        XCTAssertThrowsError(try value.ingest([sample(3, tail: 3)], received: received, now: received))
        XCTAssertNil(value.liveObservation(at: received))
        XCTAssertEqual(value.baselineTailIndex, 2)
    }

    func testDriverDropsStaleOrFutureGlucoseEvenWhenSessionMetadataIsCurrent() {
        let delegate = GS1SessionDelegateSpy()
        let transmitter = CGMSibionicsTransmitter(address: UUID().uuidString, name: "GS1 test", code: "GEPD802J", mac: "11:22:33:44:55:66",
            authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        let now = Date()
        transmitter.publish([.init(index: 65, date: now.addingTimeInterval(-121), mgdl: 110),
                             .init(index: 70, date: now.addingTimeInterval(60), mgdl: 120)],
            observation: .init(start: now.addingTimeInterval(-4200), latestSampleDate: now))
        let drained = expectation(description: "Glucose delivery queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(delegate.starts.count, 1)
        XCTAssertEqual(delegate.glucoseBatches, 0)
        XCTAssertEqual(delegate.heartbeats, 1)
        transmitter.prepareForRelease()
    }

    func testReleasedDriverCannotPublishAQueuedNewNativeFinalCorrection() throws {
        let uuid = UUID(), identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let value = try session(folder(), identity: identity.checkpointIdentity(peripheralID: uuid)), now = Date()
        let previous = now.addingTimeInterval(-60)
        XCTAssertTrue(try value.ingest((1...64).map { sample($0, tail: 64) }, received: previous, now: previous).isEmpty)
        let readings = try value.ingest([sample(65, tail: 65)], received: now, now: now)
        XCTAssertEqual(readings.map(\.index), [65])
        let observation = try XCTUnwrap(value.liveObservation(at: now)), delegate = GS1SessionDelegateSpy()
        let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 test", code: "GEPD802J", mac: "11:22:33:44:55:66",
            authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        transmitter.publish(readings, observation: observation)
        transmitter.prepareForRelease()
        let drained = expectation(description: "Released native correction queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(delegate.starts.isEmpty)
        XCTAssertEqual(delegate.glucoseBatches, 0)
        XCTAssertEqual(delegate.heartbeats, 0)
    }

    @MainActor func testObservedSessionPersistsOnceAndPublishesOriginalWarmupMetadata() throws {
        let defaults = UserDefaults.standard
        let keys = [UserDefaults.Key.isMaster.rawValue, UserDefaults.Key.activeSensorStartDate.rawValue,
                    UserDefaults.Key.activeSensorDescription.rawValue, UserDefaults.Key.activeSensorMaxSensorAgeInDays.rawValue,
                    "dexcomSensorSessionIdentityData"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.isMaster = true
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let coordinator = RootApplicationCoordinator()
        let delegate = GS1SessionDelegateSpy()
        let transmitter = CGMSibionicsTransmitter(address: UUID().uuidString, name: "GS1 test", code: "GEPD802J", mac: "11:22:33:44:55:66", authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        let other = CGMSibionicsTransmitter(address: UUID().uuidString, name: "Other GS1", code: "GEPD802J", mac: "11:22:33:44:55:66", authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        defer { transmitter.prepareForRelease(); other.prepareForRelease() }
        let now = Date(), start = now.addingTimeInterval(-120)
        XCTAssertFalse(coordinator.synchronizeObservedSession(startDate: start, from: other, currentTransmitter: transmitter, coreDataManager: core))
        XCTAssertNil(coordinator.activeSensor)
        XCTAssertTrue(coordinator.synchronizeObservedSession(startDate: start, from: transmitter, currentTransmitter: transmitter, coreDataManager: core))
        let sensor = try XCTUnwrap(coordinator.activeSensor)
        XCTAssertTrue(core.saveChangesSynchronously())
        let identity = sensor.objectID
        XCTAssertEqual(defaults.activeSensorStartDate, start)
        XCTAssertEqual(defaults.activeSensorMaxSensorAgeInDays, 14)
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: BgReading.fetchRequest()), 0)
        let metadata = XDripCGMMetadataBuilder.build(context: .init(activeSensor: sensor, transmitter: transmitter,
            sensorHealthIssue: nil, hasInitialCalibration: false, lastCalibrationAt: nil, dexcomAlgorithmState: nil, libreSensorState: nil),
            latestSharedGlucoseAt: nil, lastCommunicationAt: now, now: now)
        XCTAssertEqual(metadata.sensor?.state, "warmup")
        XCTAssertEqual(metadata.sensor?.startedAt, start.timeIntervalSince1970)
        XCTAssertEqual(metadata.sensor?.warmupEndsAt, start.addingTimeInterval(3600).timeIntervalSince1970)
        XCTAssertEqual(metadata.sensor?.expiresAt, start.addingTimeInterval(14 * 86400).timeIntervalSince1970)
        XCTAssertNil(metadata.latestData?.glucoseAt)

        let calibration = Calibration(timeStamp: now, sensor: sensor, bg: 110, rawValue: 110, adjustedRawValue: 110,
            sensorConfidence: 1, rawTimeStamp: now, slope: 1, intercept: 0, distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 110, slopeConfidence: 1, deviceName: "fixture", nsManagedObjectContext: core.mainManagedObjectContext)
        let reading = BgReading(timeStamp: now, sensor: sensor, calibration: calibration, rawData: 110, deviceName: "fixture", nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        for repeatedStart in [start, start.addingTimeInterval(-600)] {
            XCTAssertTrue(coordinator.synchronizeObservedSession(startDate: repeatedStart, from: transmitter, currentTransmitter: transmitter, coreDataManager: core))
        }
        XCTAssertEqual(coordinator.activeSensor?.objectID, identity)
        XCTAssertEqual(coordinator.activeSensor?.startDate, start)
        XCTAssertNil(sensor.endDate)
        XCTAssertTrue(reading.sensor === sensor)
        XCTAssertTrue(calibration.sensor === sensor)
        XCTAssertEqual(try core.mainManagedObjectContext.count(for: Sensor.fetchRequest()), 1)
        XCTAssertFalse(coordinator.synchronizeObservedSession(startDate: start, from: transmitter, currentTransmitter: other, coreDataManager: core))
        XCTAssertEqual(coordinator.activeSensor?.objectID, identity)
    }

    func testExtendedPublicationRequiresExplicitModeAndStopsAtDonorBound() {
        XCTAssertEqual(GS1Policy.extendedLifetimeMinutes, 34301)
        XCTAssertEqual(GS1Policy.extendedLifetime, 34301 * 60)
        for index in [20160, 34300, 34301] {
            let date = baseTime.addingTimeInterval(Double(index) * 60)
            XCTAssertFalse(GS1Policy.mayPublish(index: index, timestamp: date, start: baseTime, now: date, live: true, confirmed: true))
            XCTAssertEqual(GS1Policy.mayPublish(index: index, timestamp: date, start: baseTime, now: date, live: true, confirmed: true, extended: true), index < 34301)
        }
        let last = baseTime.addingTimeInterval(34300 * 60)
        XCTAssertFalse(GS1Policy.mayPublish(index: 34300, timestamp: last, start: baseTime,
            now: baseTime.addingTimeInterval(34301 * 60), live: true, confirmed: true, extended: true))
        for index in [34301, 34302] {
            XCTAssertFalse(GS1Policy.mayPublish(index: index, timestamp: last, start: baseTime,
                now: last, live: true, confirmed: true, extended: true), "Clock drift must not bypass the index cap")
        }
        for (live, confirmed) in [(false, true), (true, false)] {
            XCTAssertFalse(GS1Policy.mayPublish(index: 34300, timestamp: last, start: baseTime,
                now: last, live: live, confirmed: confirmed, extended: true))
        }
    }

    func testExtendedConsentUsesNewPreferenceAndRejectsOldDiagnosticAuthorization() throws {
        let identity = UUID().uuidString, other = UUID().uuidString
        let legacyKey = "gs1_extended_readings_" + GS1Journal.hash(Data(identity.utf8))
        let newKey = "gs1_extended_glucose_v1_" + GS1Journal.hash(Data(identity.utf8))
        defer {
            GS1ExtendedReadingConsent.setEnabled(false, identity: identity)
            GS1ExtendedReadingConsent.setEnabled(false, identity: other)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        UserDefaults.standard.set(true, forKey: legacyKey)
        XCTAssertNil(GS1ExtendedReadingConsent.token(identity))
        XCTAssertFalse(GS1ExtendedReadingConsent.isEnabled(identity))
        GS1ExtendedReadingConsent.setEnabled(true, identity: identity)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: newKey))
        let token = try XCTUnwrap(GS1ExtendedReadingConsent.token(identity))
        XCTAssertNil(GS1ExtendedReadingConsent.token(other))
        XCTAssertTrue(GS1ExtendedReadingConsent.allows(token))
        GS1ExtendedReadingConsent.setEnabled(false, identity: identity)
        GS1ExtendedReadingConsent.setEnabled(true, identity: identity)
        XCTAssertFalse(GS1ExtendedReadingConsent.allows(token))
        XCTAssertNotEqual(GS1ExtendedReadingConsent.token(identity), token)
    }

    func testOldDiagnosticPreferenceCannotPublishPostFourteenDayGlucose() throws {
        let uuid = UUID(), identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let key = identity.checkpointIdentity(peripheralID: uuid)
        let legacyKey = "gs1_extended_readings_" + GS1Journal.hash(Data(key.utf8))
        defer {
            UserDefaults.standard.removeObject(forKey: legacyKey)
            GS1ExtendedReadingConsent.setEnabled(false, identity: key)
        }
        UserDefaults.standard.set(true, forKey: legacyKey)
        let delegate = GS1SessionDelegateSpy()
        let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 test", code: identity.sensorCode, mac: identity.mac.string,
            authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        defer { transmitter.prepareForRelease() }
        let now = Date(), start = now.addingTimeInterval(-20165 * 60)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), 14)
        transmitter.publish([.init(index: 20165, date: now, mgdl: 110)],
            observation: .init(start: start, latestSampleDate: now, identity: key, authorization: GS1ExtendedReadingConsent.token(key)))
        let drained = expectation(description: "Old diagnostic preference delivery drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(delegate.starts.isEmpty)
        XCTAssertEqual(delegate.glucoseBatches, 0)
        XCTAssertEqual(delegate.heartbeats, 0)
    }

    func testExtendedObservationBindsOwnerGenerationFreshnessAndLifetime() throws {
        let identity = UUID().uuidString
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: identity) }
        let now = baseTime.addingTimeInterval(34300 * 60)
        GS1ExtendedReadingConsent.setEnabled(true, identity: identity)
        let token = try XCTUnwrap(GS1ExtendedReadingConsent.token(identity))
        let observation = GS1Session.Observation(start: baseTime, latestSampleDate: now, identity: identity, authorization: token)
        XCTAssertTrue(observation.isCurrent(at: now))
        XCTAssertFalse(observation.isCurrent(at: now.addingTimeInterval(-1)))
        XCTAssertFalse(observation.isCurrent(at: now.addingTimeInterval(121)))
        XCTAssertFalse(observation.isCurrent(at: baseTime.addingTimeInterval(34301 * 60)))
        XCTAssertFalse(GS1Session.Observation(start: baseTime, latestSampleDate: now).isCurrent(at: now))
        XCTAssertFalse(GS1Session.Observation(start: baseTime, latestSampleDate: now,
            identity: UUID().uuidString, authorization: token).isCurrent(at: now))
        let beforeFactoryExpiry = GS1Session.Observation(start: baseTime, latestSampleDate: baseTime.addingTimeInterval(3600),
            identity: identity, authorization: token)
        GS1ExtendedReadingConsent.setEnabled(false, identity: identity)
        GS1ExtendedReadingConsent.setEnabled(true, identity: identity)
        XCTAssertFalse(observation.isCurrent(at: now), "A renewed consent cannot revive a queued observation")
        XCTAssertFalse(beforeFactoryExpiry.isCurrent(at: baseTime.addingTimeInterval(3600)), "An invalid captured token must not fall back to ordinary authorization")
    }

    func testOrdinaryFactoryReadingRemainsIndependentOfExtendedModeConsentChanges() throws {
        let value = try session(folder())
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: value.identity) }
        GS1ExtendedReadingConsent.setEnabled(true, identity: value.identity)
        let authorization = try XCTUnwrap(GS1ExtendedReadingConsent.token(value.identity))
        _ = try feed(value, through: 64)
        let now = baseTime.addingTimeInterval(65 * 60)
        let readings = try value.ingest([sample(65, tail: 65)], received: now, now: now, extendedAuthorization: authorization)
        XCTAssertEqual(readings.map(\.index), [65])
        let observation = try XCTUnwrap(value.liveObservation(at: now))
        GS1ExtendedReadingConsent.setEnabled(false, identity: value.identity)
        XCTAssertTrue(observation.isCurrent(at: now))
        XCTAssertNotNil(value.liveObservation(at: now))
        XCTAssertTrue(observation.allows(try XCTUnwrap(readings.first), at: now))
    }

    func testExtendedObservationRejectsOutOfRangeIndicesValuesAndDates() throws {
        let identity = UUID().uuidString
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: identity) }
        GS1ExtendedReadingConsent.setEnabled(true, identity: identity)
        let authorization = try XCTUnwrap(GS1ExtendedReadingConsent.token(identity))
        let now = baseTime.addingTimeInterval(34300 * 60)
        let observation = GS1Session.Observation(start: baseTime, latestSampleDate: now, identity: identity, authorization: authorization)
        XCTAssertTrue(observation.allows(.init(index: 34300, date: now, mgdl: 110), at: now))
        XCTAssertFalse(observation.allows(.init(index: 34301, date: now, mgdl: 110), at: now))
        for value in [0, -1, Double.nan, .infinity, 901] {
            XCTAssertFalse(observation.allows(.init(index: 34300, date: now, mgdl: value), at: now))
        }
        for offset: TimeInterval in [-121, 1] {
            XCTAssertFalse(observation.allows(.init(index: 34300, date: now.addingTimeInterval(offset), mgdl: 110), at: now))
        }
    }

    func testPostFourteenDayDriverPublishesNormalGlucoseWithOriginalAge() throws {
        let uuid = UUID(), identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let key = identity.checkpointIdentity(peripheralID: uuid)
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: key) }
        GS1ExtendedReadingConsent.setEnabled(true, identity: key)
        let token = try XCTUnwrap(GS1ExtendedReadingConsent.token(key)), delegate = GS1SessionDelegateSpy()
        // No Bluetooth authorization: this exercises decoder delivery only, not physical BLE.
        let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 test", code: identity.sensorCode, mac: identity.mac.string,
            authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        defer { transmitter.prepareForRelease() }
        let now = Date(), start = now.addingTimeInterval(-20165 * 60)
        XCTAssertEqual(transmitter.maxSensorAgeInDays(), GS1Policy.extendedLifetime / 86400)
        transmitter.publish([.init(index: 20165, date: now, mgdl: 110)],
            observation: .init(start: start, latestSampleDate: now, identity: key, authorization: token))
        let drained = expectation(description: "Extended normal glucose delivery drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(delegate.starts, [start])
        XCTAssertEqual(delegate.glucoseBatches, 1)
        XCTAssertEqual(delegate.glucose.count, 1)
        XCTAssertEqual(delegate.glucose.first?.timeStamp, now)
        XCTAssertEqual(delegate.glucose.first?.glucoseLevelRaw, 110)
        XCTAssertEqual(delegate.glucose.first?.isHistoricalCollection, false)
        XCTAssertNil(delegate.glucose.first?.backfilledAt)
        XCTAssertEqual(delegate.glucose.first?.valueIsFromWatch, false)
        XCTAssertEqual(delegate.sensorAges, [20165 * 60])
        XCTAssertEqual(delegate.heartbeats, 1)
        XCTAssertEqual(start, now.addingTimeInterval(-20165 * 60))
    }

    @MainActor func testExtendedNativeFinalFlowsThroughRootCoreDataAlertsAndTrioAndRejectsQueuedInvalidations() throws {
        guard !Bundle.main.disableLoopShare else { throw XCTSkip("This host disables OS-AID sharing") }
        let defaults = UserDefaults.standard
        let keys = ["isMaster", "transmitterTypeAsString", "loopShareType", "loopShareSmoothedData", "loopShareMedtrumNano",
            "loopDelaySchedule", "loopDelayValueInMinutes", "timeStampLatestLoopSharedBgReading", "readingsStoredInSharedUserDefaultsAsDictionary", "snoozeAllAlertsUntilDate",
            "activeSensorStartDate", "activeSensorDescription", "activeSensorMaxSensorAgeInDays", "dexcomSensorSessionIdentityData",
            "enableAdjustment", "enableGlucoseAdjustment", "enableCurveAdjustment", "enableSmoothing", "showReadingInNotification"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        let shared = try XCTUnwrap(UserDefaults(suiteName: LoopShareType.trio.sharedUserDefaultsSuiteName))
        let sharedKeys = ["latestReadings", XDripCGMMetadataEnvelope.appGroupKey,
            "cgmTransmitterDeviceAddress", "cgmTransmitter_CBUUID_Service", "cgmTransmitter_CBUUID_Receive"]
        let savedShared = sharedKeys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
            for (key, value) in savedShared { if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) } }
        }
        defaults.isMaster = true
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.sibionicsCN.rawValue
        defaults.loopShareType = .trio
        defaults.loopDelaySchedule = nil
        defaults.snoozeAllAlertsUntilDate = nil
        defaults.timeStampLatestLoopSharedBgReading = Date().addingTimeInterval(-3600)
        for key in ["enableAdjustment", "enableGlucoseAdjustment", "enableCurveAdjustment", "enableSmoothing", "showReadingInNotification"] { defaults.set(false, forKey: key) }
        for key in sharedKeys { shared.removeObject(forKey: key) }

        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let coordinator = RootApplicationCoordinator(), bluetoothDelegate = GS1SessionDelegateSpy()
        let uuid = UUID(), identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let key = identity.checkpointIdentity(peripheralID: uuid)
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: key) }
        GS1ExtendedReadingConsent.setEnabled(true, identity: key)
        let token = try XCTUnwrap(GS1ExtendedReadingConsent.token(key))
        let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 full pipeline fixture", code: identity.sensorCode,
            mac: identity.mac.string, authorized: false, bluetoothTransmitterDelegate: bluetoothDelegate, cGMTransmitterDelegate: coordinator)
        defer { transmitter.prepareForRelease() }
        let manager = BluetoothPeripheralManager(coreDataManager: core, cgmTransmitterDelegate: coordinator,
            messageHandler: { _, _ in }, heartBeatFunction: nil, cgmTransmitterInfoChanged: {})
        manager.bluetoothTransmitters = [transmitter]
        manager.currentCgmTransmitterAddress = transmitter.deviceAddress
        let loop = LoopManager(coreDataManager: core, activeSensorIsAnubisProvider: { false }, metadataContextProvider: {
            .init(activeSensor: coordinator.activeSensor, transmitter: transmitter, sensorHealthIssue: nil,
                hasInitialCalibration: false, lastCalibrationAt: nil, dexcomAlgorithmState: nil, libreSensorState: nil)
        })
        let notificationCenter = GS1PipelineNotificationCenter()
        let types = AlertTypesAccessor(coreDataManager: core)
        let entries = AlertEntriesAccessor(coreDataManager: core).getAllEntries(forAlertKind: nil, alertTypesAccessor: types)
        for entry in entries {
            entry.isDisabled = entry.alertkind != AlertKind.high.rawValue
            entry.alertType.enabled = true
            entry.alertType.soundname = ""
        }
        let high = try XCTUnwrap(entries.first { $0.alertkind == AlertKind.high.rawValue })
        high.value = 1
        let alerts = AlertManager(coreDataManager: core, soundPlayer: nil, notificationCenter: notificationCenter)
        coordinator.configureGlucosePipeline(coreDataManager: core, bluetoothPeripheralManager: manager, loopManager: loop, alertManager: alerts)

        let value = try session(folder(), identity: key), now = Date().addingTimeInterval(-60)
        let baselineDate = now.addingTimeInterval(-5 * 60)
        XCTAssertTrue(try value.ingest((1...20160).map { sample($0, tail: 20160) }, received: baselineDate,
            now: baselineDate, extendedAuthorization: token).isEmpty)
        let readings = try value.ingest((20161...20165).map { sample($0, tail: 20165) }, received: now, now: now, extendedAuthorization: token)
        XCTAssertEqual(readings.count, 1)
        let final = try XCTUnwrap(readings.first)
        let observation = try XCTUnwrap(value.liveObservation(at: now))
        transmitter.publish(readings, observation: observation)
        let delivered = expectation(description: "Native correction reaches actual storage, alerts and Trio")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 3)
        XCTAssertTrue(core.saveChangesSynchronously())
        let stored = try core.mainManagedObjectContext.fetch(BgReading.fetchRequest())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.timeStamp, final.date)
        XCTAssertEqual(stored.first?.calculatedValue, final.mgdl)
        XCTAssertEqual(coordinator.activeSensor?.startDate, value.start)
        XCTAssertEqual(defaults.activeSensorStartDate, value.start)
        XCTAssertEqual(defaults.activeSensorMaxSensorAgeInDays, GS1Policy.extendedLifetime / 86400)
        XCTAssertTrue(notificationCenter.added.contains { $0.identifier == AlertKind.high.notificationIdentifier() }, "The real glucose threshold evaluator must receive the extended reading")
        let exportedData = try XCTUnwrap(shared.data(forKey: "latestReadings"))
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: exportedData) as? [[String: Any]])
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?["Value"] as? Double, final.mgdl.rounded())
        let metadata = try JSONDecoder().decode(XDripCGMMetadataEnvelope.self,
            from: XCTUnwrap(shared.data(forKey: XDripCGMMetadataEnvelope.appGroupKey)))
        XCTAssertEqual(metadata.sensor?.startedAt, observation.start.timeIntervalSince1970)
        XCTAssertEqual(metadata.sensor?.expiresAt, observation.start.addingTimeInterval(GS1Policy.extendedLifetime).timeIntervalSince1970)
        XCTAssertEqual(metadata.sensor?.state, "active")
        // Legacy Trio DT stores milliseconds rounded down to whole seconds.
        let wireGlucoseEpoch = floor(final.date.timeIntervalSince1970)
        XCTAssertEqual(exported.first?["DT"] as? String, "/Date(\(Int64(wireGlucoseEpoch * 1000)))/")
        XCTAssertEqual(metadata.latestData?.glucoseAt, wireGlucoseEpoch)
        XCTAssertNotNil(metadata.source?.lastCommunicationAt)
        let sensorID = try XCTUnwrap(coordinator.activeSensor).objectID
        let alertCount = notificationCenter.added.count

        // Exercise the production configuration callback independently of live radio contact.
        // The fixture decoder is not injected into the transmitter's private BLE session.
        for enabled in [false, true] {
            GS1ExtendedReadingConsent.setEnabled(enabled, identity: key)
            coordinator.sensorSessionConfigurationChanged(startDate: observation.start, from: transmitter)
            let updated = try JSONDecoder().decode(XDripCGMMetadataEnvelope.self,
                from: XCTUnwrap(shared.data(forKey: XDripCGMMetadataEnvelope.appGroupKey)))
            XCTAssertEqual(updated.sensor?.startedAt, metadata.sensor?.startedAt)
            XCTAssertEqual(updated.sensor?.expiresAt,
                observation.start.addingTimeInterval(enabled ? GS1Policy.extendedLifetime : GS1Policy.lifetime).timeIntervalSince1970)
            XCTAssertEqual(updated.sensor?.state, enabled ? "active" : "expired")
            XCTAssertEqual(updated.source?.lastCommunicationAt, metadata.source?.lastCommunicationAt,
                "A local mode change is not fresh sensor contact")
            XCTAssertEqual(updated.latestData, metadata.latestData)
            XCTAssertEqual(coordinator.activeSensor?.objectID, sensorID)
            XCTAssertEqual(try core.mainManagedObjectContext.count(for: BgReading.fetchRequest()), 1)
            XCTAssertEqual(notificationCenter.added.count, alertCount)
            XCTAssertEqual(shared.data(forKey: "latestReadings"), exportedData)
        }
        let metadataBeforeRejectedConfiguration = shared.data(forKey: XDripCGMMetadataEnvelope.appGroupKey)
        coordinator.sensorSessionConfigurationChanged(startDate: observation.start.addingTimeInterval(-60), from: transmitter)
        XCTAssertEqual(shared.data(forKey: XDripCGMMetadataEnvelope.appGroupKey), metadataBeforeRejectedConfiguration)
        let other = CGMSibionicsTransmitter(address: UUID().uuidString, name: "Replaced GS1 fixture", code: identity.sensorCode,
            mac: identity.mac.string, authorized: false, bluetoothTransmitterDelegate: bluetoothDelegate, cGMTransmitterDelegate: coordinator)
        defer { other.prepareForRelease() }
        coordinator.sensorSessionConfigurationChanged(startDate: observation.start, from: other)
        XCTAssertEqual(shared.data(forKey: XDripCGMMetadataEnvelope.appGroupKey), metadataBeforeRejectedConfiguration)

        for invalidation in ["off/on", "release"] {
            let authorization = try XCTUnwrap(GS1ExtendedReadingConsent.token(key))
            let current = Date()
            transmitter.publish([.init(index: 20170, date: current, mgdl: 120)],
                observation: .init(start: observation.start, latestSampleDate: current, identity: key, authorization: authorization))
            if invalidation == "release" { transmitter.prepareForRelease() }
            else {
                GS1ExtendedReadingConsent.setEnabled(false, identity: key)
                GS1ExtendedReadingConsent.setEnabled(true, identity: key)
            }
            let drained = expectation(description: "Invalidated full pipeline delivery drained: " + invalidation)
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 3)
            XCTAssertEqual(try core.mainManagedObjectContext.count(for: BgReading.fetchRequest()), 1, invalidation)
            XCTAssertEqual(coordinator.activeSensor?.objectID, sensorID, invalidation)
            XCTAssertEqual(coordinator.activeSensor?.startDate, observation.start, invalidation)
            XCTAssertEqual(notificationCenter.added.count, alertCount, invalidation)
            XCTAssertEqual(shared.data(forKey: "latestReadings"), exportedData, invalidation)
        }
    }

    func testQueuedExtendedDriverRejectsRevokedRenewedReleasedAndForeignAuthorization() throws {
        for invalidation in ["off", "off/on", "release", "foreign owner"] {
            let uuid = UUID(), identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
            let key = identity.checkpointIdentity(peripheralID: uuid), other = UUID().uuidString
            defer {
                GS1ExtendedReadingConsent.setEnabled(false, identity: key)
                GS1ExtendedReadingConsent.setEnabled(false, identity: other)
            }
            GS1ExtendedReadingConsent.setEnabled(true, identity: key)
            GS1ExtendedReadingConsent.setEnabled(true, identity: other)
            let token = try XCTUnwrap(GS1ExtendedReadingConsent.token(invalidation == "foreign owner" ? other : key))
            let delegate = GS1SessionDelegateSpy()
            let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 test", code: identity.sensorCode, mac: identity.mac.string,
                authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
            defer { transmitter.prepareForRelease() }
            let now = Date(), start = now.addingTimeInterval(-20165 * 60)
            transmitter.publish([.init(index: 20165, date: now, mgdl: 110)],
                observation: .init(start: start, latestSampleDate: now, identity: key, authorization: token))
            if invalidation == "release" { transmitter.prepareForRelease() }
            else if invalidation != "foreign owner" {
                GS1ExtendedReadingConsent.setEnabled(false, identity: key)
                if invalidation == "off/on" { GS1ExtendedReadingConsent.setEnabled(true, identity: key) }
            }
            let drained = expectation(description: "Invalidated extended delivery drained: " + invalidation)
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            XCTAssertTrue(delegate.starts.isEmpty, invalidation)
            XCTAssertEqual(delegate.glucoseBatches, 0, invalidation)
            XCTAssertEqual(delegate.heartbeats, 0, invalidation)
        }
    }

    func testExtendedConsentIsRecheckedBetweenMainQueueCallbacks() throws {
        let uuid = UUID(), identity = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let key = identity.checkpointIdentity(peripheralID: uuid)
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: key) }
        GS1ExtendedReadingConsent.setEnabled(true, identity: key)
        let token = try XCTUnwrap(GS1ExtendedReadingConsent.token(key)), delegate = GS1SessionDelegateSpy()
        let transmitter = CGMSibionicsTransmitter(address: uuid.uuidString, name: "GS1 test", code: identity.sensorCode, mac: identity.mac.string,
            authorized: false, bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        defer { transmitter.prepareForRelease() }
        let now = Date(), start = now.addingTimeInterval(-20165 * 60)
        delegate.onObserved = { GS1ExtendedReadingConsent.setEnabled(false, identity: key) }
        transmitter.publish([.init(index: 20165, date: now, mgdl: 110)],
            observation: .init(start: start, latestSampleDate: now, identity: key, authorization: token))
        let drained = expectation(description: "Mid-delivery consent withdrawal drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(delegate.starts, [start])
        XCTAssertEqual(delegate.glucoseBatches, 0)
        XCTAssertEqual(delegate.heartbeats, 0)
    }

    func testExtendedFinalCorrectionsEnterNormalPipelineAndPreserveJournalStartAndRecoveryGuards() throws {
        let base = try folder(), value = try session(base)
        defer { GS1ExtendedReadingConsent.setEnabled(false, identity: value.identity) }
        XCTAssertTrue(try feed(value, through: 20160).isEmpty)
        let originalStart = value.start, firstRecord = value.journal.records.first
        XCTAssertNil(value.liveObservation(at: baseTime.addingTimeInterval(20160 * 60)))
        GS1ExtendedReadingConsent.setEnabled(true, identity: value.identity)
        let authorization = try XCTUnwrap(GS1ExtendedReadingConsent.token(value.identity))
        let now = baseTime.addingTimeInterval(20165 * 60)
        let output = try value.ingest((20161...20165).map { sample($0, tail: 20165) }, received: now, now: now, extendedAuthorization: authorization)
        XCTAssertEqual(output.map(\.index), [20165])
        XCTAssertEqual(output.first?.date, now)
        XCTAssertEqual(value.liveObservation(at: now)?.start, originalStart)
        XCTAssertEqual(value.start, originalStart)
        XCTAssertEqual(value.journal.records.first, firstRecord)
        XCTAssertEqual(value.journal.records.count, 20165)
        GS1ExtendedReadingConsent.setEnabled(false, identity: value.identity)
        XCTAssertNil(value.liveObservation(at: now))
        GS1ExtendedReadingConsent.setEnabled(true, identity: value.identity)
        XCTAssertNil(value.liveObservation(at: now), "Renewed consent awaits fresh contact")
        let renewed = try XCTUnwrap(GS1ExtendedReadingConsent.token(value.identity))
        let later = now.addingTimeInterval(60)
        XCTAssertTrue(try value.ingest([sample(20166, tail: 20166)], received: later, now: later, extendedAuthorization: renewed).isEmpty)
        XCTAssertEqual(value.start, originalStart)

        let incomplete = baseTime.addingTimeInterval(20171 * 60)
        XCTAssertTrue(try value.ingest((20167...20170).map { sample($0, tail: 20171) }, received: incomplete, now: incomplete, extendedAuthorization: renewed).isEmpty)
        XCTAssertFalse(value.historyReady)
        GS1ExtendedReadingConsent.setEnabled(false, identity: value.identity)
        GS1ExtendedReadingConsent.setEnabled(true, identity: value.identity)
        let thirdAuthorization = try XCTUnwrap(GS1ExtendedReadingConsent.token(value.identity))
        XCTAssertTrue(try value.ingest([sample(20171, tail: 20171)], received: incomplete, now: incomplete, extendedAuthorization: thirdAuthorization).isEmpty)
        XCTAssertTrue(value.historyReady)
        let nextFinal = baseTime.addingTimeInterval(20175 * 60)
        XCTAssertEqual(try value.ingest((20172...20175).map { sample($0, tail: 20175) }, received: nextFinal, now: nextFinal, extendedAuthorization: thirdAuthorization).map(\.index), [20175])
        XCTAssertEqual(value.start, originalStart)

        let restored = try session(base), firstTail = baseTime.addingTimeInterval(20180 * 60)
        XCTAssertNil(restored.liveObservation(at: nextFinal))
        XCTAssertTrue(try restored.ingest((20176...20180).map { sample($0, tail: 20180) }, received: firstTail,
            now: firstTail, extendedAuthorization: thirdAuthorization).isEmpty)
        XCTAssertEqual(restored.baselineTailIndex, 20180)
        let fresh = baseTime.addingTimeInterval(20185 * 60)
        XCTAssertEqual(try restored.ingest((20181...20185).map { sample($0, tail: 20185) }, received: fresh,
            now: fresh, extendedAuthorization: thirdAuthorization).map(\.index), [20185])
        XCTAssertEqual(restored.liveObservation(at: fresh)?.start, originalStart)
        XCTAssertEqual(restored.start, originalStart)
        XCTAssertEqual(restored.journal.records.first, firstRecord)
    }
    func testCheckpointAndFullJournalReplayHaveIdenticalCoreState() throws {
        let base = try folder(), first = try session(base)
        _ = try feed(first, through: 120)
        let saved = try XCTUnwrap(first.journal.loadCheckpoint())
        let restored = try session(base)
        XCTAssertEqual(restored.nextIndex, 121)
        XCTAssertEqual(restored.start, first.start)
        let replayBase = try folder()
        let replayDirectory = replayBase.appendingPathComponent(first.journal.directory.lastPathComponent)
        try FileManager.default.copyItem(at: first.journal.directory, to: replayDirectory)
        try FileManager.default.removeItem(at: replayDirectory.appendingPathComponent("checkpoint.json"))
        let replayed = try session(replayBase)
        XCTAssertEqual(replayed.nextIndex, restored.nextIndex)
        let received = baseTime.addingTimeInterval(121*60)
        _ = try restored.ingest([sample(121, tail: 121)], received: received, now: received)
        let checkpointFromRestore = try XCTUnwrap(restored.journal.loadCheckpoint()).core
        // Replay and restore use separate stores; both process the same next minute.
        _ = try replayed.ingest([sample(121, tail: 121)], received: received, now: received)
        XCTAssertEqual(try XCTUnwrap(replayed.journal.loadCheckpoint()).core, checkpointFromRestore)
        XCTAssertEqual(saved.start, baseTime)
    }
    func testCheckpointWithInconsistentStartCannotReanchorSession() throws {
        let base = try folder(), original = try session(base)
        _ = try feed(original, through: 70)
        let saved = try XCTUnwrap(original.journal.loadCheckpoint())
        try original.journal.saveCheckpoint(core: saved.core, index: saved.index, start: baseTime.addingTimeInterval(1800), confirmed: true)
        let restored = try session(base)
        XCTAssertEqual(restored.start, baseTime)
        XCTAssertEqual(restored.nextIndex, 71)
    }

    func testCorruptCheckpointReplaysContiguousJournal() throws {
        let base = try folder(), original = try session(base)
        _ = try feed(original, through: 70)
        try Data("broken".utf8).write(to: original.journal.directory.appendingPathComponent("checkpoint.json"))
        let replay = try session(base)
        XCTAssertEqual(replay.nextIndex, 71)
        XCTAssertEqual(replay.start, baseTime)
        XCTAssertTrue(replay.startConfirmed)
    }
    func testCorruptOrPartialJournalCannotPublishOrRestore() throws {
        let base = try folder(), original = try session(base)
        _ = try feed(original, through: 3)
        let url = original.journal.directory.appendingPathComponent("source.jsonl")
        var data = try Data(contentsOf: url); data.append(Data("partial".utf8)); try data.write(to: url)
        XCTAssertThrowsError(try session(base))
    }
    func testIdentityCodeMACAndUUIDEachIsolateState() throws {
        let base = try folder()
        let id = try GS1CNIdentity(sensorCode: "GEPD802J", mac: GS1MAC("11:22:33:44:55:66"))
        let uuid = UUID()
        let original = try session(base, identity: id.checkpointIdentity(peripheralID: uuid))
        _ = try feed(original, through: 3)
        let changedCode = try GS1CNIdentity(sensorCode: "46HU804E", mac: id.mac)
        let changedMAC = try GS1CNIdentity(sensorCode: id.sensorCode, mac: GS1MAC("11:22:33:44:55:67"))
        for key in [changedCode.checkpointIdentity(peripheralID: uuid), changedMAC.checkpointIdentity(peripheralID: uuid), id.checkpointIdentity(peripheralID: UUID())] {
            XCTAssertEqual(try session(base, identity: key).nextIndex, 1)
        }
    }
    func testGapRequestsEarliestMissingMinuteWithoutAdvancing() throws {
        let value = try session(folder())
        XCTAssertTrue(try value.ingest([sample(4, tail: 4)], received: baseTime, now: baseTime).isEmpty)
        XCTAssertEqual(value.nextIndex, 1)
        XCTAssertFalse(value.historyReady)
        XCTAssertNil(value.start)
    }
    func testDuplicateNeverReanchorsAndConflictIsRejected() throws {
        let value = try session(folder())
        _ = try feed(value, through: 2)
        let start = value.start, originalDate = value.journal.records[1].timestamp
        let later = baseTime.addingTimeInterval(300)
        XCTAssertTrue(try value.ingest([sample(2, tail: 2)], received: later, now: later).isEmpty)
        XCTAssertEqual(value.start, start)
        XCTAssertEqual(value.journal.records[1].timestamp, originalDate)
        XCTAssertThrowsError(try value.ingest([sample(2, tail: 2, chemical: 101)], received: later, now: later))
        XCTAssertEqual(value.nextIndex, 3)
    }
    func testJournalAheadRetryUsesOriginalSignalAndTimestamp() throws {
        let value = try session(folder())
        let persisted = GS1SourceRecord(sample(1, tail: 1), received: baseTime.addingTimeInterval(60))
        try value.journal.append(persisted) // Simulates append completing before core/checkpoint.
        let later = baseTime.addingTimeInterval(120)
        XCTAssertThrowsError(try value.ingest([sample(1, tail: 1, chemical: 101)], received: later, now: later))
        XCTAssertEqual(value.nextIndex, 1)
        _ = try value.ingest([sample(1, tail: 1)], received: later, now: later)
        XCTAssertEqual(value.start, baseTime)
        XCTAssertEqual(value.journal.records.count, 1)
        XCTAssertEqual(value.journal.records[0], persisted)
    }
    func testReceiveClockValidationRejectsNonFiniteFutureAndInvalidEpochWithoutInventingAnchor() throws {
        let value = try session(folder()); _ = try feed(value, through: 2)
        let jump = baseTime.addingTimeInterval(3600)
        XCTAssertThrowsError(try value.ingest([sample(3, tail: 3)], received: jump, now: jump.addingTimeInterval(-10)))
        XCTAssertEqual(value.nextIndex, 3)
        XCTAssertTrue(try value.ingest([sample(3, tail: 3)], received: jump, now: jump).isEmpty)
        XCTAssertEqual(value.nextIndex, 4)
        XCTAssertEqual(value.start, baseTime)
        for interval in [Double.nan, .infinity, -.infinity] {
            let invalid = Date(timeIntervalSince1970: interval)
            for (received, now) in [(invalid, baseTime), (baseTime, invalid)] {
                XCTAssertThrowsError(try value.ingest([sample(4, tail: 4)], received: received, now: now))
                guard case .invalidClock? = value.timelineIssue else { return XCTFail("Invalid clock must remain terminal") }
                XCTAssertEqual(value.nextIndex, 4)
            }
        }
        let first = try session(folder()), received = Date(timeIntervalSince1970: 946_771_200)
        XCTAssertThrowsError(try first.ingest([sample(1, tail: 2001)], received: received, now: received))
        guard case .invalidRecord? = first.timelineIssue else { return XCTFail("Invalid event epoch must remain rejected") }
        XCTAssertEqual(first.nextIndex, 1)
        XCTAssertTrue(first.journal.records.isEmpty)
    }
    func testJournalWithInvalidEpochCannotBeRestoredEvenWithValidNativeCheckpoint() throws {
        let (base, journal) = try legacyStore([-1_790_000_000, 120, 180])
        XCTAssertNotNil(journal.loadCheckpoint())
        XCTAssertThrowsError(try session(base))
    }
    func testHistoricalAndWarmupSamplesNeverBecomeFreshGlucose() throws {
        let warmup = try session(folder())
        XCTAssertTrue(try feed(warmup, through: 59).isEmpty)
        let historical = try session(folder())
        let received = baseTime.addingTimeInterval(120*60)
        XCTAssertTrue(try historical.ingest((1...100).map { sample($0, tail: 120) }, received: received, now: received).isEmpty)
        XCTAssertFalse(historical.historyReady)
        let stale = try session(folder())
        XCTAssertTrue(try stale.ingest((1...120).map { sample($0, tail: 120) }, received: received, now: received.addingTimeInterval(300)).isEmpty)
    }
    func testFactoryWarmupLifetimeAndFreshnessBoundaries() {
        let date = baseTime.addingTimeInterval(3600)
        XCTAssertTrue(GS1Policy.mayPublish(index: 60, timestamp: date, start: baseTime, now: date, live: true, confirmed: true))
        XCTAssertFalse(GS1Policy.mayPublish(index: 59, timestamp: date, start: baseTime, now: date, live: true, confirmed: true))
        XCTAssertFalse(GS1Policy.mayPublish(index: 60, timestamp: date, start: baseTime, now: date.addingTimeInterval(-1), live: true, confirmed: true))
        XCTAssertFalse(GS1Policy.mayPublish(index: 60, timestamp: date, start: baseTime, now: date.addingTimeInterval(121), live: true, confirmed: true))
        XCTAssertFalse(GS1Policy.mayPublish(index: 60, timestamp: date, start: baseTime, now: date, live: false, confirmed: true))
        XCTAssertFalse(GS1Policy.mayPublish(index: 20160, timestamp: baseTime.addingTimeInterval(GS1Policy.lifetime), start: baseTime, now: baseTime.addingTimeInterval(GS1Policy.lifetime), live: true, confirmed: true))
    }
    func testFactoryLifetimeIndexCannotPublishAfterFourteenDaysDespiteNegativeClockDrift() {
        for drift: TimeInterval in [-120, -60, 0] {
            let timestamp = baseTime.addingTimeInterval(GS1Policy.lifetime + drift)
            XCTAssertFalse(GS1Policy.mayPublish(index: 20160, timestamp: timestamp, start: baseTime, now: timestamp, live: true, confirmed: true))
        }
    }
    func testZeroSignalHasNoRawFallback() throws {
        let value = try session(folder()), received = baseTime.addingTimeInterval(120*60)
        let readings = try value.ingest((1...120).map { sample($0, tail: 120, chemical: 0) }, received: received, now: received)
        XCTAssertTrue(readings.isEmpty)
        XCTAssertEqual(value.nextIndex, 121)
    }
    func testFinalReadingsKeepOriginalTimestampAndFiveMinuteCadence() throws {
        let value = try session(folder())
        var readings: [GS1Session.Reading] = []
        for index in 1...300 { readings += try feed(value, through: index) }
        XCTAssertFalse(readings.isEmpty)
        for reading in readings {
            XCTAssertEqual(reading.index % 5, 0)
            XCTAssertEqual(reading.date, baseTime.addingTimeInterval(Double(reading.index)*60))
            XCTAssertGreaterThanOrEqual(reading.index, 60)
            XCTAssertTrue(reading.mgdl.isFinite && reading.mgdl > 0)
        }
    }
    func testCorrectionBeforeTailIsNeverPromotedFromSameOrSeparatePackets() throws {
        for separate in [false, true] {
            let value = try session(folder()); _ = try feed(value, through: 64)
            let received = baseTime.addingTimeInterval(66 * 60)
            if separate {
                XCTAssertTrue(try value.ingest([sample(65, tail: 66)], received: received, now: received).isEmpty)
                XCTAssertTrue(try value.ingest([sample(66, tail: 66)], received: received, now: received).isEmpty)
            } else {
                XCTAssertTrue(try value.ingest([sample(65, tail: 66), sample(66, tail: 66)], received: received, now: received).isEmpty)
            }
            XCTAssertTrue(value.historyReady)
            XCTAssertEqual(try feed(value, through: 70).map(\.index), [70])
        }
    }
    func testGapRecoveryDoesNotPublishAnEarlierFinalCorrection() throws {
        let value = try session(folder()); _ = try feed(value, through: 64)
        let firstReceipt = baseTime.addingTimeInterval(66 * 60)
        XCTAssertTrue(try value.ingest([sample(65, tail: 66)], received: firstReceipt, now: firstReceipt).isEmpty)
        let received = baseTime.addingTimeInterval(67 * 60)
        XCTAssertTrue(try value.ingest([sample(67, tail: 67)], received: received, now: received).isEmpty)
        XCTAssertEqual(value.nextIndex, 66); XCTAssertFalse(value.historyReady)
        XCTAssertTrue(try value.ingest([sample(66, tail: 67), sample(67, tail: 67)], received: received, now: received).isEmpty)
        XCTAssertEqual(try feed(value, through: 70).map(\.index), [70])
    }
    func testStaleOrFutureCurrentTailCorrectionNeverPublishesOrChangesItsDate() throws {
        for delay: TimeInterval in [121, -1] {
            let value = try session(folder()); _ = try feed(value, through: 64)
            let received = baseTime.addingTimeInterval(65 * 60)
            XCTAssertTrue(try value.ingest([sample(65, tail: 65)], received: received, now: received.addingTimeInterval(delay)).isEmpty)
            XCTAssertEqual(value.journal.records.last?.timestamp, received)
            XCTAssertTrue(try value.ingest([sample(65, tail: 65)], received: received, now: received).isEmpty)
            XCTAssertEqual(try feed(value, through: 70).map(\.index), [70])
        }
    }
    func testFreshnessBoundaryUsesImmutableCorrectionTimeAtIngestion() throws {
        for delay: TimeInterval in [120, 121] {
            let value = try session(folder()); _ = try feed(value, through: 64)
            let received = baseTime.addingTimeInterval(65 * 60)
            let readings = try value.ingest([sample(65, tail: 65)], received: received, now: received.addingTimeInterval(delay))
            XCTAssertEqual(readings.map(\.index), delay == 120 ? [65] : [])
            if let reading = readings.first { XCTAssertEqual(reading.date, received) }
        }
    }
    func testWarmupAndRestartNeverPromoteEarlierCorrection() throws {
        let warmup = try session(folder()); _ = try feed(warmup, through: 54)
        XCTAssertTrue(try feed(warmup, through: 55).isEmpty)
        let base = try folder(), first = try session(base); _ = try feed(first, through: 64)
        let received = baseTime.addingTimeInterval(66 * 60)
        XCTAssertTrue(try first.ingest([sample(65, tail: 66)], received: received, now: received).isEmpty)
        let restored = try session(base)
        XCTAssertTrue(try restored.ingest([sample(66, tail: 66)], received: received, now: received).isEmpty)
        XCTAssertEqual(restored.baselineTailIndex, 66)
    }
    func testStrictDeviceInformationMACAndCandidateMatching() {
        XCTAssertEqual(GS1Setup.readOnlyMAC(Data("11:22:33:44:55:66".utf8))?.string, "11:22:33:44:55:66")
        for invalid in ["112233445566", "11-22-33-44-55-66", "SERIAL12345678901", "11:22:33:44:55:66\0", UUID().uuidString] {
            XCTAssertNil(GS1Setup.readOnlyMAC(Data(invalid.utf8)))
        }
        XCTAssertTrue(GS1Setup.matches(name: "LT2309GEPD", code: "GEPD802J"))
        XCTAssertFalse(GS1Setup.matches(name: "LT2309OTHR", code: "GEPD802J"))
        XCTAssertNil(GS1Setup.normalizedCode("UNKNOWN!"))
    }

    // Invented static-random address bytes; these are not captured hardware data.
    private var syntheticGS1SerialBytes: Data { Data([0x12, 0x34, 0x56, 0x78, 0x9a, 0xc2]) }
    private let syntheticGS1SerialMAC = "C2:9A:78:56:34:12"

    func testGS1RawDeviceInformationMACUsesReversedSixByteOrder() {
        let mac = GS1Setup.readOnlyMAC(syntheticGS1SerialBytes, model: "GS1", manufacturer: "SISENSING")
        XCTAssertEqual(mac?.string, syntheticGS1SerialMAC)
        XCTAssertNotEqual(mac?.string, "12:34:56:78:9A:C2")
    }

    func testGS1RawMACRequiresBothExactNormalizedModelAndManufacturer() {
        XCTAssertEqual(GS1Setup.readOnlyMAC(syntheticGS1SerialBytes, model: " \tgs1\n", manufacturer: " sisensing \r")?.string,
            syntheticGS1SerialMAC)
        let cases: [(String?, String?)] = [(nil, nil), ("GS1", nil), (nil, "SISENSING"),
            ("", "SISENSING"), ("GS3", "SISENSING"), ("GS1-7", "SISENSING"),
            ("GS1", ""), ("GS1", "Other Manufacturer"), ("GS1", "SISENSING INC")]
        for (model, manufacturer) in cases {
            XCTAssertNil(GS1Setup.readOnlyMAC(syntheticGS1SerialBytes, model: model, manufacturer: manufacturer))
        }
    }

    func testGS1RawMACRejectsEmptyBroadcastASCIIAndWrongLengthSerials() {
        let invalid = [Data(), Data(repeating: 0, count: 6), Data(repeating: 0xff, count: 6), Data([0, 0, 0, 0, 0, 0xc0]),
            Data("ABCDEF".utf8), Data("123456".utf8), Data("123456789012".utf8),
            Data([0x12, 0x34, 0x56, 0x78, 0xc2]), Data([0x12, 0x34, 0x56, 0x78, 0x9a, 0xb1, 0xc2])]
        for serial in invalid {
            XCTAssertNil(GS1Setup.readOnlyMAC(serial, model: "GS1", manufacturer: "SISENSING"))
        }
    }

    func testGS1RawMACRejectsUnobservedAddressSchemas() {
        for lastByte: UInt8 in [0x02, 0x42, 0x82] {
            let serial = Data([0x12, 0x34, 0x56, 0x78, 0x9a, lastByte])
            XCTAssertNil(GS1Setup.readOnlyMAC(serial, model: "GS1", manufacturer: "SISENSING"))
        }
    }

    func testLegacyDeviceInformationASCII17MACDoesNotNeedTheRawGS1FamilyEvidence() {
        let serial = Data("11:22:33:44:55:66".utf8)
        XCTAssertEqual(GS1Setup.readOnlyMAC(serial)?.string, "11:22:33:44:55:66")
        XCTAssertEqual(GS1Setup.readOnlyMAC(serial, model: "Other Model", manufacturer: "Other Manufacturer")?.string,
            "11:22:33:44:55:66")
        XCTAssertEqual(GS1Setup.deviceInformationMAC(["2A25": serial])?.string, "11:22:33:44:55:66")
    }

    func testGS1DeviceInformationTrimsUTF8FieldWhitespaceAndNULTerminators() {
        let fields: [String: Data] = ["2A25": syntheticGS1SerialBytes,
            "2A24": Data("\0 \tGS1\n\0".utf8), "2A29": Data("\tSISENSING \0\r".utf8)]
        XCTAssertEqual(GS1Setup.deviceInformationMAC(fields)?.string, syntheticGS1SerialMAC)
    }

    func testGS1RawMACNeedsAllThreeDeviceInformationFieldsInEveryArrivalOrder() {
        let source: [String: Data] = ["2A25": syntheticGS1SerialBytes,
            "2A24": Data("GS1".utf8), "2A29": Data("SISENSING".utf8)]
        let orders = [["2A25", "2A24", "2A29"], ["2A25", "2A29", "2A24"],
            ["2A24", "2A25", "2A29"], ["2A24", "2A29", "2A25"],
            ["2A29", "2A25", "2A24"], ["2A29", "2A24", "2A25"]]
        for order in orders {
            var received: [String: Data] = [:]
            for (index, key) in order.enumerated() {
                received[key] = source[key]
                if index < 2 { XCTAssertNil(GS1Setup.deviceInformationMAC(received), order.description) }
                else { XCTAssertEqual(GS1Setup.deviceInformationMAC(received)?.string, syntheticGS1SerialMAC, order.description) }
            }
        }
    }

    func testGS1DeviceInformationCannotResolveFromCorruptOrWrongFamilyFields() {
        let valid: [String: Data] = ["2A25": syntheticGS1SerialBytes,
            "2A24": Data("GS1".utf8), "2A29": Data("SISENSING".utf8)]
        for key in ["2A24", "2A29"] {
            var malformed = valid
            malformed[key] = Data([0xff, 0xfe])
            XCTAssertNil(GS1Setup.deviceInformationMAC(malformed))
        }
        var wrongModel = valid
        wrongModel["2A24"] = Data("GS3".utf8)
        XCTAssertNil(GS1Setup.deviceInformationMAC(wrongModel))
        var missingSerial = valid
        missingSerial.removeValue(forKey: "2A25")
        XCTAssertNil(GS1Setup.deviceInformationMAC(missingSerial))
    }

    func testDeliveryGateInvalidatesQueuedOldCallback() throws {
        let gate = CGMDeliveryGate(), old = try XCTUnwrap(gate.token())
        gate.invalidate()
        XCTAssertFalse(gate.allows(old))
        XCTAssertNotNil(gate.token())
    }
    func testStoppedDeliveryGateRejectsOldAndNewCallbacks() throws {
        let gate = CGMDeliveryGate(), old = try XCTUnwrap(gate.token())
        gate.stop()
        XCTAssertFalse(gate.allows(old))
        XCTAssertNil(gate.token())
    }
    func testReleasedDeliveryGateIsPermanent() {
        let gate = CGMDeliveryGate()
        gate.release(); gate.invalidate()
        XCTAssertTrue(gate.isReleased)
        XCTAssertNil(gate.token())
    }

    // MARK: - Chinese stream pacing, using a deterministic monotonic clock

    func testGS1SingleRequestConsumesMultipleFramesUntilTheQuietTail() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        for time: TimeInterval in [2, 4, 6, 8] {
            pacing.receivedDataFrame(at: time, advanced: true)
            XCTAssertFalse(pacing.requestSent(at: time + 0.25), "An intermediate frame is not a page boundary")
            XCTAssertEqual(pacing.timerFired(at: time + 1), .none)
        }
        XCTAssertEqual(pacing.nextDeadline, 68)
        XCTAssertEqual(pacing.timerFired(at: 67.999), .none)
        XCTAssertEqual(pacing.timerFired(at: 68), .request)
        XCTAssertTrue(pacing.requestSent(at: 68))
    }

    func testGS1FirstResponseGetsThirtySecondsAndFragmentsCannotMakeItInfinite() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        for time: TimeInterval in [5, 15, 29] { pacing.receivedNotificationFragment(at: time) }
        XCTAssertEqual(pacing.nextDeadline, 30)
        XCTAssertEqual(pacing.timerFired(at: 29.999), .none)
        XCTAssertEqual(pacing.timerFired(at: 30), .responseTimeout)
        XCTAssertTrue(pacing.isDraining)
        XCTAssertFalse(pacing.requestSent(at: 31))
        XCTAssertEqual(pacing.timerFired(at: 89.999), .none)
        XCTAssertEqual(pacing.timerFired(at: 90), .request)
    }

    func testGS1DuplicateStreamCannotRenewTheIncompleteHistoryProgressDeadline() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        pacing.receivedDataFrame(at: 1, advanced: true)
        for time: TimeInterval in [20, 60, 100, 140, 180] {
            pacing.receivedDataFrame(at: time, advanced: false)
            XCTAssertFalse(pacing.requestSent(at: time + 0.25))
            XCTAssertEqual(pacing.timerFired(at: time), .none)
        }
        XCTAssertEqual(pacing.nextDeadline, 181)
        XCTAssertEqual(pacing.timerFired(at: 181), .noProgress)
    }

    func testGS1RealProgressRenewsTheWatchdogWhileQuietPollRemainsSixtySeconds() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        for time: TimeInterval in [1, 50, 100, 150, 200, 250] {
            pacing.receivedDataFrame(at: time, advanced: true)
            XCTAssertEqual(pacing.timerFired(at: time), .none)
        }
        pacing.receivedDataFrame(at: 300, advanced: true)
        XCTAssertEqual(pacing.nextDeadline, 360)
        XCTAssertEqual(pacing.timerFired(at: 360), .request)
    }

    func testGS1RepeatedFormerLiveTailCannotKeepAStaleConnectionBusyForever() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        pacing.receivedDataFrame(at: 1, advanced: true)
        // The session may still have historyReady=true from this original tail.
        // Pacing counts accepted indices rather than that persisted Boolean.
        for time: TimeInterval in [30, 80, 130, 180] {
            pacing.receivedDataFrame(at: time, advanced: false)
            XCTAssertFalse(pacing.requestSent(at: time))
        }
        XCTAssertEqual(pacing.timerFired(at: 181), .noProgress)

        pacing = GS1StreamPacing() // Reconnect with the same saved tail.
        XCTAssertTrue(pacing.requestSent(at: 200))
        for time: TimeInterval in [201, 250, 300, 350] {
            pacing.receivedDataFrame(at: time, advanced: false)
        }
        XCTAssertEqual(pacing.timerFired(at: 380), .noProgress)
    }

    func testGS1RejectedResponseDrainsWithoutOverlappingTheNextRequest() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        pacing.receivedDataFrame(at: 1, advanced: true)
        pacing.rejectStream(at: 2, advanced: true)
        for time: TimeInterval in [3, 4, 5] {
            pacing.receivedDataFrame(at: time, advanced: false)
            XCTAssertTrue(pacing.isDraining)
            XCTAssertFalse(pacing.requestSent(at: time + 1))
        }
        XCTAssertEqual(pacing.timerFired(at: 64.999), .none)
        XCTAssertEqual(pacing.timerFired(at: 65), .request)
        XCTAssertFalse(pacing.isDraining)
        XCTAssertTrue(pacing.requestSent(at: 65))
        // Quiet and a retry do not replace the original no-progress deadline.
        pacing.receivedDataFrame(at: 70, advanced: false)
        pacing.receivedDataFrame(at: 120, advanced: false)
        pacing.receivedDataFrame(at: 170, advanced: false)
        XCTAssertEqual(pacing.timerFired(at: 182), .noProgress)
    }

    func testGS1PartialFrameCrossingQuietBoundaryDefersPollWithoutLosingBytes() throws {
        var pacing = GS1StreamPacing(), assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertTrue(pacing.requestSent(at: 0))
        let first = syntheticGS1Response(count: 3, fixed: true), second = syntheticGS1Response(count: 9, fixed: true)
        XCTAssertEqual(try assembler.append(first), [try GS1ChineseProtocol.parse(first)])
        pacing.receivedDataFrame(at: 1, advanced: true)
        pacing.receivedNotificationFragment(at: 60.5)
        XCTAssertTrue(try assembler.append(Data(second.prefix(47))).isEmpty)
        XCTAssertEqual(pacing.timerFired(at: 61), .none, "A pending fragment is incoming stream activity")
        XCTAssertFalse(pacing.requestSent(at: 61))
        XCTAssertEqual(try assembler.append(Data(second.dropFirst(47))), [try GS1ChineseProtocol.parse(second)])
        pacing.receivedDataFrame(at: 61.5, advanced: true)
        XCTAssertEqual(pacing.timerFired(at: 121.5), .request)
        // A first-response retry also preserves already buffered frame bytes.
        XCTAssertTrue(pacing.requestSent(at: 121.5))
        XCTAssertTrue(try assembler.append(Data(first.prefix(100))).isEmpty)
        XCTAssertEqual(pacing.timerFired(at: 151.5), .responseTimeout)
        XCTAssertEqual(pacing.timerFired(at: 211.5), .request)
        XCTAssertTrue(pacing.requestSent(at: 211.5))
        XCTAssertEqual(try assembler.append(Data(first.dropFirst(100))), [try GS1ChineseProtocol.parse(first)])
    }

    func testGS1FragmentsAndEmptyFramesDoNotHideMissingHistoryForever() {
        var pacing = GS1StreamPacing()
        XCTAssertTrue(pacing.requestSent(at: 0))
        pacing.receivedDataFrame(at: 1, advanced: false)
        for time: TimeInterval in [30, 60, 90, 120, 150, 179] { pacing.receivedNotificationFragment(at: time) }
        XCTAssertEqual(pacing.nextDeadline, 180)
        XCTAssertEqual(pacing.timerFired(at: 180), .noProgress)
    }

    // MARK: - Synthetic AA55 fixed ten-slot responses

    private func syntheticGS1Response(count: Int, fixed: Bool, validCompactPrefix: Bool = false) -> Data {
        precondition((0...255).contains(count) && (!fixed || count <= 10))
        var bytes: [UInt8] = [0xaa, 0x55, 0x09, UInt8(count)]
        for index in 1..<(count + 1) {
            // Invented minute records. No captured sensor or medical data is used.
            for value in [index, 320, 80, 100, 0, count - index, 0] {
                bytes += [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
            }
        }
        if validCompactPrefix {
            precondition(fixed && count > 0 && count < 10)
            // Make the compact-length prefix independently checksum-valid even
            // though the transport's real checksum is at byte 144.
            let adjustment = UInt8(truncatingIfNeeded: -bytes.reduce(0) { $0 + Int($1) })
            bytes[4 + (count - 1) * 14 + 9] = adjustment
        }
        if fixed { bytes += [UInt8](repeating: 0, count: 14 * (10 - count)) }
        bytes.append(UInt8(truncatingIfNeeded: -bytes.reduce(0) { $0 + Int($1) }))
        return Data(bytes)
    }

    private func syntheticGS1Echo() -> Data {
        var bytes: [UInt8] = [0xaa, 0x55, 0x07, 0x01, 0x00, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11]
        bytes += [UInt8](repeating: 0, count: 8)
        bytes.append(UInt8(truncatingIfNeeded: -bytes.reduce(0) { $0 + Int($1) }))
        return Data(bytes)
    }

    func testGS1ParserAcceptsExactCompactAndFixedTenSlotCounts() throws {
        for count in [0, 1, 3, 9, 10] {
            let expected = GS1Packet.samples((0..<count).map { sample($0 + 1, tail: count) })
            let compact = syntheticGS1Response(count: count, fixed: false)
            let fixed = syntheticGS1Response(count: count, fixed: true)
            XCTAssertEqual(compact.count, 5 + 14 * count)
            XCTAssertEqual(fixed.count, 145)
            XCTAssertEqual(try GS1ChineseProtocol.parse(compact), expected)
            XCTAssertEqual(try GS1ChineseProtocol.parse(fixed), expected)
        }
    }

    func testGS1FixedLayoutRejectsElevenRecordsWithoutChangingCompactCompatibility() throws {
        let compact = syntheticGS1Response(count: 11, fixed: false)
        XCTAssertEqual(compact.count, 159)
        XCTAssertEqual(try GS1ChineseProtocol.parse(compact), .samples((1...11).map { sample($0, tail: 11) }))
        var invalidFixed = [UInt8](syntheticGS1Response(count: 10, fixed: true))
        invalidFixed[3] = 11
        invalidFixed[144] = UInt8(truncatingIfNeeded: -invalidFixed.prefix(144).reduce(0) { $0 + Int($1) })
        XCTAssertThrowsError(try GS1ChineseProtocol.parse(Data(invalidFixed)))
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertThrowsError(try assembler.append(Data(invalidFixed)))
    }

    func testGS1FixedPaddingMustBeZeroEvenWhenTheWholePacketChecksumIsValid() throws {
        var bytes = [UInt8](syntheticGS1Response(count: 3, fixed: true))
        bytes[4 + 3 * 14] = 1
        bytes[144] = UInt8(truncatingIfNeeded: -bytes.prefix(144).reduce(0) { $0 + Int($1) })
        XCTAssertEqual(GS1ChineseProtocol.checksum(bytes), 0)
        XCTAssertThrowsError(try GS1ChineseProtocol.parse(Data(bytes))) {
            XCTAssertEqual($0 as? GS1ProtocolError, .wrongLength)
        }
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertThrowsError(try assembler.append(Data(bytes)))
        let valid = syntheticGS1Response(count: 3, fixed: true)
        XCTAssertEqual(try assembler.append(valid), [try GS1ChineseProtocol.parse(valid)])
    }

    func testGS1FixedFinalChecksumFailureDoesNotLeakSamplesAndResetsTheAssembler() throws {
        let valid = syntheticGS1Response(count: 3, fixed: true)
        var corrupt = [UInt8](valid)
        corrupt[144] ^= 1
        XCTAssertThrowsError(try GS1ChineseProtocol.parse(Data(corrupt))) {
            XCTAssertEqual($0 as? GS1ProtocolError, .checksum)
        }
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertThrowsError(try assembler.append(Data(corrupt)))
        XCTAssertEqual(try assembler.append(valid), [try GS1ChineseProtocol.parse(valid)])
    }

    func testGS1FixedLayoutWaitsForAll145BytesAtEverySplit() throws {
        for count in [1, 3, 9, 10] {
            let packet = syntheticGS1Response(count: count, fixed: true)
            let expected = try GS1ChineseProtocol.parse(packet)
            for split in 1..<145 {
                var assembler = GS1PacketAssembler(layout: .fixed10)
                XCTAssertTrue(try assembler.append(Data(packet.prefix(split))).isEmpty, "count=\(count), split=\(split)")
                XCTAssertEqual(try assembler.append(Data(packet.dropFirst(split))), [expected], "count=\(count), split=\(split)")
            }
        }
    }

    func testGS1FixedLayoutDoesNotEmitEarlyWhenNotificationsArriveOneByteAtATime() throws {
        let packet = syntheticGS1Response(count: 3, fixed: true)
        var assembler = GS1PacketAssembler(layout: .fixed10)
        for (offset, byte) in packet.enumerated() {
            let parsed = try assembler.append(Data([byte]))
            if offset < 144 { XCTAssertTrue(parsed.isEmpty, "offset=\(offset)") }
            else { XCTAssertEqual(parsed, [try GS1ChineseProtocol.parse(packet)]) }
        }
    }

    func testGS1FixedLayoutDoesNotConsumeAnAccidentallyValidCompactPrefix() throws {
        let packet = syntheticGS1Response(count: 3, fixed: true, validCompactPrefix: true)
        let compactLength = 5 + 3 * 14
        let prefix = Data(packet.prefix(compactLength))
        let expected = try GS1ChineseProtocol.parse(packet)
        XCTAssertEqual(try GS1ChineseProtocol.parse(prefix), expected)
        var compactAssembler = GS1PacketAssembler() // Legacy default remains compact.
        XCTAssertEqual(try compactAssembler.append(prefix), [expected])
        var fixedAssembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertTrue(try fixedAssembler.append(prefix).isEmpty)
        XCTAssertEqual(try fixedAssembler.append(Data(packet.dropFirst(compactLength))), [expected])
    }

    func testGS1FullRequestEchoCanPrecedeAFixed145ByteReply() throws {
        let echo = syntheticGS1Echo()
        let packet = syntheticGS1Response(count: 3, fixed: true)
        XCTAssertEqual(echo.count, 20)
        XCTAssertEqual(try GS1ChineseProtocol.parse(echo), .echo)
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertEqual(try assembler.append(echo + packet), [.echo, try GS1ChineseProtocol.parse(packet)])
    }

    func testGS1ShortEchoLookaheadWaitsForTheFixedTransportFrame() throws {
        let packet = syntheticGS1Response(count: 3, fixed: true, validCompactPrefix: true)
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertTrue(try assembler.append(Data([0xaa, 0x55, 0x07])).isEmpty)
        // This prefix is valid compact data, but not a complete fixed response.
        XCTAssertTrue(try assembler.append(Data(packet.prefix(47))).isEmpty)
        XCTAssertEqual(try assembler.append(Data(packet.dropFirst(47))), [.echo, try GS1ChineseProtocol.parse(packet)])
    }

    func testGS1AssemblerCanConsumeTwoFixedFramesWithoutLosingTheSecondHeader() throws {
        let first = syntheticGS1Response(count: 3, fixed: true)
        let second = syntheticGS1Response(count: 9, fixed: true)
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertEqual(try assembler.append(first + second), [try GS1ChineseProtocol.parse(first), try GS1ChineseProtocol.parse(second)])
    }

    func testGS1FixedLayoutAlsoAcceptsTheCanonicalFiveByteEmptyResponse() throws {
        let empty = Data([0xaa, 0x55, 0x09, 0x00, 0xf8])
        XCTAssertEqual(try GS1ChineseProtocol.parse(empty), .samples([]))
        var assembler = GS1PacketAssembler(layout: .fixed10)
        XCTAssertTrue(try assembler.append(Data(empty.prefix(4))).isEmpty)
        XCTAssertEqual(try assembler.append(Data(empty.suffix(1))), [.samples([])])
        let fixedEmpty = syntheticGS1Response(count: 0, fixed: true)
        XCTAssertEqual(try assembler.append(fixedEmpty), [.samples([])])
    }

    func testThreeCompleteFixedRecordsAdvanceTheWarmupJournalWithoutPublishingGlucose() throws {
        var assembler = GS1PacketAssembler(layout: .fixed10)
        let packets = try assembler.append(syntheticGS1Response(count: 3, fixed: true))
        guard case .samples(let samples)? = packets.first else { return XCTFail("Expected complete raw records") }
        let value = try session(folder())
        let receipt = baseTime.addingTimeInterval(180)
        XCTAssertTrue(try value.ingest(samples, received: receipt, now: receipt).isEmpty)
        XCTAssertEqual(value.nextIndex, 4)
        XCTAssertEqual(value.journal.records.count, 3)
        XCTAssertEqual(value.start, baseTime)
    }

    #if GS1_LAB
    private func widgetJSON(_ snapshot: GS1WidgetSnapshot, overriding fields: [String: Any] = [:]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for (key, value) in fields { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testLabWidgetSnapshotRoundTripSortsNewestFirstAndPreservesUnits() throws {
        let newest = GS1WidgetSnapshot.Sample(date: baseTime, mgdl: 126)
        let oldest = GS1WidgetSnapshot.Sample(date: baseTime.addingTimeInterval(-600), mgdl: 108)
        let middle = GS1WidgetSnapshot.Sample(date: baseTime.addingTimeInterval(-300), mgdl: 117)
        let snapshot = GS1WidgetSnapshot(samples: [oldest, newest, middle], isMgDl: false, updatedAt: baseTime)
        let decoded = try XCTUnwrap(GS1WidgetSnapshot.decode(JSONEncoder().encode(snapshot), at: baseTime))
        XCTAssertEqual(decoded.samples, [newest, middle, oldest])
        XCTAssertEqual(decoded.latest, newest)
        XCTAssertFalse(decoded.isMgDl)
        XCTAssertEqual(decoded.updatedAt, baseTime)
        XCTAssertFalse(decoded.isStale(at: baseTime))
    }

    func testLabWidgetEmptySnapshotContainsNoInventedGlucose() throws {
        let snapshot = GS1WidgetSnapshot(samples: [], isMgDl: true, updatedAt: baseTime)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try XCTUnwrap(GS1WidgetSnapshot.decode(encoded, at: baseTime))
        XCTAssertTrue(decoded.samples.isEmpty)
        XCTAssertNil(decoded.latest)
        XCTAssertTrue(decoded.isStale(at: baseTime))
        XCTAssertTrue(decoded.isValid(at: baseTime))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["samples"] as? [[String: Any]])?.count, 0)
    }

    func testLabWidgetStalenessUsesMeasurementTimeAndCannotBeResetByPublishingAgain() {
        let snapshot = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: 126)],
            isMgDl: true, updatedAt: baseTime.addingTimeInterval(599))
        XCTAssertFalse(snapshot.isStale(at: baseTime.addingTimeInterval(599)))
        XCTAssertFalse(snapshot.isStale(at: baseTime.addingTimeInterval(600)))
        XCTAssertTrue(snapshot.isStale(at: baseTime.addingTimeInterval(601)))
        let republished = GS1WidgetSnapshot(samples: snapshot.samples, isMgDl: true,
            updatedAt: baseTime.addingTimeInterval(1800))
        XCTAssertTrue(republished.isStale(at: baseTime.addingTimeInterval(1800)))
    }

    func testLabWidgetDecodeRejectsForeignOwnerAndUnsupportedSchemaVersion() throws {
        let snapshot = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: 126)], isMgDl: true, updatedAt: baseTime)
        XCTAssertNotNil(GS1WidgetSnapshot.decode(try widgetJSON(snapshot), at: baseTime))
        for owner in ["com.V779UZKPJ6.xdripswift", GS1WidgetSnapshot.widgetBundleIdentifier, ""] {
            XCTAssertNil(GS1WidgetSnapshot.decode(try widgetJSON(snapshot, overriding: ["owner": owner]), at: baseTime))
        }
        for version in [0, 2, -1] {
            XCTAssertNil(GS1WidgetSnapshot.decode(try widgetJSON(snapshot, overriding: ["version": version]), at: baseTime))
        }
        XCTAssertNil(GS1WidgetSnapshot.decode(try widgetJSON(snapshot, overriding: ["version": "1"]), at: baseTime))
    }

    func testLabWidgetDecodeRejectsCorruptAndOversizedOtherwiseValidJSON() throws {
        let snapshot = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: 126)], isMgDl: true, updatedAt: baseTime)
        let valid = try JSONEncoder().encode(snapshot)
        for data in [Data(), Data([0xff]), Data("{\"samples\":".utf8), Data(valid.dropLast())] {
            XCTAssertNil(GS1WidgetSnapshot.decode(data, at: baseTime))
        }
        var oversized = valid
        oversized.append(Data(repeating: 0x20, count: 100_001))
        XCTAssertNoThrow(try JSONDecoder().decode(GS1WidgetSnapshot.self, from: oversized))
        XCTAssertNil(GS1WidgetSnapshot.decode(oversized, at: baseTime))
    }

    func testLabWidgetSnapshotEnforcesFutureClockToleranceAndCaptureOrdering() throws {
        let atTolerance = GS1WidgetSnapshot(samples: [.init(date: baseTime.addingTimeInterval(120), mgdl: 126)],
            isMgDl: true, updatedAt: baseTime.addingTimeInterval(120))
        XCTAssertNotNil(GS1WidgetSnapshot.decode(try JSONEncoder().encode(atTolerance), at: baseTime))
        let futureCapture = GS1WidgetSnapshot(samples: [], isMgDl: true, updatedAt: baseTime.addingTimeInterval(121))
        XCTAssertFalse(futureCapture.isValid(at: baseTime))
        let futureReading = GS1WidgetSnapshot(samples: [.init(date: baseTime.addingTimeInterval(121), mgdl: 126)],
            isMgDl: true, updatedAt: baseTime)
        XCTAssertFalse(futureReading.isValid(at: baseTime))
        let readingAfterCapture = GS1WidgetSnapshot(samples: [.init(date: baseTime.addingTimeInterval(-119), mgdl: 126)],
            isMgDl: true, updatedAt: baseTime.addingTimeInterval(-240))
        XCTAssertFalse(readingAfterCapture.isValid(at: baseTime))
    }

    func testLabWidgetSnapshotRejectsNonFiniteDatesAndOutOfRangeGlucose() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 12, 1001] {
            let snapshot = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: value)], isMgDl: true, updatedAt: baseTime)
            XCTAssertFalse(snapshot.isValid(at: baseTime))
        }
        for value in [13.0, 1000.0] {
            XCTAssertTrue(GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: value)],
                isMgDl: true, updatedAt: baseTime).isValid(at: baseTime))
        }
        for interval in [Double.nan, .infinity, -.infinity] {
            let invalidDate = Date(timeIntervalSince1970: interval)
            XCTAssertFalse(GS1WidgetSnapshot(samples: [], isMgDl: true, updatedAt: invalidDate).isValid(at: baseTime))
            XCTAssertFalse(GS1WidgetSnapshot(samples: [.init(date: invalidDate, mgdl: 126)],
                isMgDl: true, updatedAt: baseTime).isValid(at: baseTime))
        }
    }

    func testLabWidgetSnapshotRejectsDuplicateDatesAndUnsortedWireHistory() throws {
        let duplicate = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: 126), .init(date: baseTime, mgdl: 127)],
            isMgDl: true, updatedAt: baseTime)
        XCTAssertFalse(duplicate.isValid(at: baseTime))
        XCTAssertNil(GS1WidgetSnapshot.decode(try JSONEncoder().encode(duplicate), at: baseTime))
        let valid = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: 126),
            .init(date: baseTime.addingTimeInterval(-300), mgdl: 117)], isMgDl: true, updatedAt: baseTime)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        let samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertNil(GS1WidgetSnapshot.decode(try widgetJSON(valid, overriding: ["samples": Array(samples.reversed())]), at: baseTime))
    }

    func testLabWidgetSnapshotLimitsHistoryTo300RealSamples() throws {
        let samples = (0..<301).map {
            GS1WidgetSnapshot.Sample(date: baseTime.addingTimeInterval(-Double($0) * 60), mgdl: 126)
        }
        let atLimit = GS1WidgetSnapshot(samples: Array(samples.prefix(300)), isMgDl: true, updatedAt: baseTime)
        XCTAssertEqual(try XCTUnwrap(GS1WidgetSnapshot.decode(JSONEncoder().encode(atLimit), at: baseTime)).samples.count, 300)
        let overLimit = GS1WidgetSnapshot(samples: samples, isMgDl: true, updatedAt: baseTime)
        XCTAssertFalse(overLimit.isValid(at: baseTime))
        XCTAssertNil(GS1WidgetSnapshot.decode(try JSONEncoder().encode(overLimit), at: baseTime))
    }

    func testLabWidgetSnapshotHasPrivateIdentityAndOnlyDisplayFields() throws {
        XCTAssertEqual(GS1WidgetSnapshot.appBundleIdentifier, "com.V779UZKPJ6.xdripswift.gs1lab")
        XCTAssertEqual(GS1WidgetSnapshot.widgetBundleIdentifier, GS1WidgetSnapshot.appBundleIdentifier + ".xDripWidget")
        XCTAssertEqual(GS1WidgetSnapshot.groupIdentifier, "group.com.V779UZKPJ6.xdripswift.gs1lab.widget")
        XCTAssertNotEqual(GS1WidgetSnapshot.groupIdentifier, Bundle.main.appGroupSuiteName)
        XCTAssertNotEqual(GS1WidgetSnapshot.groupIdentifier, Bundle.main.appGroupSuiteNameTrio)
        XCTAssertFalse(CollectorBuild.allowsExternalIntegrations)
        XCTAssertTrue(Bundle.main.disableLoopShare)
        let snapshot = GS1WidgetSnapshot(samples: [.init(date: baseTime, mgdl: 126)], isMgDl: false, updatedAt: baseTime)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["version", "owner", "updatedAt", "isMgDl", "samples"]))
        let sampleObject = try XCTUnwrap((object["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(sampleObject.keys), Set(["date", "mgdl"]))
    }

    // These checks exercise only the separately built GS1 Lab host. Their stores
    // and preferences are test-owned; no primary app container is opened.
    private func withLabDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "GS1LabIsolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func assertLabExportsDisabled(_ defaults: UserDefaults, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(defaults.isMaster, file: file, line: line)
        XCTAssertFalse(defaults.nightscoutEnabled, file: file, line: line)
        XCTAssertFalse(defaults.masterUploadDataToNightscout, file: file, line: line)
        XCTAssertFalse(defaults.followerUploadDataToNightscout, file: file, line: line)
        XCTAssertFalse(defaults.uploadReadingstoDexcomShare, file: file, line: line)
        XCTAssertFalse(defaults.storeReadingsInHealthkit, file: file, line: line)
        XCTAssertFalse(defaults.createCalendarEvent, file: file, line: line)
        XCTAssertFalse(defaults.enableContactImage, file: file, line: line)
        XCTAssertEqual(defaults.loopShareType, .disabled, file: file, line: line)
        XCTAssertFalse(defaults.canPublishOSAidData, file: file, line: line)
        XCTAssertFalse(defaults.dataFlowPolicy.exportsGlucoseToNightscout, file: file, line: line)
        XCTAssertFalse(defaults.dataFlowPolicy.importsGlucoseFromNightscout, file: file, line: line)
    }

    private func labManager(_ core: CoreDataManager, delegate: GS1LabCGMDelegate) -> BluetoothPeripheralManager {
        BluetoothPeripheralManager(coreDataManager: core, cgmTransmitterDelegate: delegate,
            messageHandler: { _, _ in }, heartBeatFunction: nil, cgmTransmitterInfoChanged: {})
    }

    func testLabBuildPermitsOnlyGS1AndNoExternalIntegrations() {
        XCTAssertTrue(CollectorBuild.isGS1Lab)
        XCTAssertFalse(CollectorBuild.allowsExternalIntegrations)
        XCTAssertEqual(BluetoothPeripheralType.allCases.filter(CollectorBuild.permits), [.SibionicsCNType])
    }

    func testLabRawRestoredPreferencesCannotEnableExportsOrFollowerMode() {
        withLabDefaults { defaults in
            // Restore can bypass the typed setters, including inverse booleans.
            defaults.set(true, forKey: UserDefaults.Key.isMaster.rawValue)
            defaults.set(false, forKey: UserDefaults.Key.masterUploadDataToNightscout.rawValue)
            for key in [UserDefaults.Key.nightscoutEnabled, .followerUploadDataToNightscout,
                        .uploadReadingstoDexcomShare, .storeReadingsInHealthkit, .createCalendarEvent, .enableContactImage] {
                defaults.set(true, forKey: key.rawValue)
            }
            defaults.set(LoopShareType.trio.rawValue, forKey: UserDefaults.Key.loopShareType.rawValue)
            assertLabExportsDisabled(defaults)
            XCTAssertTrue(defaults.bool(forKey: UserDefaults.Key.nightscoutEnabled.rawValue))
            XCTAssertEqual(defaults.integer(forKey: UserDefaults.Key.loopShareType.rawValue), LoopShareType.trio.rawValue)
        }
    }

    func testLabSettingsTogglesCannotEnableAnyExternalChannel() {
        withLabDefaults { defaults in
            defaults.isMaster = false
            defaults.nightscoutEnabled = true
            defaults.masterUploadDataToNightscout = true
            defaults.followerUploadDataToNightscout = true
            defaults.uploadReadingstoDexcomShare = true
            defaults.storeReadingsInHealthkit = true
            defaults.createCalendarEvent = true
            defaults.enableContactImage = true
            defaults.loopShareType = .trio
            defaults.loopShareSmoothedData = true
            assertLabExportsDisabled(defaults)
            XCTAssertFalse(defaults.loopShareSmoothedData)
        }
    }

    func testLabShareTargetsNeverResolveToAnAppGroup() {
        XCTAssertTrue(Bundle.main.disableLoopShare)
        for type in LoopShareType.allCases {
            XCTAssertEqual(type.sharedUserDefaultsSuiteName, "")
        }
    }

    func testLabSharedDefaultsWriteDoesNotOverwriteItsPrivateSentinel() throws {
        let suiteName = Bundle.main.appGroupSuiteName
        guard suiteName.contains("gs1lab"), !suiteName.hasPrefix("group.") else {
            return XCTFail("Refusing to open a non-Lab preference suite")
        }
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = "LabWriteSentinel.\(UUID().uuidString)"
        suite.set("fixture-private-sentinel", forKey: key)
        defer { suite.removeObject(forKey: key) }
        UserDefaults.storeInSharedUserDefaults(value: "must-not-be-written", forKey: key)
        XCTAssertEqual(suite.string(forKey: key), "fixture-private-sentinel")
    }

    @MainActor func testLabLoopPublishMetadataAndClearDoNotTouchPrivateSharedReadings() throws {
        let suiteName = Bundle.main.appGroupSuiteNameTrio
        guard suiteName.contains("gs1lab"), !suiteName.hasPrefix("group.") else {
            return XCTFail("Refusing to open a non-Lab preference suite")
        }
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keys = ["latestReadings", XDripCGMMetadataEnvelope.appGroupKey]
        let previous = keys.map { suite.object(forKey: $0) }
        let sentinel = Data("test-only-private-fixture".utf8)
        for key in keys { suite.set(sentinel, forKey: key) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { suite.set(value, forKey: key) } else { suite.removeObject(forKey: key) }
            }
        }
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = LoopManager(coreDataManager: core, activeSensorIsAnubisProvider: { false }, metadataContextProvider: {
            XDripCGMMetadataContext(activeSensor: nil, transmitter: nil, sensorHealthIssue: nil,
                hasInitialCalibration: nil, lastCalibrationAt: nil, dexcomAlgorithmState: nil, libreSensorState: nil)
        })
        manager.share()
        manager.shareMetadata(clearReadings: true, sensorState: "fixture")
        manager.clearSharedLoopReadings()
        for key in keys { XCTAssertEqual(suite.data(forKey: key), sentinel) }
    }

    @MainActor func testLabBluetoothPickerOffersOnlyGS1() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = GS1LabCGMDelegate()
        let manager = labManager(core, delegate: delegate)
        let model = BluetoothPeripheralsViewModel(bluetoothPeripheralManager: manager)
        XCTAssertEqual(model.bluetoothPeripheralTypes(for: .CGM), [.SibionicsCNType])
        for category in BluetoothPeripheralCategory.allCases where category != .CGM {
            XCTAssertTrue(model.bluetoothPeripheralTypes(for: category).isEmpty)
        }
    }

    @MainActor func testLabNewGS1DetailShowsEditableSetupRowsBeforeAnyPeripheralIsSaved() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = GS1LabCGMDelegate()
        let manager = labManager(core, delegate: delegate)
        var entries: [BluetoothPeripheralTextEntry] = []
        let state = BluetoothPeripheralDetailState(bluetoothPeripheral: nil,
            expectedBluetoothPeripheralType: .SibionicsCNType, coreDataManager: core,
            bluetoothPeripheralManager: manager, sensorProvider: nil,
            closeDetailView: { XCTFail("Editing setup must not close the new device screen") },
            presentTextEntryView: { entries.append($0) },
            presentSelectionListView: { _ in XCTFail("Initial setup must not start a Bluetooth scan") },
            presentReadSuccessView: { _, _ in }, presentBatteryHistoryView: { _ in },
            presentSignalStrengthView: { _ in })
        let initialRows = state.sections.flatMap(\.rows)
        let requiredIDs: Set<String> = ["gs1-code", "gs1-mac", "gs1-selected", "gs1-status"]
        XCTAssertTrue(Set(initialRows.map(\.id)).isSuperset(of: requiredIDs))
        let codeRow = try XCTUnwrap(initialRows.first { $0.id == "gs1-code" })
        let macRow = try XCTUnwrap(initialRows.first { $0.id == "gs1-mac" })
        XCTAssertTrue(codeRow.isEnabled)
        XCTAssertTrue(macRow.isEnabled)
        XCTAssertEqual(initialRows.first { $0.id == "gs1-selected" }?.detail, "Not selected")
        XCTAssertFalse(try XCTUnwrap(initialRows.first { $0.id == "gs1-status" }?.detail).isEmpty)
        XCTAssertFalse(initialRows.contains { $0.id == "gs1-save" })

        try XCTUnwrap(codeRow.action)()
        XCTAssertEqual(entries.count, 1)
        try XCTUnwrap(entries.last).actionHandler("GEPD802J")
        try XCTUnwrap(macRow.action)()
        XCTAssertEqual(entries.count, 2)
        try XCTUnwrap(entries.last).actionHandler("11:22:33:44:55:66")
        let editedRows = state.sections.flatMap(\.rows)
        XCTAssertEqual(editedRows.first { $0.id == "gs1-code" }?.detail, "GEPD802J")
        XCTAssertEqual(editedRows.first { $0.id == "gs1-mac" }?.detail, "11:22:33:44:55:66")
        XCTAssertFalse(editedRows.contains { $0.id == "gs1-save" })
        XCTAssertTrue(core.mainManagedObjectContext.insertedObjects.isEmpty)
        XCTAssertTrue(manager.getBluetoothTransmitters().isEmpty)
    }

    @MainActor func testLabSavedGS1DetailDoesNotDuplicateTheSetupSection() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = GS1LabCGMDelegate()
        let manager = labManager(core, delegate: delegate)
        let device = try manager.registerSibionicsCN(address: UUID(), name: "LT2309GEPD",
            code: "GEPD802J", mac: "11:22:33:44:55:66")
        let state = BluetoothPeripheralDetailState(bluetoothPeripheral: device,
            expectedBluetoothPeripheralType: .SibionicsCNType, coreDataManager: core,
            bluetoothPeripheralManager: manager, sensorProvider: nil, closeDetailView: {},
            presentTextEntryView: { _ in }, presentSelectionListView: { _ in },
            presentReadSuccessView: { _, _ in }, presentBatteryHistoryView: { _ in },
            presentSignalStrengthView: { _ in })
        let rows = state.sections.flatMap(\.rows)
        for id in ["gs1-code", "gs1-mac", "gs1-selected", "gs1-status"] {
            XCTAssertEqual(rows.filter { $0.id == id }.count, 1, id)
        }
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.id == "gs1-code" }).isEnabled)
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.id == "gs1-mac" }).isEnabled)
        XCTAssertFalse(device.startAuthorized)
        XCTAssertFalse(device.blePeripheral.shouldconnect)
        XCTAssertTrue(manager.getBluetoothTransmitters().isEmpty)
    }

    @MainActor func testLabUnsupportedPeripheralFactoryAndConnectAreBlocked() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = GS1LabCGMDelegate()
        let manager = labManager(core, delegate: delegate)
        let ottai = Ottai(address: UUID().uuidString, name: "fixture-Ottai", alias: nil,
            nsManagedObjectContext: core.mainManagedObjectContext)
        ottai.blePeripheral.shouldconnect = false
        XCTAssertNil(manager.getBluetoothTransmitter(for: ottai, createANewOneIfNecesssary: true))
        manager.connect(to: ottai)
        XCTAssertFalse(ottai.blePeripheral.shouldconnect)
        XCTAssertTrue(manager.getBluetoothTransmitters().isEmpty)
    }

    @MainActor func testLabStartupDoesNotRestoreAnEnabledOttaiTransmitter() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let ottai = Ottai(address: UUID().uuidString, name: "fixture-restored-Ottai", alias: nil,
            nsManagedObjectContext: core.mainManagedObjectContext)
        ottai.ottaiSensorId = "AABBCCDDEEFF"
        ottai.blePeripheral.shouldconnect = true
        core.saveChanges()
        let delegate = GS1LabCGMDelegate()
        let manager = labManager(core, delegate: delegate)
        XCTAssertTrue(manager.getBluetoothTransmitters().isEmpty)
        XCTAssertTrue(manager.getBluetoothPeripherals().allSatisfy { $0.bluetoothPeripheralType() == .SibionicsCNType })
    }

    @MainActor func testLabSavingGS1SelectionDoesNotAuthorizeOrStartAnUnusedSensor() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delegate = GS1LabCGMDelegate()
        let manager = labManager(core, delegate: delegate)
        let device = try manager.registerSibionicsCN(address: UUID(), name: "LT2309GEPD",
            code: "GEPD802J", mac: "11:22:33:44:55:66")
        XCTAssertFalse(device.startAuthorized)
        XCTAssertFalse(device.blePeripheral.shouldconnect)
        XCTAssertEqual(device.sensorCode, "GEPD802J")
        XCTAssertTrue(manager.getBluetoothTransmitters().isEmpty)
    }

    func testLabBundleHasItsOwnIdentityWithoutPrimaryAppRoutes() throws {
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertEqual(identifier, "com.V779UZKPJ6.xdripswift.gs1lab")
        XCTAssertEqual(Bundle.main.mainAppBundleIdentifier, identifier)
        XCTAssertNotEqual(identifier, "com.V779UZKPJ6.xdripswift")
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.isEmpty)
        for suite in [Bundle.main.appGroupSuiteName, Bundle.main.appGroupSuiteNameTrio] {
            XCTAssertTrue(suite.contains("gs1lab"))
            XCTAssertFalse(suite.hasPrefix("group."))
            XCTAssertFalse(suite.contains("loopkit"))
        }
    }

    @MainActor func testLabBackupRestoreIsRejectedBeforeSettingsAreApplied() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let service = BackupService(coreDataManager: core)
        let manifest = BackupManifest(format: "fixture", formatVersion: 1, createdAt: baseTime,
            appVersion: "fixture", appBuild: "fixture", bgReadingCount: 0, treatmentCount: 0,
            deviceStatusCount: nil, profileCount: nil, firstBgReadingDate: nil, lastBgReadingDate: nil,
            firstTreatmentDate: nil, firstDeviceStatusDate: nil, firstProfileDate: nil,
            includesSettings: true, includesAccounts: false, isPasswordProtected: false)
        let payload = BackupPayload(manifest: manifest,
            settings: ["nightscoutEnabled": try BackupPropertyListValue(true)], accounts: nil,
            alertTypes: [], bgReadings: [], treatments: [], deviceStatuses: nil, profiles: nil)
        let before = UserDefaults.standard.bool(forKey: UserDefaults.Key.nightscoutEnabled.rawValue)
        do {
            _ = try await service.restore(inspection: BackupInspection(payload: payload), mode: .keepCurrent,
                restoresSettings: true, restoredAccountCategories: [])
            XCTFail("Lab must reject an app backup before restoring any values")
        } catch {
            XCTAssertEqual((error as NSError).domain, "GS1Lab")
        }
        XCTAssertEqual(UserDefaults.standard.bool(forKey: UserDefaults.Key.nightscoutEnabled.rawValue), before)
        XCTAssertTrue(core.mainManagedObjectContext.insertedObjects.isEmpty)
    }
    #endif
}

private final class GS1SessionDelegateSpy: CGMTransmitterDelegate, BluetoothTransmitterDelegate {
    var starts: [Date] = []
    var glucoseBatches = 0
    var heartbeats = 0
    var observed: XCTestExpectation?
    var glucose: [GlucoseData] = []
    var sensorAges: [TimeInterval] = []
    var onObserved: (() -> Void)?
    var configurationChanges = 0
    func sensorSessionObserved(startDate: Date, from transmitter: CGMTransmitter) { starts.append(startDate); observed?.fulfill(); onObserved?() }
    func sensorSessionConfigurationChanged(startDate: Date, from transmitter: CGMTransmitter) { configurationChanges += 1 }
    func newSensorDetected(sensorStartDate: Date?) { XCTFail("Observation must not restart a sensor") }
    func sensorStopDetected() {}
    func sensorNotDetected() {}
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {
        glucoseBatches += 1
        glucose.append(contentsOf: glucoseData)
        if let sensorAge { sensorAges.append(sensorAge) }
    }
    func errorOccurred(xDripError: XdripError) {}
    func didConnectTo(bluetoothTransmitter: BluetoothTransmitter) {}
    func didDisconnectFrom(bluetoothTransmitter: BluetoothTransmitter) {}
    func deviceDidUpdateBluetoothState(state: CBManagerState, bluetoothTransmitter: BluetoothTransmitter) {}
    func transmitterNeedsPairing(bluetoothTransmitter: BluetoothTransmitter) {}
    func successfullyPaired() {}
    func pairingFailed() {}
    func error(message: String) {}
    func heartBeat() { heartbeats += 1 }
}

/// Records requests from the real AlertManager without simulator notification permissions.
private final class GS1PipelineNotificationCenter: AlertNotificationScheduling {
    var added: [UNNotificationRequest] = []
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {
        added.append(request)
        completionHandler?(nil)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}

#if GS1_LAB
private final class GS1LabCGMDelegate: CGMTransmitterDelegate {
    func newSensorDetected(sensorStartDate: Date?) {}
    func sensorStopDetected() {}
    func sensorNotDetected() {}
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {}
    func errorOccurred(xDripError: XdripError) {}
}
#endif
