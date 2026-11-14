//
//  OttaiStartupBackfillTests.swift
//  xdripTests
//
//  Covers what the Ottai/Syai driver asks the sensor for right after a start.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
import CoreBluetooth
@testable import xdrip

final class OttaiStartupBackfillTests: XCTestCase {

    private let dayOfRecords = 24 * 60

    private func encryptedStreamingFrame(counter: Int, raw: Int = 2000, key: String) throws -> [UInt8] {
        let header: [UInt8] = [0, 0, 0, 0, UInt8(counter & 255), UInt8((counter >> 8) & 255), 0, 0]
        let record: [UInt8] = [UInt8(raw & 255), UInt8((raw >> 8) & 255), 0, 0, 0, 0, 100, 0xac, 0x0d]
        return try XCTUnwrap(OttaiCrypto.encryptPayload(header + record, sessionKeyHex: key))
    }

    @MainActor func testCorruptLiveNotificationsDoNotSuppressPolling() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        var now = h.originalStart + 3000 * 60_000
        var materials = h.preparedMaterials
        materials.activeTimeMs = h.originalStart
        materials.method = "C0"
        materials.coefficient = "6"
        h.transmitter.streamingTestNow = { now }
        h.transmitter.configureStreamingTest(materials: materials)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charGlucoseLive,
            value: try encryptedStreamingFrame(counter: 3000, key: h.key))
        XCTAssertEqual(h.transmitter.streamingTestSnapshot().lastLiveNotifyAtMs, now)
        let validAt = now
        now += 120_000
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charGlucoseLive, value: [1, 2, 3])
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charGlucoseLive,
            value: try encryptedStreamingFrame(counter: 3002, raw: 0, key: h.key))
        XCTAssertEqual(h.transmitter.streamingTestSnapshot().lastLiveNotifyAtMs, validAt)
        h.transmitter.pollStreamingTest()
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charGlucoseLive)
    }

    @MainActor func testRepeatedAcceptedLiveCounterKeepsItsOriginalDate() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        let previousBase = OttaiRegistry.loadApiBase()
        UserDefaults.standard.set(OttaiConstants.apiBase, forKey: "ottai_api_base")
        defer { UserDefaults.standard.set(previousBase, forKey: "ottai_api_base") }
        var now = h.originalStart + 3000 * 60_000
        var materials = h.preparedMaterials
        materials.activeTimeMs = 0
        materials.method = "C0"
        materials.coefficient = "6"
        h.transmitter.streamingTestNow = { now }
        h.transmitter.configureStreamingTest(materials: materials)
        let frame = try encryptedStreamingFrame(counter: 3000, key: h.key)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charGlucoseLive, value: frame)
        let first = try XCTUnwrap(h.transmitter.streamingTestSnapshot().acceptedLiveTimes[3000])
        now += 60_000
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charGlucoseLive, value: frame)
        XCTAssertEqual(h.transmitter.streamingTestSnapshot().acceptedLiveTimes[3000], first)
        XCTAssertEqual(h.transmitter.streamingTestSnapshot().confirmedActiveTimeMs, 0)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charGlucoseLive,
            value: try encryptedStreamingFrame(counter: 3001, key: h.key))
        XCTAssertGreaterThan(h.transmitter.streamingTestSnapshot().confirmedActiveTimeMs, 0)
    }

    @MainActor func testSyaiV3UsesFactoryPreparationAndManufacturerLifetime() throws {
        let h = OttaiLifetimeTransportHarness(apiBase: OttaiConstants.apiBaseSyai)
        defer { h.clean() }
        OttaiRegistry.clearActivationCheckpoint(h.id)
        for prefix in ["ottai_accepted_max_active_", "ottai_lifetime_evidence_"] { UserDefaults.standard.removeObject(forKey: prefix + h.id) }
        h.transmitter.prepareLegacySyaiColdStartTest()
        h.transmitter.startSensor(sensorCode: nil, startDate: Date())
        h.transmitter.receiveLifetimeTest(uuid: "fixture-drain", value: [])
        let material = OttaiCloudClient.V3AuthMaterial(authHost: String(repeating: "11", count: 68),
            authFlag: String(repeating: "22", count: 32), keyB: "", cf: "", d: "", c: "")
        h.transmitter.beginLegacySyaiAuthenticationTest(material: material)
        h.ack(OttaiConstants.charAuthAppParam)
        h.ack(OttaiConstants.charAuthSign)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array(h.materials.deviceVersion.utf8))
        XCTAssertTrue(OttaiRegistry.hasPreparationCheckpoint(h.id))
        let prepared = expectation(description: "Syai preparation returns to local ECDH")
        h.transmitter.preparationTestMaterialFetch = { attempted, willBind in
            XCTAssertFalse(attempted)
            XCTAssertTrue(willBind())
            return h.preparedMaterials
        }
        h.transmitter.preparationTestLocalReauth = { prepared.fulfill() }
        h.status(2)
        wait(for: [prepared], timeout: 2)
        h.configure()
        h.transmitter.resumeActivationTransportTest(materials: h.preparedMaterials)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array(h.materials.deviceVersion.utf8))
        h.status(2)
        XCTAssertEqual(h.payloads.last?.0, OttaiConstants.charDestructive)
        XCTAssertEqual(h.payloads.last?.1.first, 0x09)
        h.ack(OttaiConstants.charDestructive)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charCurrentTime)
        h.ack(OttaiConstants.charCurrentTime)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charMaxActiveTime)
        h.ack(OttaiConstants.charMaxActiveTime)
        h.duration(14)
        h.ack(OttaiConstants.charDestructive)
        XCTAssertGreaterThan(try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(h.id)).commandSentAtMs, 0)
        h.ack(OttaiConstants.charCommand)
        h.status(3)
        XCTAssertGreaterThan(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id)).confirmedStartMs, 0)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), 14 * 86_400_000)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(h.id), .sensorReadback)
    }

    @MainActor func testSyaiNoKeyCompatibilityUsesOpaqueServerFramesWithoutFreshBindOrThirtyDayClaim() throws {
        let h = OttaiLifetimeTransportHarness(apiBase: OttaiConstants.apiBaseSyai)
        defer { h.clean() }
        OttaiRegistry.clearActivationCheckpoint(h.id)
        for prefix in ["ottai_accepted_max_active_", "ottai_lifetime_evidence_"] { UserDefaults.standard.removeObject(forKey: prefix + h.id) }
        h.transmitter.prepareLegacySyaiColdStartTest()
        h.transmitter.startSensor(sensorCode: nil, startDate: Date())
        h.transmitter.receiveLifetimeTest(uuid: "fixture-drain", value: [])
        XCTAssertNotNil(OttaiRegistry.loadActivationCheckpoint(h.id))
        XCTAssertFalse(OttaiRegistry.hasPreparationCheckpoint(h.id))
        var discoveries = 0, pendingBinds = 0
        h.transmitter.activationTestRediscover = { discoveries += 1 }
        h.transmitter.serverActivationTestPendingBind = { pendingBinds += 1 }
        h.transmitter.preparationTestMaterialFetch = { _, _ in XCTFail("Syai must not call the CN/Global Fresh bind"); return nil }
        let material = OttaiCloudClient.V3AuthMaterial(authHost: String(repeating: "11", count: 68),
            authFlag: String(repeating: "22", count: 32), keyB: "",
            cf: "090211223344", d: String(repeating: "33", count: 16), c: String(repeating: "44", count: 16))
        h.transmitter.beginLegacySyaiAuthenticationTest(material: material)
        XCTAssertEqual(h.transcript, ["W:" + OttaiConstants.charAuthAppParam])
        h.ack(OttaiConstants.charAuthAppParam)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charAuthSign)
        h.ack(OttaiConstants.charAuthSign)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charSoftwareVersion)
        // Compatibility keeps the previous firmware reader; it must not impose the
        // unrelated CN/Global Fresh V1.4...V1.8 preparation allowlist on Syai.
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array("legacy-syai-revision".utf8))
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charCommand)
        h.status(2)
        XCTAssertEqual(discoveries, 1)
        XCTAssertFalse(h.payloads.contains { $0.0 == OttaiConstants.charDestructive })
        h.transmitter.finishActivationDiscoveryTest()
        XCTAssertEqual(h.payloads.last?.1, try OttaiCrypto.hexToBytesStrict(material.cf))
        h.ack(OttaiConstants.charDestructive)
        XCTAssertEqual(h.payloads.last?.1, try OttaiCrypto.hexToBytesStrict(material.d))
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), 0)
        h.ack(OttaiConstants.charMaxActiveTime)
        XCTAssertEqual(h.payloads.last?.0, OttaiConstants.charCurrentTime)
        XCTAssertEqual(h.payloads.last?.1, [0, 0, 0, 0])
        h.ack(OttaiConstants.charCurrentTime)
        XCTAssertGreaterThan(try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(h.id)).commandSentAtMs, 0)
        XCTAssertEqual(h.payloads.last?.1, try OttaiCrypto.hexToBytesStrict(material.c))
        h.ack(OttaiConstants.charCommand)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charCommand)
        h.status(3)
        XCTAssertEqual(pendingBinds, 1)
        XCTAssertGreaterThan(OttaiRegistry.loadPendingBind(h.id), 0)
        XCTAssertTrue(try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(h.id)).confirmed)
        XCTAssertFalse(OttaiRegistry.hasPreparationCheckpoint(h.id))
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), 0)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(h.id), .legacy)
        XCTAssertFalse(h.transcript.contains("R:" + OttaiConstants.charMaxActiveTime))
        XCTAssertEqual(h.transcript, ["W:" + OttaiConstants.charAuthAppParam, "W:" + OttaiConstants.charAuthSign,
            "R:" + OttaiConstants.charSoftwareVersion, "R:" + OttaiConstants.charCommand,
            "W:" + OttaiConstants.charDestructive, "W:" + OttaiConstants.charMaxActiveTime,
            "W:" + OttaiConstants.charCurrentTime, "W:" + OttaiConstants.charCommand,
            "R:" + OttaiConstants.charCommand])
    }

    @MainActor func testFirstCNStartWithCachedKeysStillReadsFirmwareAndPreparesFactory() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        XCTAssertFalse(OttaiRegistry.hasPreparationCheckpoint(h.id))
        h.transmitter.resumeActivationTransportTest(materials: h.preparedMaterials)
        // The ordinary user Start owns the new checkpoint; a cached key alone is
        // never a factory-complete marker. Stop the first probe before issuing Start.
        h.transmitter.disconnectLifetimeTest()
        h.configure()
        let rediscovery = expectation(description: "Explicit Start rediscovers services")
        h.transmitter.activationTestRediscover = { rediscovery.fulfill() }
        h.status(2)
        h.transmitter.startSensor(sensorCode: nil, startDate: Date())
        wait(for: [rediscovery], timeout: 2)
        let prep = try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id))
        XCTAssertTrue(prep.storedMaterials)
        XCTAssertTrue(prep.materialsSaved)
        XCTAssertFalse(prep.factoryComplete)
        h.transmitter.finishActivationDiscoveryTest()
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charSoftwareVersion)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array(h.materials.deviceVersion.utf8))
        h.status(2)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charDestructive)
        XCTAssertEqual(OttaiRegistry.loadPreparationCheckpoint(h.id)?.liveFirmware, h.materials.deviceVersion)
        XCTAssertFalse(h.payloads.contains { $0.0 == OttaiConstants.charCommand })
    }

    @MainActor func testExplicitRetryRefreshesIncompleteFactoryMaterialsBeforeAnyFactoryWrite() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        var prep = OttaiPreparationCheckpoint(sensorID: h.id, bluetoothID: h.bluetoothID,
            apiBase: h.account.apiBase, userID: h.account.userId, authorizedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        prep.liveFirmware = h.materials.deviceVersion
        prep.bindAttempted = true
        prep.materialsSaved = false
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(prep))
        let reauth = expectation(description: "Read-only prepared materials refresh")
        h.transmitter.preparationTestLocalReauth = { reauth.fulfill() }
        h.transmitter.preparationTestMaterialFetch = { alreadyAttempted, _ in
            XCTAssertTrue(alreadyAttempted)
            return h.preparedMaterials
        }
        h.transmitter.resumeActivationTransportTest(materials: h.preparedMaterials)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charSoftwareVersion)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array(h.materials.deviceVersion.utf8))
        h.status(2)
        wait(for: [reauth], timeout: 2)
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertTrue(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id)).materialsSaved)
        XCTAssertFalse(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id)).factoryComplete)
    }

    @MainActor func testFreshCNCloudProofSettlesBeforeBindThenLocalAuthResumesFactoryAndActivation() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        var checkpoint = OttaiPreparationCheckpoint(sensorID: h.id, bluetoothID: h.bluetoothID,
            apiBase: h.account.apiBase, userID: h.account.userId, authorizedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        checkpoint.liveFirmware = h.materials.deviceVersion
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(checkpoint))
        let discovery = expectation(description: "Cloud proof settles then requests discovery")
        let localReauth = expectation(description: "Prepared credentials require a new local ECDH")
        h.transmitter.preparationTestRediscover = { discovery.fulfill() }
        h.transmitter.preparationTestLocalReauth = { localReauth.fulfill() }
        var preparations = 0
        h.transmitter.preparationTestMaterialFetch = { alreadyAttempted, willBind in
            preparations += 1
            XCTAssertFalse(alreadyAttempted)
            XCTAssertTrue(willBind())
            XCTAssertTrue(OttaiRegistry.loadPreparationCheckpoint(h.id)?.bindAttempted == true)
            return h.preparedMaterials
        }
        h.transmitter.beginPreparationProofTest()
        XCTAssertTrue(h.transcript.isEmpty)
        XCTAssertEqual(preparations, 0)
        wait(for: [discovery], timeout: 4)
        XCTAssertEqual(preparations, 0) // proof/discovery alone cannot authorize a bind
        h.transmitter.finishPreparationDiscoveryTest()
        XCTAssertEqual(h.transcript, ["R:" + OttaiConstants.charSoftwareVersion])
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array(h.materials.deviceVersion.utf8))
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charCommand)
        XCTAssertEqual(preparations, 0)
        h.status(2)
        wait(for: [localReauth], timeout: 3)
        XCTAssertEqual(preparations, 1)
        let prepared = try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id))
        XCTAssertTrue(prepared.materialsSaved)
        XCTAssertFalse(prepared.factoryComplete)
        XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: h.id).activeTimeMs, 0)
        XCTAssertTrue(h.payloads.isEmpty) // no opaque coefficient/duration/activate frames

        h.transmitter.disconnectLifetimeTest()
        h.configure()
        h.transmitter.resumeActivationTransportTest(materials: h.preparedMaterials)
        h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charSoftwareVersion, value: Array(h.materials.deviceVersion.utf8))
        h.status(2)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charDestructive)
        XCTAssertFalse(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id)).factoryComplete)
        h.ack(OttaiConstants.charDestructive)
        XCTAssertTrue(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id)).factoryComplete)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charCurrentTime)
        h.ack(OttaiConstants.charCurrentTime)
        h.ack(OttaiConstants.charMaxActiveTime)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charMaxActiveTime)
        XCTAssertFalse(h.payloads.contains { $0.0 == OttaiConstants.charCommand })
        h.duration(30)
        h.ack(OttaiConstants.charDestructive)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charCommand)
        h.status(3)
        let confirmed = try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(h.id))
        XCTAssertGreaterThan(confirmed.confirmedStartMs, 0)
        XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: h.id).activeTimeMs, confirmed.confirmedStartMs)
        XCTAssertNil(OttaiRegistry.loadActivationCheckpoint(h.id))
        XCTAssertEqual(OttaiRegistry.loadPendingBind(h.id), 0)
        XCTAssertEqual(preparations, 1)
    }

    @MainActor func testFreshGlobalConfirmedStartDoesNotCreateALegacySDKBindIntent() throws {
        let oldProfile = UserDefaults.standard.string(forKey: "ottai_session_profile")
        OttaiRegistry.saveSessionProfile(.globalPhone)
        defer {
            if let oldProfile { UserDefaults.standard.set(oldProfile, forKey: "ottai_session_profile") }
            else { UserDefaults.standard.removeObject(forKey: "ottai_session_profile") }
        }
        let h = OttaiLifetimeTransportHarness(globalAccount: true)
        defer { h.clean() }
        var preparation = OttaiPreparationCheckpoint(sensorID: h.id, bluetoothID: h.bluetoothID,
            apiBase: h.account.apiBase, userID: h.account.userId, authorizedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        preparation.bindAttempted = true
        preparation.materialsSaved = true
        preparation.factoryComplete = true
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(preparation))
        var activation = try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(h.id))
        activation.commandSentAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        activation.commandConnectionID = UUID().uuidString
        XCTAssertTrue(OttaiRegistry.saveActivationCheckpoint(activation))
        h.status(3)
        XCTAssertEqual(OttaiRegistry.loadPendingBind(h.id), 0)
        XCTAssertNil(OttaiRegistry.loadActivationCheckpoint(h.id))
        XCTAssertEqual(OttaiRegistry.loadPreparationCheckpoint(h.id)?.confirmedStartMs, activation.commandSentAtMs)
        XCTAssertTrue(h.payloads.isEmpty)
    }

    @MainActor func testResumedActivationDoesNotSkipAnUnreadableOrWrongIdentityPreparation() {
        for corrupt in [true, false] {
            let h = OttaiLifetimeTransportHarness()
            defer { h.clean() }
            if corrupt { UserDefaults.standard.set(Data("broken".utf8), forKey: "ottai_preparation_" + h.id) }
            else {
                let wrong = OttaiPreparationCheckpoint(sensorID: h.id, bluetoothID: UUID().uuidString,
                    apiBase: h.account.apiBase, userID: h.account.userId, authorizedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
                XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(wrong))
            }
            h.transmitter.resumeActivationTransportTest(materials: h.preparedMaterials)
            XCTAssertTrue(h.payloads.isEmpty)
            XCTAssertTrue(h.transcript.isEmpty)
        }
    }

    @MainActor func testCNAndGlobalRuntimeAcceptEncryptedThirtyDayReadbackAndWriteThatExactTarget() throws {
        for global in [false, true] {
            let h = OttaiLifetimeTransportHarness()
            defer { h.clean() }
            if global {
                try h.transmitter.beginActivationTransportTest(global: true, materials: h.materials)
                h.ack(OttaiConstants.charDestructive)
            } else { h.transmitter.beginLifetimeTest(activation: true) }
            let wire = try XCTUnwrap(h.payloads.last { $0.0 == OttaiConstants.charMaxActiveTime }?.1)
            // Independent target bytes: LE32(2592000 seconds), zero padded to AES.
            let sent = try XCTUnwrap(OttaiCrypto.aesECB(.decrypt, key: OttaiCrypto.hexToBytesStrict(h.key), data: wire, pkcs7Padded: false))
            XCTAssertEqual(sent, [0, 0x8d, 0x27, 0] + [UInt8](repeating: 0, count: 12))
            h.ack(OttaiConstants.charMaxActiveTime)
            XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
            let cipher = try XCTUnwrap(OttaiCrypto.encryptPayload([0, 0x8d, 0x27, 0, 0, 0, 0, 0], sessionKeyHex: h.key))
            h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charMaxActiveTime, value: cipher)
            XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), 30 * 86_400_000)
            XCTAssertEqual(OttaiRegistry.lifetimeEvidence(h.id), .sensorReadback)
            XCTAssertEqual(h.transcript.last, "W:" + (global ? OttaiConstants.charCurrentTime : OttaiConstants.charDestructive))
            XCTAssertFalse(h.payloads.contains { $0.0 == OttaiConstants.charCommand })
        }
    }

    @MainActor func testCNActivationWaitsForExactDurationReadbackBeforeRetainAndActivate() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        try h.transmitter.beginActivationTransportTest(global: false, materials: h.materials)
        XCTAssertEqual(h.transcript, ["W:" + OttaiConstants.charCurrentTime])
        h.ack(OttaiConstants.charCurrentTime)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charMaxActiveTime)
        h.ack(OttaiConstants.charMaxActiveTime)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charMaxActiveTime)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
        XCTAssertFalse(h.transcript.contains("W:" + OttaiConstants.charDestructive))
        h.duration(30)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charDestructive)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(h.id), .sensorReadback)
        h.ack(OttaiConstants.charDestructive)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charCommand)
    }

    @MainActor func testGlobalFactoryPlanWaitsForDurationReadbackBeforeZeroRTCAndActivation() throws {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        try h.transmitter.beginActivationTransportTest(global: true, materials: h.materials)
        XCTAssertEqual(h.transcript, ["W:" + OttaiConstants.charDestructive])
        h.ack(OttaiConstants.charDestructive)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charMaxActiveTime)
        h.ack(OttaiConstants.charMaxActiveTime)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charMaxActiveTime)
        XCTAssertFalse(h.transcript.contains("W:" + OttaiConstants.charCurrentTime))
        h.duration(30)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charCurrentTime)
        XCTAssertEqual(h.payloads.last?.1, [0, 0, 0, 0])
        h.ack(OttaiConstants.charCurrentTime)
        XCTAssertEqual(h.transcript.last, "W:" + OttaiConstants.charCommand)
        XCTAssertEqual(h.payloads.filter { $0.0 == OttaiConstants.charDestructive }.count, 1)
    }

    @MainActor func testActivationMismatchMalformedAndTimeoutNeverReachRetainRTCOrActivate() throws {
        for fault in 0..<3 {
            let h = OttaiLifetimeTransportHarness()
            defer { h.clean() }
            h.transmitter.beginLifetimeTest(activation: true)
            h.ack(OttaiConstants.charMaxActiveTime)
            if fault == 0 { h.duration(15) }
            else if fault == 1 { h.transmitter.receiveLifetimeTest(uuid: OttaiConstants.charMaxActiveTime, value: [1, 2, 3]) }
            else { h.transmitter.failLifetimeTest() }
            XCTAssertEqual(h.transcript, ["W:" + OttaiConstants.charMaxActiveTime, "R:" + OttaiConstants.charMaxActiveTime])
            XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
            h.duration(30) // a late response after failure cannot resume the old sequence
            h.ack(OttaiConstants.charMaxActiveTime)
            XCTAssertEqual(h.transcript.count, 2)
        }
    }

    @MainActor func testCNActivationStopsIfSensorBecomesActiveBeforeReadbackOrActivate() {
        for beforeReadback in [true, false] {
            let h = OttaiLifetimeTransportHarness()
            defer { h.clean() }
            h.transmitter.beginLifetimeTest(activation: true)
            h.ack(OttaiConstants.charMaxActiveTime)
            if beforeReadback { h.status(3); h.duration(30) }
            else { h.duration(30); h.status(3); h.ack(OttaiConstants.charDestructive) }
            XCTAssertFalse(h.payloads.contains { $0.0 == OttaiConstants.charCommand })
        }
    }

    @MainActor func testMissingLifetimeReadPropertyBlocksBeforeAnyDurationWrite() {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        h.transmitter.lifetimeTestReadable = { $0 != OttaiConstants.charMaxActiveTime }
        h.transmitter.beginLifetimeTest(activation: true)
        XCTAssertTrue(h.transcript.isEmpty)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
    }

    @MainActor func testActiveRequestOnlyWritesDurationAndChecksStatusAfterReadback() {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        h.transmitter.beginLifetimeTest(activation: false)
        XCTAssertEqual(h.transcript, ["R:" + OttaiConstants.charCommand])
        h.status(3)
        XCTAssertEqual(h.transcript.last, "R:" + OttaiConstants.charMaxActiveTime)
        h.duration(15)
        XCTAssertTrue(OttaiRegistry.hasLifetimeIntent(h.id))
        XCTAssertEqual(h.payloads.map(\.0), [OttaiConstants.charMaxActiveTime])
        h.ack(OttaiConstants.charMaxActiveTime)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
        h.duration(30)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
        h.status(3)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), 30 * 86_400_000)
        XCTAssertFalse(OttaiRegistry.hasLifetimeIntent(h.id))
        XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: h.id).activeTimeMs, h.originalStart)
        XCTAssertEqual(OttaiRegistry.loadLastDataNo(h.id), 2_880)
        XCTAssertEqual(h.transcript, ["R:" + OttaiConstants.charCommand, "R:" + OttaiConstants.charMaxActiveTime,
            "W:" + OttaiConstants.charMaxActiveTime, "R:" + OttaiConstants.charMaxActiveTime, "R:" + OttaiConstants.charCommand])
    }

    @MainActor func testActiveRequestAbortsIfEndedStatusArrivesDuringBaselineRead() {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        h.transmitter.beginLifetimeTest(activation: false)
        h.status(3)
        h.status(4)
        h.duration(15)
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertFalse(OttaiRegistry.hasLifetimeIntent(h.id))
    }

    @MainActor func testActiveRequestDoesNotWriteWhenOriginalAgeAlreadyReachedThirtyDays() {
        let h = OttaiLifetimeTransportHarness(old: true)
        defer { h.clean() }
        h.transmitter.beginLifetimeTest(activation: false)
        h.status(3)
        h.duration(15)
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertFalse(OttaiRegistry.hasLifetimeIntent(h.id))
    }

    @MainActor func testActiveReadbackWithEndedFinalStatusDoesNotAdoptNewDuration() {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        h.transmitter.beginLifetimeTest(activation: false)
        h.status(3); h.duration(15); h.ack(OttaiConstants.charMaxActiveTime); h.duration(30); h.status(4)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
        XCTAssertTrue(OttaiRegistry.hasLifetimeIntent(h.id))
        XCTAssertEqual(h.payloads.count, 1)
    }

    @MainActor func testInterruptedActiveWriteIsReadOnlyOnTheNextExplicitRequest() {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        h.transmitter.beginLifetimeTest(activation: false)
        h.status(3); h.duration(15); h.ack(OttaiConstants.charMaxActiveTime)
        h.transmitter.disconnectLifetimeTest()
        let before = h.transcript.count
        h.configure()
        XCTAssertEqual(h.transcript.count, before) // reconnect does not replay a write
        h.transmitter.beginLifetimeTest(activation: false)
        h.status(3); h.duration(15); h.status(3)
        XCTAssertEqual(h.payloads.count, 1)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), h.oldLifetime)
        XCTAssertFalse(OttaiRegistry.hasLifetimeIntent(h.id))
        XCTAssertEqual(Array(h.transcript.suffix(3)), ["R:" + OttaiConstants.charCommand,
            "R:" + OttaiConstants.charMaxActiveTime, "R:" + OttaiConstants.charCommand])
    }

    @MainActor func testActiveBaselineAlreadyThirtyDaysDoesNotRewriteIt() {
        let h = OttaiLifetimeTransportHarness()
        defer { h.clean() }
        h.transmitter.beginLifetimeTest(activation: false)
        h.status(3); h.duration(30); h.status(3)
        XCTAssertTrue(h.payloads.isEmpty)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(h.id), 30 * 86_400_000)
    }


    func testDelayedAndUnorderedBatchKeepsOriginalStartAndWarmupBoundary() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for delay: TimeInterval in [60, 1_200] {
            let deliveredAt = start.addingTimeInterval(3_600 + delay)
            let latest = deliveredAt.addingTimeInterval(-delay)
            let readings = [
                GlucoseData(timeStamp: latest.addingTimeInterval(-300), glucoseLevelRaw: 110),
                GlucoseData(timeStamp: latest, glucoseLevelRaw: 115),
                GlucoseData(timeStamp: latest.addingTimeInterval(-600), glucoseLevelRaw: 105)
            ]
            let age = try XCTUnwrap(CGMOttaiTransmitter.sensorAge(for: readings, activeTimeMs: 1_800_000_000_000))
            XCTAssertEqual(latest.addingTimeInterval(-age), start)
            XCTAssertEqual(age, 3_600)
            XCTAssertEqual(latest.addingTimeInterval(-age + 3_600), start.addingTimeInterval(3_600))
        }
    }

    @MainActor func testBackfillBeforeWarmupCannotBecomeOldEnoughAtDelivery() throws {
        let readings = [GlucoseData(timeStamp: Date(timeIntervalSince1970: 1_800_003_540), glucoseLevelRaw: 110)]
        let age = try XCTUnwrap(CGMOttaiTransmitter.sensorAge(for: readings, activeTimeMs: 1_800_000_000_000))
        XCTAssertTrue(RootApplicationCoordinator.shouldSuppressReadingDuringWarmup(sensorAgeInSeconds: age, minimumWarmUpRequiredInMinutes: 60))
    }

    func testMissingOrInvalidSessionAgeIsNeverNegativeOrNonfinite() {
        let valid = GlucoseData(timeStamp: Date(timeIntervalSince1970: 1_800_000_000), glucoseLevelRaw: 110)
        XCTAssertNil(CGMOttaiTransmitter.sensorAge(for: [], activeTimeMs: 1_800_000_000_000))
        XCTAssertNil(CGMOttaiTransmitter.sensorAge(for: [valid], activeTimeMs: 0))
        XCTAssertNil(CGMOttaiTransmitter.sensorAge(for: [valid], activeTimeMs: 1_800_000_060_000))
        let invalid = GlucoseData(timeStamp: Date(timeIntervalSince1970: .infinity), glucoseLevelRaw: 110)
        XCTAssertNil(CGMOttaiTransmitter.sensorAge(for: [valid, invalid], activeTimeMs: 1_800_000_000_000))
    }

    @MainActor func testProductionDeliveryUsesMeasurementTimeAndCancelsReleasedSource() throws {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
        let keys = ["ottai_active_time_", "ottai_provisional_active_time_", "ottai_delivered_datano_"].map { $0 + id }
        defer { for key in keys { UserDefaults.standard.removeObject(forKey: key) } }
        let startMs: Int64 = 1_800_000_000_000
        OttaiRegistry.saveActiveTimeMs(id, startMs)
        let delegate = OttaiDeliveryDelegateSpy()
        let transmitter = CGMOttaiTransmitter(address: UUID().uuidString, name: "Ottai test", sensorId: id,
            bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        let newest = Date(timeIntervalSince1970: Double(startMs) / 1000 + 3_600)
        let readings = [GlucoseData(timeStamp: newest.addingTimeInterval(-300), glucoseLevelRaw: 110),
                        GlucoseData(timeStamp: newest, glucoseLevelRaw: 115)]
        delegate.received = expectation(description: "Production delivery")
        transmitter.deliver(readings, upTo: 60)
        wait(for: [delegate.received!], timeout: 2)
        XCTAssertEqual(delegate.batches, 1)
        XCTAssertEqual(delegate.startDate, Date(timeIntervalSince1970: Double(startMs) / 1000))
        let before = OttaiRegistry.loadDeliveredDataNo(id)
        transmitter.deliver(readings, upTo: 90)
        transmitter.prepareForRelease()
        let drained = expectation(description: "Released main callback drained")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(delegate.batches, 1)
        XCTAssertLessThanOrEqual(OttaiRegistry.loadDeliveredDataNo(id), max(before, 60))
    }

    @MainActor func testReconnectReissuesCancelledSessionObservationExactlyOnce() {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
        let keys = ["ottai_active_time_", "ottai_provisional_active_time_"].map { $0 + id }
        let previousStart = UserDefaults.standard.activeSensorStartDate
        UserDefaults.standard.activeSensorStartDate = nil
        defer {
            UserDefaults.standard.activeSensorStartDate = previousStart
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        }
        let startMs: Int64 = 1_800_000_000_000
        OttaiRegistry.saveActiveTimeMs(id, startMs)
        let delegate = OttaiDeliveryDelegateSpy()
        let transmitter = CGMOttaiTransmitter(address: UUID().uuidString, name: "Ottai test", sensorId: id,
            bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        transmitter.reportSensorSessionIfNeeded()
        transmitter.resetConnectionState()
        transmitter.reportSensorSessionIfNeeded()
        transmitter.reportSensorSessionIfNeeded()
        let drained = expectation(description: "Reconnected session observation delivered")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(delegate.sessionStarts, [Date(timeIntervalSince1970: Double(startMs) / 1000)])
        transmitter.prepareForRelease()
    }

    func testNothingKnownAsksForTheLastDay() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 0, deliveredDataNo: 0)
        XCTAssertEqual(range?.start, 5000 - dayOfRecords)
        XCTAssertEqual(range?.count, dayOfRecords)
    }

    func testUntrustedLastDataNoAlsoAsksForTheLastDay() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: -1, deliveredDataNo: 4990)
        XCTAssertEqual(range?.start, 5000 - dayOfRecords)
        XCTAssertEqual(range?.count, dayOfRecords)
    }

    func testYoungSensorStartsAtZero() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 30, lastDataNo: 0, deliveredDataNo: 0)
        XCTAssertEqual(range?.start, 0)
        XCTAssertEqual(range?.count, 30)
    }

    func testOnlyTheRecordsSinceTheLastSeenOneAreRequested() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 4990, deliveredDataNo: 4990)
        XCTAssertEqual(range?.start, 4991)
        XCTAssertEqual(range?.count, 9)
    }

    func testDeliveredMarkBehindLastSeenWins() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 4998, deliveredDataNo: 4980)
        XCTAssertEqual(range?.start, 4981)
        XCTAssertEqual(range?.count, 19)
    }

    func testMissingDeliveredMarkFallsBackToLastSeen() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 4990, deliveredDataNo: 0)
        XCTAssertEqual(range?.start, 4991)
        XCTAssertEqual(range?.count, 9)
    }

    func testNothingMissingGivesNil() {
        XCTAssertNil(CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 4999, deliveredDataNo: 4999))
        XCTAssertNil(CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 4999, deliveredDataNo: 0))
    }

    func testLastSeenSlightlyAheadOfLiveGivesNil() {
        XCTAssertNil(CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5000, lastDataNo: 5003, deliveredDataNo: 5003))
    }

    func testLongAbsenceIsCappedToOneDay() {
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 9000, lastDataNo: 2000, deliveredDataNo: 2000)
        XCTAssertEqual(range?.start, 9000 - dayOfRecords)
        XCTAssertEqual(range?.count, dayOfRecords)
    }

    func testEndedSensorIncludesItsLastRecordWhenNeverDelivered() {
        // The ended path passes lastDataNo + 1 as the end, so the last record itself is inside the range.
        let range = CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 5001, lastDataNo: 4990, deliveredDataNo: 4990)
        XCTAssertEqual(range?.start, 4991)
        XCTAssertEqual(range?.count, 10)
    }

    func testNoLiveRecordGivesNil() {
        XCTAssertNil(CGMOttaiTransmitter.startupBackfillRange(liveDataNo: 0, lastDataNo: 0, deliveredDataNo: 0))
    }
}

private final class OttaiDeliveryDelegateSpy: CGMTransmitterDelegate, BluetoothTransmitterDelegate {
    var received: XCTestExpectation?
    var batches = 0
    var startDate: Date?
    var sessionStarts: [Date] = []
    func cgmTransmitterInfoReceived(glucoseData: inout [GlucoseData], transmitterBatteryInfo: TransmitterBatteryInfo?, sensorAge: TimeInterval?) {
        batches += 1
        startDate = sensorAge.flatMap { age in glucoseData.map(\.timeStamp).max()?.addingTimeInterval(-age) }
        received?.fulfill()
    }
    func newSensorDetected(sensorStartDate: Date?) { if let sensorStartDate { sessionStarts.append(sensorStartDate) } }
    func sensorStopDetected() {}
    func sensorNotDetected() {}
    func errorOccurred(xDripError: XdripError) {}
    func didConnectTo(bluetoothTransmitter: BluetoothTransmitter) {}
    func didDisconnectFrom(bluetoothTransmitter: BluetoothTransmitter) {}
    func deviceDidUpdateBluetoothState(state: CBManagerState, bluetoothTransmitter: BluetoothTransmitter) {}
    func transmitterNeedsPairing(bluetoothTransmitter: BluetoothTransmitter) {}
    func successfullyPaired() {}
    func pairingFailed() {}
    func error(message: String) {}
    func heartBeat() {}
}


private final class OttaiLifetimeTransportHarness {
    let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
    let bluetoothID = UUID().uuidString
    let account: OttaiAccountContext
    let key = "00112233445566778899aabbccddeeff"
    let oldLifetime: Int64 = 15 * 86_400_000
    let originalStart: Int64
    let delegate = OttaiDeliveryDelegateSpy()
    var transcript: [String] = []
    var payloads: [(String, [UInt8])] = []
    let transmitter: CGMOttaiTransmitter
    var materials: OttaiRegistry.DeviceMaterials {
        var m = OttaiRegistry.DeviceMaterials()
        m.deviceVersion = "E1.2.6(V1.7.SH2616.1),STDRD"
        m.coefficient = "1.0,2.0"
        m.activeExpireTimeMs = 14 * 86_400_000
        return m
    }

    init(old: Bool = false, globalAccount: Bool = false, apiBase: String? = nil) {
        account = OttaiAccountContext(apiBase: apiBase ?? (globalAccount ? OttaiConstants.apiBaseGlobal : OttaiConstants.apiBase),
            userId: "fixture-user", login: "fixture@example.invalid", generation: "fixture-generation")
        originalStart = Int64(Date().timeIntervalSince1970 * 1000) - (old ? 31 : 2) * 86_400_000
        OttaiRegistry.saveActiveTimeMs(id, originalStart)
        OttaiRegistry.saveLastDataNo(id, 2_880)
        OttaiRegistry.saveAcceptedMaxActive(id, oldLifetime, evidence: .sensorReadback)
        transmitter = CGMOttaiTransmitter(address: bluetoothID, name: "Ottai protocol test", sensorId: id,
            bluetoothTransmitterDelegate: delegate, cGMTransmitterDelegate: delegate)
        let checkpoint = OttaiActivationAttempt(sensorID: id, bluetoothID: bluetoothID,
            apiBase: account.apiBase, userID: account.userId, authorizedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        _ = OttaiRegistry.saveActivationCheckpoint(checkpoint)
        transmitter.lifetimeTestRead = { [weak self] uuid in self?.transcript.append("R:" + uuid) }
        transmitter.lifetimeTestWrite = { [weak self] uuid, bytes in
            self?.transcript.append("W:" + uuid); self?.payloads.append((uuid, bytes)); return true
        }
        configure()
    }
    var preparedMaterials: OttaiRegistry.DeviceMaterials {
        var m = materials
        m.keyAHex = String(repeating: "00", count: 96)
        m.method = "C0"
        return m
    }
    func configure() { transmitter.configureLifetimeTest(sessionKeyHex: key, account: account) }
    func status(_ value: UInt8) { transmitter.receiveLifetimeTest(uuid: OttaiConstants.charCommand, value: [value]) }
    func duration(_ days: Int64) {
        let seconds = UInt64(days * 86_400)
        transmitter.receiveLifetimeTest(uuid: OttaiConstants.charMaxActiveTime,
            value: (0..<8).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) })
    }
    func ack(_ uuid: String) { transmitter.acknowledgeLifetimeTest(uuid: uuid) }
    func clean() {
        transmitter.disconnectLifetimeTest()
        transmitter.prepareForRelease()
        for prefix in ["ottai_active_time_", "ottai_provisional_active_time_", "ottai_last_datano_", "ottai_accepted_max_active_",
                       "ottai_lifetime_evidence_", "ottai_lifetime_intent_", "ottai_lifetime_status_", "ottai_activation_checkpoint_", "ottai_activation_status_",
                       "ottai_preparation_", "ottai_legacy_preparation_", "ottai_activation_started_", "ottai_sensor_status_", "ottai_record_size_", "ottai_delivered_datano_", "ottai_keya_", "ottai_method_", "ottai_coeff_", "ottai_active_expire_", "ottai_retain_time_",
                       "ottai_preheat_period_", "ottai_grace_period_", "ottai_factory_calibration_k_", "ottai_factory_calibration_b_",
                       "ottai_device_version_", "ottai_device_id_", "ottai_act_tried_", "ottai_v3_bootstrap_pending_", "ottai_pending_bind_", "ottai_last_validated_device_version_"] {
            UserDefaults.standard.removeObject(forKey: prefix + id)
        }
    }
}
