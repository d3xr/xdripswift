//
//  OttaiServerActivationTests.swift
//  xdripTests
//
//  Server-assisted activation of new Syai sensors.
//

import XCTest
import UIKit
import CryptoKit
@testable import xdrip

final class OttaiServerActivationTests: XCTestCase {

    func testDonorPreparationDictionaryMigratesWithoutBecomingActivationAuthorization() {
        let suite = "OttaiLegacyPreparation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "ottai_preparation_" + activationSensor
        defaults.set(["version": "V1.7", "address": activationBluetoothID], forKey: key)
        XCTAssertFalse(OttaiRegistry.hasPreparationCheckpoint(activationSensor, in: defaults))
        XCTAssertNil(OttaiRegistry.loadPreparationCheckpoint(activationSensor, in: defaults))
        XCTAssertNil(defaults.object(forKey: key))
        let migrated = defaults.dictionary(forKey: "ottai_legacy_preparation_" + activationSensor)
        XCTAssertEqual(migrated?["version"] as? String, "V1.7")
        XCTAssertEqual(migrated?["address"] as? String, activationBluetoothID)
    }

    func testMalformedPreparationStillBlocksInsteadOfBecomingFreshAuthorization() {
        let suite = "OttaiCorruptPreparation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "ottai_preparation_" + activationSensor
        for value in [Data([0xff]), ["version": "V1.7", "address": "invalid"]] as [Any] {
            defaults.set(value, forKey: key)
            XCTAssertTrue(OttaiRegistry.hasPreparationCheckpoint(activationSensor, in: defaults))
            XCTAssertNil(OttaiRegistry.loadPreparationCheckpoint(activationSensor, in: defaults))
            XCTAssertNotNil(defaults.object(forKey: key))
        }
    }

    func testLegacyPreparationCannotOverwriteAccountBoundCheckpoint() throws {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        defer { OttaiRegistry.removeSensor(id) }
        let checkpoint = OttaiPreparationCheckpoint(sensorID: id, bluetoothID: activationBluetoothID,
            apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: activationStart)
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(checkpoint))
        OttaiRegistry.savePreparation(id, version: "V1.7", address: activationBluetoothID)
        XCTAssertEqual(OttaiRegistry.loadPreparationCheckpoint(id), checkpoint)
        XCTAssertEqual(OttaiRegistry.preparation(id)?.version, "V1.7")
        OttaiRegistry.clearPreparation(id)
        XCTAssertEqual(OttaiRegistry.loadPreparationCheckpoint(id), checkpoint)
        XCTAssertNil(OttaiRegistry.preparation(id))
    }

    func testNFCWakeCapabilityDefaultsDisabledAndAcceptsOnlyExplicitBuildValues() {
        for value in [nil, "NO", "false", "$(OTTAI_NFC_WAKE_ENABLED)", "", false] as [Any?] {
            XCTAssertFalse(OttaiNFCWake.signingCapability(value))
        }
        for value in [true, "YES", "true", "  yes  ", "1"] as [Any] {
            XCTAssertTrue(OttaiNFCWake.signingCapability(value))
        }
        XCTAssertTrue(OttaiNFCWake.requiresWake(apiBase: OttaiConstants.apiBase))
        XCTAssertTrue(OttaiNFCWake.requiresWake(apiBase: OttaiConstants.apiBaseSyai))
        XCTAssertFalse(OttaiNFCWake.requiresWake(apiBase: OttaiConstants.apiBaseGlobal))
    }

    @MainActor func testNFCWakeDisabledSigningNeverCreatesOrBeginsAReader() {
        var factories = 0, outcomes: [OttaiNFCWake.Outcome] = []
        let wake = OttaiNFCWake(enabled: false, hardwareAvailable: { XCTFail("Do not probe NFC when signing is disabled"); return true },
            isForeground: { true }, makeReader: { _ in factories += 1; return nil })
        wake.start(apiBase: OttaiConstants.apiBase, isOwnerCurrent: { true }) { outcomes.append($0) }
        XCTAssertEqual(factories, 0)
        guard case .unavailable(let message)? = outcomes.first else { XCTFail("Disabled signing must be explained"); return }
        XCTAssertTrue(message.contains("provisioning profile"))
        XCTAssertEqual(outcomes.count, 1)
        wake.cancel()
        XCTAssertEqual(outcomes.count, 1)
    }

    @MainActor func testGlobalAndBackgroundNFCWakeNeverCreateAReader() {
        var factories = 0, outcomes: [OttaiNFCWake.Outcome] = []
        let wake = OttaiNFCWake(enabled: true, hardwareAvailable: { true }, isForeground: { false },
            makeReader: { _ in factories += 1; return nil })
        wake.start(apiBase: OttaiConstants.apiBaseGlobal, isOwnerCurrent: { true }) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.notRequired])
        wake.start(apiBase: OttaiConstants.apiBaseSyai, isOwnerCurrent: { true }) { outcomes.append($0) }
        XCTAssertEqual(factories, 0)
        guard case .unavailable? = outcomes.last else { XCTFail("NFC requires foreground"); return }
    }

    @MainActor func testNFCRFReadinessAndTagDetectionDoNotActivateOrVerifyASensor() {
        let reader = OttaiNFCWakeReaderSpy()
        var events: ((OttaiNFCWake.Event) -> Void)?, timeouts: [() -> Void] = []
        var ready = 0, outcomes: [OttaiNFCWake.Outcome] = []
        let wake = OttaiNFCWake(enabled: true, hardwareAvailable: { true }, isForeground: { true },
            scheduleTimeout: { timeouts.append($0) }, makeReader: { events = $0; return reader })
        wake.start(apiBase: OttaiConstants.apiBaseSyai, isOwnerCurrent: { true }, onReaderReady: { ready += 1 }) { outcomes.append($0) }
        XCTAssertEqual(reader.begins, 1)
        events?(.readerReady)
        XCTAssertEqual(ready, 1)
        XCTAssertTrue(outcomes.isEmpty)
        events?(.tagDetected)
        XCTAssertEqual(outcomes, [.tagObserved])
        XCTAssertEqual(reader.invalidations, 1)
        XCTAssertTrue(outcomes[0].message.contains("identity and the sensor wake are not verified"))
        XCTAssertTrue(outcomes[0].message.contains("Check Bluetooth"))
        XCTAssertEqual(timeouts.count, 1)
        timeouts[0]() // a late watchdog cannot change the observation
        events?(.invalidated(.cancelled))
        XCTAssertEqual(outcomes.count, 1)
    }

    @MainActor func testNFCWakeCancellationAndStaleCallbacksNeverReportAnObservation() {
        let reader = OttaiNFCWakeReaderSpy()
        var callbacks: [(OttaiNFCWake.Event) -> Void] = [], timeouts: [() -> Void] = []
        var outcomes: [OttaiNFCWake.Outcome] = []
        let wake = OttaiNFCWake(enabled: true, hardwareAvailable: { true }, isForeground: { true },
            scheduleTimeout: { timeouts.append($0) }, makeReader: { callbacks.append($0); return reader })
        wake.start(apiBase: OttaiConstants.apiBase, isOwnerCurrent: { true }) { outcomes.append($0) }
        reader.onInvalidate = { callbacks[0](.invalidated(.cancelled)) }
        wake.cancel()
        callbacks[0](.tagDetected)
        XCTAssertEqual(outcomes, [.cancelled])
        wake.start(apiBase: OttaiConstants.apiBase, isOwnerCurrent: { true }) { outcomes.append($0) }
        callbacks[0](.tagDetected)
        timeouts[0]()
        XCTAssertEqual(outcomes, [.cancelled])
        callbacks[1](.invalidated(.timedOut))
        XCTAssertEqual(outcomes, [.cancelled, .timedOut])
        callbacks[1](.tagDetected)
        XCTAssertEqual(outcomes.count, 2)
    }

    @MainActor func testNFCWakeChangedOwnerAndBackgroundInvalidateExactlyOnce() {
        let reader = OttaiNFCWakeReaderSpy(), notifications = NotificationCenter()
        var callback: ((OttaiNFCWake.Event) -> Void)?, current = true, outcomes: [OttaiNFCWake.Outcome] = []
        let wake = OttaiNFCWake(enabled: true, hardwareAvailable: { true }, isForeground: { true }, notifications: notifications,
            scheduleTimeout: { _ in }, makeReader: { callback = $0; return reader })
        wake.start(apiBase: OttaiConstants.apiBase, isOwnerCurrent: { current }) { outcomes.append($0) }
        current = false
        callback?(.tagDetected)
        XCTAssertEqual(outcomes, [.ownerChanged])
        current = true
        wake.start(apiBase: OttaiConstants.apiBase, isOwnerCurrent: { current }) { outcomes.append($0) }
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        callback?(.tagDetected)
        XCTAssertEqual(outcomes, [.ownerChanged, .cancelled])
        XCTAssertEqual(reader.invalidations, 2)
    }

    func testThirtyDayCandidatesNeverExceedRequestedMaximumEvenWithLongCloudLifetime() {
        for cloud in ([0, 14 * 86_400_000, 15 * 86_400_000, 45 * 86_400_000] as [Int64]) {
            let candidates = OttaiConstants.activationMaxActiveCandidatesMs(cloudActiveExpireMs: cloud)
            XCTAssertEqual(candidates.first, 30 * 86_400_000)
            XCTAssertTrue(candidates.allSatisfy { $0 <= 30 * 86_400_000 })
            XCTAssertEqual(Set(candidates).count, candidates.count)
        }
    }

    func testLifetimeWireDecoderPreservesMinuteIndicesAcrossSignedBoundary() throws {
        for minutes in [32_767, 32_768, 43_200] {
            let seconds = UInt64(minutes * 60)
            let plain = (0..<8).map { UInt8(truncatingIfNeeded: seconds >> ($0 * 8)) }
            let expected = Int64(seconds) * 1000
            XCTAssertEqual(OttaiLifetimeTransaction.decode(plain, sessionKeyHex: ""), expected)
            XCTAssertEqual(OttaiLifetimeTransaction.decode(Array(plain.prefix(4)), sessionKeyHex: ""), expected)
            let encrypted = try XCTUnwrap(OttaiCrypto.encryptPayload(plain, sessionKeyHex: activationSessionKey))
            XCTAssertEqual(OttaiLifetimeTransaction.decode(encrypted, sessionKeyHex: activationSessionKey), expected)
            XCTAssertNil(OttaiLifetimeTransaction.decode(encrypted, sessionKeyHex: ""))
            XCTAssertNil(OttaiLifetimeTransaction.decode(encrypted, sessionKeyHex: "invalid"))
        }
        XCTAssertNil(OttaiLifetimeTransaction.decode([0, 0, 0], sessionKeyHex: activationSessionKey))
        XCTAssertNil(OttaiLifetimeTransaction.decode([UInt8](repeating: 255, count: 8), sessionKeyHex: activationSessionKey))
        let badPadding = try XCTUnwrap(OttaiCrypto.encryptPayload([0, 0x8d, 0x27, 0, 0, 0, 0, 0, 1], sessionKeyHex: activationSessionKey))
        XCTAssertNil(OttaiLifetimeTransaction.decode(badPadding, sessionKeyHex: activationSessionKey))
    }

    func testLegacySentActivationCheckpointSurvivesSeparatePreparationSchema() throws {
        let oldJSON = """
        {"sensorID":"AABBCCDDEEFF","bluetoothID":"7D473D30-41C1-45D0-A3C5-E91F41187211","apiBase":"https://seas.ottai.com","userID":"fixture-user","authorizedAtMs":1790000000000,"commandSentAtMs":1790000001000,"commandConnectionID":"BF30A437-9665-4FA3-921E-E95AB7ECBA48","confirmed":false}
        """
        let old = try JSONDecoder().decode(OttaiActivationAttempt.self, from: Data(oldJSON.utf8))
        XCTAssertTrue(old.isValid)
        XCTAssertEqual(old.commandSentAtMs, 1_790_000_001_000)
        XCTAssertEqual(old.commandConnectionID, activationConnectionID)
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 2, commandSentAtMs: old.commandSentAtMs), .confirmOnly)
        XCTAssertEqual(try JSONDecoder().decode(OttaiActivationAttempt.self, from: JSONEncoder().encode(old)), old)
    }

    func testPreparedKeysCannotEraseIncompleteFactoryCheckpoint() throws {
        let suite = "OttaiPreparation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var checkpoint = OttaiPreparationCheckpoint(sensorID: activationSensor, bluetoothID: activationBluetoothID,
            apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: activationStart)
        checkpoint.liveFirmware = "E1.2.6(V1.7.SH2616.1),STDRD"
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(checkpoint, in: defaults))
        checkpoint.bindAttempted = true
        checkpoint.materialsSaved = true
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(checkpoint, in: defaults))
        XCTAssertFalse(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(activationSensor, in: defaults)).factoryComplete)
        checkpoint.factoryComplete = true
        XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(checkpoint, in: defaults))
        XCTAssertTrue(try XCTUnwrap(OttaiRegistry.loadPreparationCheckpoint(activationSensor, in: defaults)).factoryComplete)
        XCTAssertFalse(checkpoint.matches(sensorID: activationSensor, bluetoothID: UUID().uuidString, account: activationAccount))
    }

    func testFreshCNFourAndFiveNeedNoFactoryCoefficientsOrCalibrationWrite() throws {
        for minor in [4, 5] {
            var materials = OttaiRegistry.DeviceMaterials()
            materials.deviceVersion = "V1.\(minor).S2530.1"
            let writes = try OttaiCNPreparation.writes(materials: materials, sessionKeyHex: activationSessionKey,
                durationMs: OttaiConstants.extendedLifetimeMs)
            XCTAssertEqual(writes.map(\.kind), [.duration])
            XCTAssertFalse(writes.contains { $0.characteristic == OttaiConstants.charDestructive })
        }
    }

    func testLifetimeEvidenceDistinguishesLegacyWriteAndMatchingReadback() {
        let id = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).uppercased()
        let valueKey = "ottai_accepted_max_active_" + id
        let evidenceKey = "ottai_lifetime_evidence_" + id
        defer {
            UserDefaults.standard.removeObject(forKey: valueKey)
            UserDefaults.standard.removeObject(forKey: evidenceKey)
        }
        let thirtyDays: Int64 = 30 * 86_400_000
        UserDefaults.standard.set(NSNumber(value: thirtyDays), forKey: valueKey)
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(id), thirtyDays)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(id), .legacy)

        OttaiRegistry.saveAcceptedMaxActive(id, thirtyDays, evidence: .writeAcknowledged)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(id), .writeAcknowledged)
        // Re-reading saved state after reconnect does not promote ACK to read-back.
        XCTAssertEqual(OttaiRegistry.loadAcceptedMaxActive(id), thirtyDays)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(id), .writeAcknowledged)
        // An equal read-back improves provenance even though the number is unchanged.
        OttaiRegistry.saveAcceptedMaxActive(id, thirtyDays, evidence: .sensorReadback)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(id), .sensorReadback)
        // An older writer or interrupted update cannot attach stale proof to another value.
        UserDefaults.standard.set(NSNumber(value: 15 * 86_400_000), forKey: valueKey)
        XCTAssertEqual(OttaiRegistry.lifetimeEvidence(id), .legacy)
    }

    func testServerSignatureRejectionRetriesThenScansForAnotherSensor() {
        let code = "DEVICE_AUTH_SIGN_ERROR"
        XCTAssertEqual(ottaiServerAuthRecovery(code: code, signatureFailures: 1, activateSent: false), .retryConnection)
        XCTAssertEqual(ottaiServerAuthRecovery(code: code, signatureFailures: 2, activateSent: false), .scanNextSensor)
        // A different device gets its own fresh-challenge retry.
        XCTAssertEqual(ottaiServerAuthRecovery(code: code, signatureFailures: 1, activateSent: false), .retryConnection)
    }

    func testServerAuthRecoveryNeverRetriesAfterActivationWasSent() {
        for failures in [1, 2, 3] {
            XCTAssertEqual(ottaiServerAuthRecovery(code: "DEVICE_AUTH_SIGN_ERROR", signatureFailures: failures, activateSent: true), .stop)
        }
    }

    func testOtherServerErrorsDoNotExcludeBluetoothSensors() {
        for code in ["", "AuthFailed_LoginElsewhere", "DEVICE_ALREADY_USED", "DEVICE_AUTH_SIGN_ERROR_OTHER"] {
            XCTAssertEqual(ottaiServerAuthRecovery(code: code, signatureFailures: 2, activateSent: false), .stop)
        }
    }

    // MARK: - entry mode

    private func mode(keys: Bool = false, pendingBind: Bool = false, bootstrap: Bool = true,
                      session: Bool = true, requested: Bool = true) -> OttaiAuthEntryMode {
        ottaiAuthEntryMode(hasAuthKeys: keys, pendingBind: pendingBind, bootstrapPending: bootstrap,
                           sessionAvailable: session, activationRequested: requested)
    }

    func testStoredKeysAlwaysWin() {
        XCTAssertEqual(mode(keys: true, pendingBind: true), .storedMaterialAuth)
    }

    func testPendingBindNeverActivatesAgain() {
        XCTAssertEqual(mode(pendingBind: true), .awaitingBind)
    }

    func testServerActivationNeedsTheUsersRequest() {
        XCTAssertEqual(mode(requested: false), .blocked)
        XCTAssertEqual(mode(), .serverAssistedActivation)
    }

    func testServerActivationNeedsAV3CheckAndASession() {
        XCTAssertEqual(mode(bootstrap: false), .blocked)
        XCTAssertEqual(mode(session: false), .blocked)
    }

    // MARK: - validateDeviceByMacV3 (China; Syai always uses V3)

    func testChinaMovesOnToV3OnlyOnUpgradeCode() {
        XCTAssertTrue(OttaiCloudClient.shouldTryValidateV3(apiBase: OttaiConstants.apiBase, profile: .cnPhone, v2FailureCode: "AppDevice_Upgrade_Version"))
        XCTAssertFalse(OttaiCloudClient.shouldTryValidateV3(apiBase: OttaiConstants.apiBase, profile: .cnPhone, v2FailureCode: "AppDevice_AlreadyUsed"))
        XCTAssertFalse(OttaiCloudClient.shouldTryValidateV3(apiBase: OttaiConstants.apiBase, profile: .watch, v2FailureCode: "AppDevice_Upgrade_Version"))
        XCTAssertFalse(OttaiCloudClient.shouldTryValidateV3(apiBase: OttaiConstants.apiBaseGlobal, profile: .watch, v2FailureCode: "AppDevice_Upgrade_Version"))
    }

    func testChinaBindV3Body() {
        let body = OttaiCloudClient.bindRequestBody(mac: "6CA04230E260", deviceVersion: "v", userId: "42", activeTime: 1_760_000_000, contract: .v3)
        XCTAssertEqual(body["newBindType"] as? Int, 2)
        XCTAssertEqual(body["userId"] as? String, "42")
    }

    // MARK: - Syai client

    func testUnbindTypeFollowsWearTime() {
        var m = OttaiRegistry.DeviceMaterials()
        m.activeTimeMs = 1_000_000
        m.activeExpireTimeMs = 15 * 86_400_000
        XCTAssertEqual(OttaiCloudClient.syaiUnbindType(materials: m, acceptedMaxActiveMs: 0, nowMs: 1_000_000 + 16 * 86_400_000), 10)
        XCTAssertEqual(OttaiCloudClient.syaiUnbindType(materials: m, acceptedMaxActiveMs: 0, nowMs: 1_000_000 + 86_400_000), 13)
    }

    func testTraceIdIsVersion1() {
        let id = OttaiSyaiClient.traceId()
        let parts = id.split(separator: "-")
        XCTAssertEqual(parts.map(\.count), [8, 4, 4, 4, 12])
        XCTAssertEqual(parts[2].first, "1")
    }

    func testJwtPayload() {
        // {"sub":"42","app_name":"Syai Tag"}
        let jwt = "x.eyJzdWIiOiI0MiIsImFwcF9uYW1lIjoiU3lhaSBUYWcifQ.y"
        XCTAssertEqual(OttaiSyaiClient.jwtPayload(jwt)?["sub"] as? String, "42")
        XCTAssertEqual(OttaiSyaiClient.jwtPayload(jwt)?["app_name"] as? String, "Syai Tag")
    }

    func testUploadAddsCheckpointEveryFifthReading() {
        func sample(_ n: Int) -> OttaiCloudUploader.Sample {
            OttaiCloudUploader.Sample(dataNo: n, runtimeSec: n * 60, voltage: 1, rawCurrent: 2, temperatureC: 30, mmol: 5.5,
                                      sampleMs: 0, receivedAtMs: 0, originBytes: [1, 2], live: true)
        }
        var m = OttaiRegistry.DeviceMaterials()
        m.deviceId = 7
        let list = OttaiCloudUploader.uploadBody(batch: [sample(4), sample(5)], materials: m)["dataList"] as? [[String: Any]]
        XCTAssertEqual(list?.map { $0["dataType"] as? Int }, [1, 1, 2])
        XCTAssertTrue(list?[2]["origin"] is NSNull)
    }

    // MARK: - firmware -> deviceVersion

    func testSoftwareRevisionStopsBeforeTrailingGarbage() {
        let version = "E2.0.3(V1.7.SH22601.3),STDRD"
        XCTAssertEqual(OttaiCloudClient.softwareRevision(Array(version.utf8) + [0, 255, 254]), version)
        XCTAssertEqual(OttaiCloudClient.softwareRevision([0, 255]), "")
        XCTAssertEqual(OttaiCloudClient.softwareRevision(Array(" V1.7 ".utf8)), "V1.7")
    }

    func testRequiredFirmwareUpgradeKeepsItsBusinessCode() {
        let failure = OttaiCloudClient.CloudFailure(text: "server failure", code: "OTA_UPGRADE_REQUIRED")
        XCTAssertEqual(failure.code, "OTA_UPGRADE_REQUIRED")
        XCTAssertTrue(failure.text.contains("firmware update"))
        XCTAssertEqual(OttaiCloudClient.CloudFailure(text: "other", code: "OTHER").text, "other")
    }

    func testDeviceVersionFromFirmware() {
        XCTAssertEqual(OttaiCloudClient.deviceVersion(fromFirmware: "E2.0.3(V1.7.SH22601.3),STDRD"), "V1.7.SH22601.3")
        XCTAssertEqual(OttaiCloudClient.deviceVersion(fromFirmware: " V1.7.S2530.1 "), "V1.7.S2530.1")
        XCTAssertEqual(OttaiCloudClient.deviceVersion(fromFirmware: "E1.1()"), "E1.1()")
    }

    // MARK: - Activation readback and interruption recovery

    private let activationSensor = "AABBCCDDEEFF"
    private let activationBluetoothID = "7D473D30-41C1-45D0-A3C5-E91F41187211"
    private let activationConnectionID = "BF30A437-9665-4FA3-921E-E95AB7ECBA48"
    private let activationStart: Int64 = 1_790_000_000_000

    private var activationAccount: OttaiAccountContext {
        OttaiAccountContext(apiBase: OttaiConstants.apiBaseGlobal, userId: "fixture-user", login: "fixture@example.invalid", generation: "session-one")
    }

    private func activationAttempt(sent: Bool = false, confirmed: Bool = false) -> OttaiActivationAttempt {
        var attempt = OttaiActivationAttempt(sensorID: activationSensor, bluetoothID: activationBluetoothID,
            apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: activationStart - 5_000)
        if sent {
            attempt.commandSentAtMs = activationStart
            attempt.commandConnectionID = activationConnectionID
        }
        attempt.confirmed = confirmed
        return attempt
    }

    private func withActivationDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "OttaiActivationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testActivationCannotBeginBeforeReadingCommandStatus() {
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: -1, commandSentAtMs: 0), .readStatus)
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: -1, commandSentAtMs: activationStart,
            commandFromCurrentConnection: false), .readStatus)
    }

    func testOnlyAnUnstartedSensorWithoutASentCommandMayWriteFrames() {
        for status in 0...2 {
            XCTAssertEqual(OttaiActivationGate.decide(commandStatus: status, commandSentAtMs: 0), .writeFrames)
        }
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 3, commandSentAtMs: 0), .alreadyActive)
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 4, commandSentAtMs: 0), .ended)
    }

    func testUncertainCommandOnTheSameConnectionNeverRewritesActivationFrames() {
        for status in 0...2 {
            XCTAssertEqual(OttaiActivationGate.decide(commandStatus: status, commandSentAtMs: activationStart), .confirmOnly)
        }
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 3, commandSentAtMs: activationStart), .bind(startMs: activationStart))
    }

    func testAnotherAuthenticatedConnectionCanRetryOnlyAfterAFreshInactiveReadback() {
        for status in 0...2 {
            XCTAssertEqual(OttaiActivationGate.decide(commandStatus: status, commandSentAtMs: activationStart,
                commandFromCurrentConnection: false), .retryConfirmedInactive)
        }
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 3, commandSentAtMs: activationStart,
            commandFromCurrentConnection: false), .bind(startMs: activationStart))
    }

    func testEndedSensorNeverBindsOrReactivatesAfterAnInterruptedWrite() {
        for status in [4, 5, 255] {
            for sameConnection in [false, true] {
                XCTAssertEqual(OttaiActivationGate.decide(commandStatus: status, commandSentAtMs: activationStart,
                    commandFromCurrentConnection: sameConnection), .ended)
            }
        }
    }

    func testActivationWriteAcknowledgmentIsInsufficientForBinding() {
        // A sent command with the old inactive status remains uncertain. Only the
        // sensor's active readback can authorize cloud bind.
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 0, commandSentAtMs: activationStart), .confirmOnly)
        XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 3, commandSentAtMs: activationStart), .bind(startMs: activationStart))
    }

    func testServerWriteOrderStopsAfterTheActivationCommand() {
        var step: OttaiServerActivationWrite? = .coefficient
        var sequence: [OttaiServerActivationWrite] = []
        while let current = step {
            sequence.append(current)
            step = current.next
            XCTAssertLessThanOrEqual(sequence.count, 4)
            if sequence.count > 4 { break }
        }
        XCTAssertEqual(sequence, [.coefficient, .duration, .rtc, .activate])
        XCTAssertNil(OttaiServerActivationWrite.activate.next)
        XCTAssertEqual(sequence.map(\.characteristic), [OttaiConstants.charDestructive, OttaiConstants.charMaxActiveTime,
            OttaiConstants.charCurrentTime, OttaiConstants.charCommand])
        XCTAssertEqual(Set(sequence.map(\.characteristic)).count, 4)
    }

    func testInterruptionBeforeAndAfterTheCommandHasDifferentRecovery() throws {
        try withActivationDefaults { defaults in
            for lastWrite in OttaiServerActivationWrite.allCases {
                let attempt = activationAttempt(sent: lastWrite == .activate)
                XCTAssertTrue(OttaiRegistry.saveActivationCheckpoint(attempt, in: defaults))
                let restored = try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults))
                if lastWrite == .activate {
                    XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 0, commandSentAtMs: restored.commandSentAtMs), .confirmOnly)
                    XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 3, commandSentAtMs: restored.commandSentAtMs), .bind(startMs: activationStart))
                } else {
                    XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 0, commandSentAtMs: restored.commandSentAtMs), .writeFrames)
                    XCTAssertEqual(OttaiActivationGate.decide(commandStatus: 3, commandSentAtMs: restored.commandSentAtMs), .alreadyActive)
                }
            }
        }
    }

    // MARK: - Durable identity and account scope

    func testCheckpointRoundTripPreservesTheOriginalCommandTime() throws {
        try withActivationDefaults { defaults in
            let attempt = activationAttempt(sent: true)
            XCTAssertTrue(OttaiRegistry.saveActivationCheckpoint(attempt, in: defaults))
            let restored = try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults))
            XCTAssertEqual(restored, attempt)
            XCTAssertEqual(restored.commandSentAtMs, activationStart)
            XCTAssertEqual(restored.commandConnectionID, activationConnectionID)
            XCTAssertFalse(restored.confirmed)
        }
    }

    func testConfirmedCheckpointRetainsTimeAndDoesNotAuthorizeActivationAgain() throws {
        try withActivationDefaults { defaults in
            let attempt = activationAttempt(sent: true, confirmed: true)
            XCTAssertTrue(OttaiRegistry.saveActivationCheckpoint(attempt, in: defaults))
            XCTAssertEqual(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults), attempt)
            XCTAssertEqual(mode(pendingBind: true, requested: true), .awaitingBind)
        }
    }

    func testCheckpointMatchesCanonicalMACAndCaseInsensitiveBluetoothUUID() {
        let attempt = activationAttempt(sent: true)
        XCTAssertTrue(attempt.matches(sensorID: "aa:bb:cc:dd:ee:ff", bluetoothID: activationBluetoothID.lowercased(), account: activationAccount))
        XCTAssertFalse(attempt.matches(sensorID: "001122334455", bluetoothID: activationBluetoothID, account: activationAccount))
        XCTAssertFalse(attempt.matches(sensorID: activationSensor, bluetoothID: "D0CD9FBE-66D5-4C26-9044-933E4442CA15", account: activationAccount))
    }

    func testCheckpointCannotCrossUserOrRegion() {
        let attempt = activationAttempt(sent: true)
        let otherUser = OttaiAccountContext(apiBase: activationAccount.apiBase, userId: "other-user", login: activationAccount.login)
        let otherRegion = OttaiAccountContext(apiBase: OttaiConstants.apiBase, userId: activationAccount.userId, login: activationAccount.login)
        XCTAssertFalse(attempt.matches(sensorID: activationSensor, bluetoothID: activationBluetoothID, account: otherUser))
        XCTAssertFalse(attempt.matches(sensorID: activationSensor, bluetoothID: activationBluetoothID, account: otherRegion))
    }

    func testReauthenticationRejectsStaleCallbackButKeepsTheSameUsersRecoveryIntent() {
        withActivationDefaults { defaults in
            defaults.set(activationAccount.apiBase, forKey: "ottai_api_base")
            defaults.set(activationAccount.userId, forKey: "ottai_user_id")
            defaults.set(activationAccount.login, forKey: "ottai_account_login")
            defaults.set(activationAccount.generation, forKey: "ottai_session_generation")
            XCTAssertTrue(OttaiRegistry.isCurrent(activationAccount, in: defaults))
            defaults.set("session-two", forKey: "ottai_session_generation")
            XCTAssertFalse(OttaiRegistry.isCurrent(activationAccount, in: defaults))
            let current = OttaiRegistry.accountContext(in: defaults)
            XCTAssertTrue(activationAttempt(sent: true).matches(sensorID: activationSensor,
                bluetoothID: activationBluetoothID, account: current))
        }
    }

    func testInvalidCheckpointIsNotPersisted() {
        withActivationDefaults { defaults in
            let invalid = [
                OttaiActivationAttempt(sensorID: "not-a-mac", bluetoothID: activationBluetoothID, apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: activationStart),
                OttaiActivationAttempt(sensorID: activationSensor, bluetoothID: "not-a-uuid", apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: activationStart),
                OttaiActivationAttempt(sensorID: activationSensor, bluetoothID: activationBluetoothID, apiBase: "", userID: activationAccount.userId, authorizedAtMs: activationStart),
                OttaiActivationAttempt(sensorID: activationSensor, bluetoothID: activationBluetoothID, apiBase: activationAccount.apiBase, userID: "", authorizedAtMs: activationStart),
                OttaiActivationAttempt(sensorID: activationSensor, bluetoothID: activationBluetoothID, apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: 0)
            ]
            for attempt in invalid {
                XCTAssertFalse(OttaiRegistry.saveActivationCheckpoint(attempt, in: defaults))
            }
            var negativeWrite = activationAttempt()
            negativeWrite.commandSentAtMs = -1
            XCTAssertFalse(OttaiRegistry.saveActivationCheckpoint(negativeWrite, in: defaults))
            XCTAssertFalse(OttaiRegistry.saveActivationCheckpoint(activationAttempt(confirmed: true), in: defaults))
            XCTAssertNil(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults))
        }
    }

    func testCorruptOrWrongSensorCheckpointCannotBeRestored() throws {
        try withActivationDefaults { defaults in
            let key = "ottai_activation_checkpoint_\(activationSensor)"
            defaults.set(Data("{corrupted".utf8), forKey: key)
            XCTAssertNil(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults))
            var wrongSensor = activationAttempt(sent: true)
            let encoded = try JSONEncoder().encode(wrongSensor)
            defaults.set(encoded, forKey: "ottai_activation_checkpoint_001122334455")
            XCTAssertNil(OttaiRegistry.loadActivationCheckpoint("001122334455", in: defaults))
            wrongSensor.confirmed = true
            defaults.set(try JSONEncoder().encode(wrongSensor), forKey: key)
            XCTAssertEqual(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults), wrongSensor)
        }
    }

    func testClearingOneCheckpointDoesNotDeleteAnotherSensorsRecovery() throws {
        try withActivationDefaults { defaults in
            let first = activationAttempt(sent: true)
            let second = OttaiActivationAttempt(sensorID: "001122334455", bluetoothID: activationBluetoothID,
                apiBase: activationAccount.apiBase, userID: activationAccount.userId, authorizedAtMs: activationStart)
            XCTAssertTrue(OttaiRegistry.saveActivationCheckpoint(first, in: defaults))
            XCTAssertTrue(OttaiRegistry.saveActivationCheckpoint(second, in: defaults))
            OttaiRegistry.clearActivationCheckpoint(activationSensor, in: defaults)
            XCTAssertNil(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults))
            XCTAssertEqual(try XCTUnwrap(OttaiRegistry.loadActivationCheckpoint(second.sensorID, in: defaults)), second)
        }
    }

    // MARK: - Warmup and required calculation materials

    func testWarmupSuppressesTenMinuteAndLastPreHourSamples() {
        XCTAssertEqual(OttaiConstants.defaultWarmupSeconds, 3600)
        XCTAssertTrue(OttaiConstants.isWithinWarmup(activationStartMs: activationStart, sampleMs: activationStart + 600_000))
        XCTAssertTrue(OttaiConstants.isWithinWarmup(activationStartMs: activationStart, sampleMs: activationStart + 3_599_999))
        XCTAssertFalse(OttaiConstants.isWithinWarmup(activationStartMs: activationStart, sampleMs: activationStart + 3_600_000))
    }

    func testCloudWarmupCannotShortenTheManufacturerHourButMayExtendIt() {
        XCTAssertTrue(OttaiConstants.isWithinWarmup(activationStartMs: activationStart,
            sampleMs: activationStart + 3_000_000, preheatPeriodMs: 600_000))
        XCTAssertTrue(OttaiConstants.isWithinWarmup(activationStartMs: activationStart,
            sampleMs: activationStart + 3_600_000, preheatPeriodMs: 5_400_000))
        XCTAssertFalse(OttaiConstants.isWithinWarmup(activationStartMs: activationStart,
            sampleMs: activationStart + 5_400_000, preheatPeriodMs: 5_400_000))
    }

    private func validCalculationMaterials() -> OttaiRegistry.DeviceMaterials {
        OttaiRegistry.DeviceMaterials(keyAHex: String(repeating: "AB", count: 96), method: "V1 C0 ml",
            coefficient: "1.0,2.0,3.0", activeTimeMs: 0)
    }

    func testUnstartedSensorCanHaveCompleteMaterialsWithoutInventingActivationTime() {
        let materials = validCalculationMaterials()
        XCTAssertTrue(OttaiCloudClient.materialsAreComplete(materials))
        XCTAssertEqual(materials.activeTimeMs, 0)
    }

    func testActivationRequiresValidAuthKeysAndAFormula() {
        var materials = validCalculationMaterials()
        materials.keyAHex = ""
        XCTAssertFalse(OttaiCloudClient.materialsAreComplete(materials))
        materials = validCalculationMaterials()
        materials.keyAHex = String(repeating: "G", count: 192)
        XCTAssertFalse(OttaiCloudClient.materialsAreComplete(materials))
        materials = validCalculationMaterials()
        materials.method = " \n "
        XCTAssertFalse(OttaiCloudClient.materialsAreComplete(materials))
    }

    func testMalformedNonFiniteOrMissingCoefficientsBlockActivation() {
        for coefficient in ["", "1,,2", "1,banana,2", "1,2,", "1,NaN,2", "1,inf,2"] {
            var materials = validCalculationMaterials()
            materials.coefficient = coefficient
            XCTAssertFalse(OttaiCloudClient.materialsAreComplete(materials), "Invalid coefficients must not prepare activation: \(coefficient)")
        }
    }

    func testFormulaCannotReferenceACoefficientMissingFromTheSensorMaterials() {
        var materials = validCalculationMaterials()
        materials.method = "V1 C13 ml"
        XCTAssertFalse(OttaiCloudClient.materialsAreComplete(materials))
    }

    func testNativeGlobalNeverGuessesChinaV3ValidationOnUpgradeFailure() {
        XCTAssertFalse(OttaiCloudClient.shouldTryValidateV3(apiBase: OttaiConstants.apiBaseGlobal,
            profile: .globalPhone, v2FailureCode: OttaiCloudClient.bizUpgradeVersion))
    }

    func testSentCheckpointRequiresTheOriginalBluetoothConnectionIdentity() {
        withActivationDefaults { defaults in
            var missingConnection = activationAttempt(sent: true)
            missingConnection.commandConnectionID = ""
            XCTAssertFalse(OttaiRegistry.saveActivationCheckpoint(missingConnection, in: defaults))
            missingConnection.commandConnectionID = "not-a-connection-uuid"
            XCTAssertFalse(OttaiRegistry.saveActivationCheckpoint(missingConnection, in: defaults))
            XCTAssertNil(OttaiRegistry.loadActivationCheckpoint(activationSensor, in: defaults))
        }
    }

    // MARK: - Official Global M8 read-only authInfo and legacy bind contracts

    private let globalOwner = "ottai-seas:a:g:ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    private let globalTimestamp: Int64 = 1_790_000_000_123

    func testGlobalAuthInfoRequestUsesReadOnlyM8ContractAndTheSameHeaderTimestamp() throws {
        let request = try XCTUnwrap(OttaiGlobalContract.authInfoRequest(mac: "aa:bb:cc:dd:ee:ff",
            deviceID: globalOwner, accessToken: "fixture-access-token", timestamp: globalTimestamp, deviceModel: "FixturePhone"))
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, "https://seas.ottai.com/cgm/app/server/device/authInfo")
        XCTAssertEqual(Set(request.query.keys), ["mac", "sign"])
        XCTAssertEqual(request.query["mac"], activationSensor)
        XCTAssertEqual(request.query["sign"], "ca49777236c23a9ad3bdc491a8e50d0d")
        XCTAssertNil(request.query["signature"])
        XCTAssertNil(request.body)
        XCTAssertEqual(request.headers["appName"], "ottai-seas")
        XCTAssertEqual(request.headers["packageName"], "com.ottai.seas")
        XCTAssertEqual(request.headers["applicationType"], "ottai_seas")
        XCTAssertEqual(request.headers["deviceId"], globalOwner)
        XCTAssertEqual(request.headers["timestamp"], String(globalTimestamp))
        XCTAssertEqual(request.headers["productModel"], "M8")
        XCTAssertEqual(request.headers["Authorization"], "fixture-access-token")
    }

    func testGlobalAuthInfoSignerMatchesAnIndependentDigestAndCanonicalMAC() {
        // Independent Python hashlib/OpenSSL-compatible MD5 fixture for the published SDK seed.
        XCTAssertEqual(OttaiCloudClient.globalAuthInfoSign(deviceID: globalOwner, timestampMillis: globalTimestamp,
            mac: activationSensor), "ca49777236c23a9ad3bdc491a8e50d0d")
        XCTAssertEqual(OttaiCloudClient.globalAuthInfoSign(deviceID: globalOwner, timestampMillis: globalTimestamp,
            mac: activationSensor.lowercased()), "ca49777236c23a9ad3bdc491a8e50d0d")
    }

    func testInvalidIdentityOrMissingSessionCannotCreateAnAuthInfoRequest() {
        XCTAssertNil(OttaiGlobalContract.authInfoRequest(mac: "not-a-mac", deviceID: globalOwner,
            accessToken: "fixture-token", timestamp: globalTimestamp, deviceModel: "FixturePhone"))
        XCTAssertNil(OttaiGlobalContract.authInfoRequest(mac: activationSensor, deviceID: "bare-device-id",
            accessToken: "fixture-token", timestamp: globalTimestamp, deviceModel: "FixturePhone"))
        XCTAssertNil(OttaiGlobalContract.authInfoRequest(mac: activationSensor, deviceID: globalOwner,
            accessToken: "", timestamp: globalTimestamp, deviceModel: "FixturePhone"))
    }

    private func globalValidationFixture() -> [String: Any] {
        ["data": [
            "cgmDeviceRespVO": ["mac": activationSensor, "keyA": "", "produceTime": 123,
                                "deviceVersion": "fixture-version", "activeTime": 0],
            "cgmDeviceMethodVO": ["method": "V1 C0 ml", "coefficient": "1.0,2.0,3.0",
                                  "methodUpdateTime": 456, "coeffUpdateTime": 789]
        ]]
    }

    func testAuthInfoMergePreservesV2CalculationDataAndUpdatesOnlyAuthMetadata() throws {
        let validation = globalValidationFixture()
        let auth: [String: Any] = ["data": ["mac": activationSensor, "keyA": "fixture-encrypted-key",
            "produceTime": 321, "preheatPeriodTime": 3_600_000,
            "method": "must-not-replace-method", "coefficient": "must-not-replace-coefficients"]]
        let merged = try XCTUnwrap(OttaiGlobalContract.mergeAuthInfo(validation: validation, authInfo: auth, mac: activationSensor))
        let data = try XCTUnwrap(merged["data"] as? [String: Any])
        let device = try XCTUnwrap(data["cgmDeviceRespVO"] as? [String: Any])
        let method = try XCTUnwrap(data["cgmDeviceMethodVO"] as? [String: Any])
        XCTAssertEqual(device["keyA"] as? String, "fixture-encrypted-key")
        XCTAssertEqual(device["produceTime"] as? Int, 321)
        XCTAssertEqual(device["preheatPeriodTime"] as? Int, 3_600_000)
        XCTAssertEqual(device["deviceVersion"] as? String, "fixture-version")
        XCTAssertEqual(device["activeTime"] as? Int, 0)
        XCTAssertEqual(method["method"] as? String, "V1 C0 ml")
        XCTAssertEqual(method["coefficient"] as? String, "1.0,2.0,3.0")
        XCTAssertEqual(method["methodUpdateTime"] as? Int, 456)
        XCTAssertEqual(method["coeffUpdateTime"] as? Int, 789)
        let originalData = try XCTUnwrap(validation["data"] as? [String: Any])
        XCTAssertEqual((originalData["cgmDeviceRespVO"] as? [String: Any])?["keyA"] as? String, "")
    }

    func testAuthInfoCannotMergeAnotherSensorOrAnEmptyKeyIntoTheNewSensor() {
        let validation = globalValidationFixture()
        for authData: [String: Any] in [
            ["mac": "001122334455", "keyA": "fixture-encrypted-key"],
            ["keyA": "fixture-encrypted-key"],
            ["mac": activationSensor, "keyA": ""],
            ["mac": activationSensor, "keyA": NSNull()],
            ["mac": activationSensor]
        ] {
            XCTAssertNil(OttaiGlobalContract.mergeAuthInfo(validation: validation,
                authInfo: ["data": authData], mac: activationSensor))
        }
        XCTAssertNil(OttaiGlobalContract.mergeAuthInfo(validation: validation,
            authInfo: ["data": ["mac": activationSensor, "keyA": "fixture-encrypted-key"]], mac: "001122334455"))
    }

    func testGlobalM8BindKeepsMillisecondsAndUsesItsOwnNewBindType() {
        let body = OttaiCloudClient.bindRequestBody(mac: activationSensor, deviceVersion: "fixture-version",
            userId: "fixture-user", activeTime: globalTimestamp, contract: .globalM8)
        XCTAssertEqual(body["newBindType"] as? Int, 1)
        XCTAssertEqual(body["activeTime"] as? Int64, globalTimestamp)
        XCTAssertEqual(body["deviceType"] as? String, "cgm")
        XCTAssertEqual(body["mac"] as? String, activationSensor)
        XCTAssertEqual(body["deviceVersion"] as? String, "fixture-version")
        XCTAssertEqual(body["userId"] as? String, "fixture-user")
    }

    // MARK: - Global M8 activation wire fixtures

    private let activationSessionKey = "000102030405060708090A0B0C0D0E0F"

    private func globalActivationMaterials(minor: Int = 7) -> OttaiRegistry.DeviceMaterials {
        var materials = validCalculationMaterials()
        materials.deviceVersion = "E1.2.7(V1.\(minor).SH2640.3)"
        materials.coefficient = (1...14).map(String.init).joined(separator: ",")
        materials.activeExpireTimeMs = 14 * 86_400_000
        materials.preheatPeriodMs = 3_600_000
        materials.gracePeriodMs = 14_400_000
        materials.calibrationValueK = 1.25
        materials.calibrationValueB = -2.5
        return materials
    }

    func testGlobalCoefficientFrameMatchesIndependentFloat32AndModbusCRCFixture() throws {
        let frame = try OttaiGlobalActivation.coefficientFrame((1...14).map(Double.init))
        // Python struct '<14f' + independent Modbus CRC fixture; no encryption.
        let expected = try OttaiCrypto.hexToBytesStrict("090e0000803f0000004000004040000080400000a0400000c0400000e0400000004100001041000020410000304100004041000050410000604185cb")
        XCTAssertEqual(frame, expected)
        XCTAssertEqual(frame.count, 60)
        XCTAssertEqual(Array(frame.suffix(2)), [0x85, 0xcb])
    }

    func testGlobalCoefficientFrameSupportsItsOneByteCountBoundaries() throws {
        let single = try OttaiGlobalActivation.coefficientFrame([1.0])
        XCTAssertEqual(Array(single.prefix(6)), [0x09, 0x01, 0x00, 0x00, 0x80, 0x3f])
        XCTAssertEqual(single.count, 8)
        let largest = try OttaiGlobalActivation.coefficientFrame([Double](repeating: 1.0, count: 255))
        XCTAssertEqual(Array(largest.prefix(2)), [0x09, 0xff])
        XCTAssertEqual(largest.count, 1_024)
        for values in [[Double](), [Double](repeating: 1.0, count: 256)] {
            XCTAssertThrowsError(try OttaiGlobalActivation.coefficientFrame(values)) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .coefficients)
            }
        }
    }

    func testGlobalCoefficientFrameRejectsNonFiniteAndFloat32OverflowValues() {
        for value in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try OttaiGlobalActivation.coefficientFrame([value])) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .coefficients)
            }
        }
    }

    func testGlobalFirmwareAllowsOneVerifiedMinorInVendorVersionWrappers() {
        for minor in 6...8 {
            XCTAssertEqual(OttaiGlobalActivation.firmwareMinor("V1.\(minor).SH2640.3"), minor)
            XCTAssertEqual(OttaiGlobalActivation.firmwareMinor("M8 E1.2.7(V1.\(minor).SH2640.3),STDRD"), minor)
        }
    }

    func testGlobalFirmwareRejectsUnknownAmbiguousOrNonCanonicalVersions() {
        for firmware in ["", "M8", "1.7.SH2640.3", "v1.7.SH2640.3", "V1.5.SH2500.1", "V1.9.SH2700.1",
                         "V1.07.SH2640.3", "V1.7", "V1.7.SH2640.3 V1.8.SH2700.1", "V1.7.SH2640.3 V1.7.SH2640.3"] {
            XCTAssertNil(OttaiGlobalActivation.firmwareMinor(firmware), firmware)
        }
    }

    func testGlobalSixAndSevenWriteCoefficientDurationZeroRTCThenActivation() throws {
        for minor in [6, 7] {
            let writes = try OttaiGlobalActivation.writes(materials: globalActivationMaterials(minor: minor), sessionKeyHex: activationSessionKey)
            XCTAssertEqual(writes.map(\.kind), [.coefficients, .duration, .rtc, .activate])
            XCTAssertEqual(writes.map(\.characteristic), [OttaiConstants.charDestructive, OttaiConstants.charMaxActiveTime,
                OttaiConstants.charCurrentTime, OttaiConstants.charCommand])
            XCTAssertEqual(writes[0].bytes.first, 0x09)
            XCTAssertEqual(writes[2].bytes, [0, 0, 0, 0])
        }
    }

    func testGlobalEightInsertsFactoryCalibrationBeforeDuration() throws {
        let writes = try OttaiGlobalActivation.writes(materials: globalActivationMaterials(minor: 8), sessionKeyHex: activationSessionKey)
        XCTAssertEqual(writes.map(\.kind), [.coefficients, .calibration, .duration, .rtc, .activate])
        XCTAssertEqual(writes[1].characteristic, OttaiConstants.charDestructive)
        XCTAssertEqual(writes[1].bytes.count, 17)
        XCTAssertEqual(writes[1].bytes.first, 0x0b)
        // OpenSSL AES-128-ECB fixture for Float64LE(1.25) || Float64LE(-2.5).
        XCTAssertEqual(Array(writes[1].bytes.dropFirst()), try OttaiCrypto.hexToBytesStrict("a516df6f00d956e999fe568cd86b08bc"))
        let decoded = try XCTUnwrap(OttaiCrypto.decryptPayload(Array(writes[1].bytes.dropFirst()), sessionKeyHex: activationSessionKey))
        XCTAssertEqual(decoded, try OttaiCrypto.hexToBytesStrict("000000000000f43f00000000000004c0"))
    }

    func testGlobalDurationIncludesLifetimeWarmupAndGraceAndMatchesAESFixture() throws {
        let materials = globalActivationMaterials()
        XCTAssertEqual(try OttaiGlobalActivation.totalDurationMs(materials), 1_227_600_000)
        let writes = try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey)
        let duration = try XCTUnwrap(writes.first { $0.kind == .duration })
        XCTAssertEqual(duration.bytes, try OttaiCrypto.hexToBytesStrict("8608f92cc7d690795ca608415d9e469c"))
        let decoded = try XCTUnwrap(OttaiCrypto.decryptPayload(duration.bytes, sessionKeyHex: activationSessionKey))
        XCTAssertEqual(Array(decoded.prefix(4)), [0x50, 0xbb, 0x12, 0x00])
        XCTAssertTrue(decoded.dropFirst(4).allSatisfy { $0 == 0 })
    }

    func testGlobalActivationUsesZeroPadded03AESAndIgnoresLegacyRetainTime() throws {
        var materials = globalActivationMaterials()
        let first = try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey)
        materials.retainTimeMs = Int64.max
        let withUnrelatedRetainTime = try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey)
        XCTAssertEqual(first, withUnrelatedRetainTime)
        let activate = try XCTUnwrap(first.last)
        XCTAssertEqual(activate.kind, .activate)
        XCTAssertEqual(activate.bytes, try OttaiCrypto.hexToBytesStrict("8cb899148f1fa8ff9132d0eb15a936f2"))
        let decoded = try XCTUnwrap(OttaiCrypto.decryptPayload(activate.bytes, sessionKeyHex: activationSessionKey))
        XCTAssertEqual(decoded.first, 0x03)
        XCTAssertTrue(decoded.dropFirst().allSatisfy { $0 == 0 })
    }

    func testGlobalEightRequiresBothFiniteFactoryCalibrationValues() {
        var cases: [OttaiRegistry.DeviceMaterials] = []
        var noK = globalActivationMaterials(minor: 8); noK.calibrationValueK = nil; cases.append(noK)
        var noB = globalActivationMaterials(minor: 8); noB.calibrationValueB = nil; cases.append(noB)
        var invalidK = globalActivationMaterials(minor: 8); invalidK.calibrationValueK = .nan; cases.append(invalidK)
        var invalidB = globalActivationMaterials(minor: 8); invalidB.calibrationValueB = .infinity; cases.append(invalidB)
        for materials in cases {
            XCTAssertThrowsError(try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey)) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .calibration)
            }
        }
    }

    func testGlobalOlderVerifiedFirmwareDoesNotRequireUnusedCalibrationValues() throws {
        var materials = globalActivationMaterials(minor: 7)
        materials.calibrationValueK = nil
        materials.calibrationValueB = nil
        XCTAssertEqual(try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey).map(\.kind),
            [.coefficients, .duration, .rtc, .activate])
    }

    func testGlobalPlanRejectsInvalidSessionKeysWithoutProducingWrites() {
        for key in ["", "not-hex", "AB"] {
            XCTAssertThrowsError(try OttaiGlobalActivation.writes(materials: globalActivationMaterials(), sessionKeyHex: key)) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .encryption)
            }
        }
    }

    func testGlobalDurationRejectsNegativeGraceFractionalSecondsAndOverflows() {
        var cases: [OttaiRegistry.DeviceMaterials] = []
        var negativeGrace = globalActivationMaterials(); negativeGrace.gracePeriodMs = -1; cases.append(negativeGrace)
        var fractional = globalActivationMaterials(); fractional.activeExpireTimeMs += 1; cases.append(fractional)
        var sumOverflow = globalActivationMaterials(); sumOverflow.activeExpireTimeMs = Int64.max; cases.append(sumOverflow)
        var wireOverflow = globalActivationMaterials(); wireOverflow.activeExpireTimeMs = (Int64(UInt32.max) + 1) * 1000; cases.append(wireOverflow)
        for materials in cases {
            XCTAssertThrowsError(try OttaiGlobalActivation.totalDurationMs(materials)) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .duration)
            }
        }
    }

    func testGlobalPlanStopsBeforeWritesForUnknownFirmware() {
        var materials = globalActivationMaterials()
        materials.deviceVersion = "unrecognized-new-revision"
        XCTAssertThrowsError(try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey)) {
            XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .firmware)
        }
    }

    // MARK: - Production read-only sensor preparation flow

    func testGlobalCheckedSensorPerformsTwoGETsAndNeverBindsOrActivates() throws {
        var requests: [OttaiGlobalContract.Request] = []
        var nextTimestamp = globalTimestamp
        let result = OttaiGlobalContract.checkedSensor(mac: activationSensor, deviceID: globalOwner,
            accessToken: "fixture-access-token", deviceModel: "FixturePhone", send: { request in
                requests.append(request)
                switch requests.count {
                case 1: return .init(body: self.globalValidationFixture(), failure: nil)
                case 2: return .init(body: ["data": ["mac": self.activationSensor, "keyA": "fixture-key", "produceTime": 321]], failure: nil)
                default: XCTFail("A read-only check must not issue extra requests"); return .init(body: nil, failure: .init(text: "unexpected request"))
                }
            }, clock: { defer { nextTimestamp += 1 }; return nextTimestamp })
        _ = try result.get()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests.map(\.url), ["https://seas.ottai.com/cgm/app/server/device/validateDeviceByMacV2",
            "https://seas.ottai.com/cgm/app/server/device/authInfo"])
        XCTAssertTrue(requests.allSatisfy { $0.body == nil })
        XCTAssertEqual(Set(requests[0].query.keys), ["mac", "signature"])
        XCTAssertEqual(Set(requests[1].query.keys), ["mac", "sign"])
        XCTAssertEqual(requests[0].headers["timestamp"], String(globalTimestamp))
        XCTAssertEqual(requests[1].headers["timestamp"], String(globalTimestamp + 1))
        XCTAssertTrue(requests.allSatisfy { $0.headers["Authorization"] == "fixture-access-token" })
        XCTAssertTrue(requests.allSatisfy { $0.headers["productModel"] == "M8" })
    }

    func testGlobalCheckedSensorStopsAtAValidationFailureWithoutRequestingKeys() {
        var requests: [OttaiGlobalContract.Request] = []
        let result = OttaiGlobalContract.checkedSensor(mac: activationSensor, deviceID: globalOwner,
            accessToken: "fixture-token", deviceModel: "FixturePhone", send: { request in
                requests.append(request)
                return .init(body: self.globalValidationFixture(), failure: .init(text: "fixture refusal", code: "AppDevice_Upgrade_Version", httpStatus: 200))
            })
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.method, "GET")
    }

    func testGlobalCheckedSensorDoesNotTryMutationFallbackAfterAuthInfoFailure() {
        var requests: [OttaiGlobalContract.Request] = []
        let result = OttaiGlobalContract.checkedSensor(mac: activationSensor, deviceID: globalOwner,
            accessToken: "fixture-token", deviceModel: "FixturePhone", send: { request in
                requests.append(request)
                return requests.count == 1
                    ? .init(body: self.globalValidationFixture(), failure: nil)
                    : .init(body: nil, failure: .init(text: "fixture expired session", code: "AuthFailed_TokenInvalid", httpStatus: 401))
            })
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
    }

    func testGlobalCheckedSensorRejectsCrossSensorAuthReplyWithoutAnyFollowupRequest() {
        var count = 0
        let result = OttaiGlobalContract.checkedSensor(mac: activationSensor, deviceID: globalOwner,
            accessToken: "fixture-token", deviceModel: "FixturePhone", send: { _ in
                count += 1
                return count == 1
                    ? .init(body: self.globalValidationFixture(), failure: nil)
                    : .init(body: ["data": ["mac": "001122334455", "keyA": "fixture-key"]], failure: nil)
            })
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(count, 2)
    }

    // MARK: - Global metadata defaults and cache preparation regressions

    func testGlobalDurationNeverSubstitutesChinaDefaultsForInvalidExplicitMetadata() {
        var missingExpiry = globalActivationMaterials(); missingExpiry.activeExpireTimeMs = 0
        var negativeExpiry = globalActivationMaterials(); negativeExpiry.activeExpireTimeMs = -1
        var negativePreheat = globalActivationMaterials(); negativePreheat.preheatPeriodMs = -1
        for materials in [missingExpiry, negativeExpiry, negativePreheat] {
            XCTAssertThrowsError(try OttaiGlobalActivation.totalDurationMs(materials)) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .duration)
            }
        }
    }

    func testGlobalZeroPreheatAndGraceRemainZeroInDurationInsteadOfAddingAnHour() throws {
        var materials = globalActivationMaterials()
        materials.preheatPeriodMs = 0
        materials.gracePeriodMs = 0
        XCTAssertEqual(try OttaiGlobalActivation.totalDurationMs(materials), 14 * 86_400_000)
    }

    func testAuthInfoMissingLifetimeMetadataUsesOfficialGlobalFourteenDayDefaults() throws {
        var validation = globalValidationFixture()
        var validationData = try XCTUnwrap(validation["data"] as? [String: Any])
        var validationVO = try XCTUnwrap(validationData["cgmDeviceRespVO"] as? [String: Any])
        validationVO["activeExpireTime"] = Int64(15 * 86_400_000)
        validationVO["preheatPeriodTime"] = Int64(3_600_000)
        validationVO["gracePeriodTime"] = Int64(14_400_000)
        validationData["cgmDeviceRespVO"] = validationVO
        validation["data"] = validationData
        let auth: [String: Any] = ["data": ["mac": activationSensor, "keyA": "fixture-key", "produceTime": 321]]
        let merged = try XCTUnwrap(OttaiGlobalContract.mergeAuthInfo(validation: validation, authInfo: auth, mac: activationSensor))
        let data = try XCTUnwrap(merged["data"] as? [String: Any])
        let device = try XCTUnwrap(data["cgmDeviceRespVO"] as? [String: Any])
        XCTAssertEqual((device["activeExpireTime"] as? NSNumber)?.int64Value, 14 * 86_400_000)
        XCTAssertEqual((device["preheatPeriodTime"] as? NSNumber)?.int64Value, 0)
        XCTAssertEqual((device["gracePeriodTime"] as? NSNumber)?.int64Value, 0)
    }

    func testAuthInfoExplicitZeroExpiryIsPreservedAndRejectedByTheActivationPlan() throws {
        let auth: [String: Any] = ["data": ["mac": activationSensor, "keyA": "fixture-key", "produceTime": 321,
            "activeExpireTime": 0, "preheatPeriodTime": 0, "gracePeriodTime": 0]]
        let merged = try XCTUnwrap(OttaiGlobalContract.mergeAuthInfo(validation: globalValidationFixture(), authInfo: auth, mac: activationSensor))
        let data = try XCTUnwrap(merged["data"] as? [String: Any])
        let device = try XCTUnwrap(data["cgmDeviceRespVO"] as? [String: Any])
        XCTAssertEqual((device["activeExpireTime"] as? NSNumber)?.int64Value, 0)
        var materials = globalActivationMaterials()
        materials.activeExpireTimeMs = try XCTUnwrap((device["activeExpireTime"] as? NSNumber)?.int64Value)
        XCTAssertThrowsError(try OttaiGlobalActivation.writes(materials: materials, sessionKeyHex: activationSessionKey)) {
            XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .duration)
        }
    }

    func testIncompleteNewGlobalEightCacheDoesNotPreventFetchingFactoryCalibrationAgain() {
        var materials = globalActivationMaterials(minor: 8)
        materials.calibrationValueK = nil
        materials.calibrationValueB = nil
        XCTAssertTrue(OttaiCloudClient.materialsAreComplete(materials))
        XCTAssertFalse(OttaiCloudClient.materialsReadyForSetup(materials,
            apiBase: OttaiConstants.apiBaseGlobal, profile: .globalPhone))
        materials.calibrationValueK = 1.25
        materials.calibrationValueB = -2.5
        XCTAssertTrue(OttaiCloudClient.materialsReadyForSetup(materials,
            apiBase: OttaiConstants.apiBaseGlobal, profile: .globalPhone))
    }

    func testRunningGlobalSensorAndOtherProfilesDoNotNeedNewSensorActivationPreflight() {
        var materials = validCalculationMaterials()
        materials.deviceVersion = "unknown-firmware"
        XCTAssertFalse(OttaiCloudClient.materialsReadyForSetup(materials,
            apiBase: OttaiConstants.apiBaseGlobal, profile: .globalPhone))
        XCTAssertTrue(OttaiCloudClient.materialsReadyForSetup(materials,
            apiBase: OttaiConstants.apiBaseGlobal, profile: .watch))
        XCTAssertTrue(OttaiCloudClient.materialsReadyForSetup(materials,
            apiBase: OttaiConstants.apiBase, profile: .cnPhone))
        materials.activeTimeMs = activationStart
        XCTAssertTrue(OttaiCloudClient.materialsReadyForSetup(materials,
            apiBase: OttaiConstants.apiBaseGlobal, profile: .globalPhone))
    }

    func testGlobalPreflightIndependentlyRejectsMalformedCloudCoefficientCSV() {
        for csv in ["1,,2", "1,bad,2", "1,2,", ",1,2"] {
            var materials = globalActivationMaterials()
            materials.coefficient = csv
            XCTAssertThrowsError(try OttaiGlobalActivation.preflight(materials: materials)) {
                XCTAssertEqual($0 as? OttaiGlobalActivation.Failure, .coefficients)
            }
        }
    }

    func testGlobalBindFirmwareKeepsTheFullLiveVersionWrapper() {
        XCTAssertEqual(OttaiGlobalActivation.bindFirmware("E1.2.7(V1.7.SH2640.3),STDRD"), "E1.2.7(V1.7.SH2640.3)")
        XCTAssertEqual(OttaiGlobalActivation.bindFirmware("E2.0.3(V1.8.SH2700.1),STDRD"), "E2.0.3(V1.8.SH2700.1)")
        XCTAssertNotEqual(OttaiGlobalActivation.bindFirmware("E1.2.7(V1.7.SH2640.3),STDRD"), "V1.7.SH2640.3")
    }

    func testGlobalBindFirmwareRemovesOnlySurroundingControlWhitespaceAndSuffix() {
        XCTAssertEqual(OttaiGlobalActivation.bindFirmware("\u{0000}\n\t E1.2.7(V1.6.SH2500.1) \r\t,STDRD\n"),
            "E1.2.7(V1.6.SH2500.1)")
        XCTAssertEqual(OttaiGlobalActivation.bindFirmware(" V1.7.SH2640.3 \t"), "V1.7.SH2640.3")
    }

    func testGlobalBindFirmwareRejectsUnknownOrAmbiguousFirstVersionField() {
        for raw in ["", " ,STDRD", "E1.2.7(unknown),STDRD", "E1.2.7(V1.9.SH2700.1),STDRD",
                    "E1.2.7(V1.7.SH2640.3 V1.8.SH2700.1),STDRD", ",E1.2.7(V1.7.SH2640.3)"] {
            XCTAssertNil(OttaiGlobalActivation.bindFirmware(raw), raw)
        }
    }
}


/// The test transport has no application command surface, matching the passive adapter.
private final class OttaiNFCWakeReaderSpy: OttaiNFCWakeReader {
    var begins = 0
    var invalidations = 0
    var onInvalidate: (() -> Void)?
    func begin() { begins += 1 }
    func invalidate() { invalidations += 1; onInvalidate?() }
}

final class OttaiUploadOutboxTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("sensor.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func sample(_ n: Int, mmol: Double = 5.5) -> OttaiCloudUploader.Sample {
        OttaiCloudUploader.Sample(dataNo: n, runtimeSec: n * 60, voltage: 123, rawCurrent: 4567,
                                  temperatureC: 31.25, mmol: mmol, sampleMs: 123456789,
                                  receivedAtMs: 123456999, originBytes: [0, 1, 128, 255], live: true)
    }

    func testRestartRestoresCompleteRawSample() throws {
        try OttaiUploadOutbox(url: file).enqueue(sample(7), account: "A", limit: 4000)
        let restored = try XCTUnwrap(OttaiUploadOutbox(url: file).pending(account: "A").first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(restored), try encoder.encode(sample(7)))
    }

    func testAcknowledgementSurvivesRestartAndDeduplicatesBackfill() throws {
        let store = try OttaiUploadOutbox(url: file)
        try store.enqueue(sample(7), account: "A", limit: 4000)
        try store.enqueue(sample(8), account: "A", limit: 4000)
        try store.acknowledge([sample(7)], account: "A")
        let restored = try OttaiUploadOutbox(url: file)
        try restored.enqueue(sample(7), account: "A", limit: 4000)
        XCTAssertEqual(restored.pending(account: "A").map(\.dataNo), [8])
    }

    func testUnacknowledgedBatchRemainsAfterRestart() throws {
        let store = try OttaiUploadOutbox(url: file)
        try store.enqueue(sample(7), account: "A", limit: 4000)
        _ = store.pending(account: "A") // Sending a batch does not remove it.
        XCTAssertEqual(try OttaiUploadOutbox(url: file).pending(account: "A").map(\.dataNo), [7])
    }

    func testAccountsStaySeparateIncludingTheirAcknowledgements() throws {
        let store = try OttaiUploadOutbox(url: file)
        try store.enqueue(sample(7), account: "A", limit: 4000)
        try store.enqueue(sample(7), account: "B", limit: 4000)
        try store.acknowledge([sample(7)], account: "A")
        let restored = try OttaiUploadOutbox(url: file)
        XCTAssertTrue(restored.pending(account: "A").isEmpty)
        XCTAssertEqual(restored.pending(account: "B").map(\.dataNo), [7])
    }

    func testUnownedReadingsAssignedOnlyOnce() throws {
        let store = try OttaiUploadOutbox(url: file)
        try store.enqueue(sample(7), account: "", limit: 4000)
        try store.assignUnownedSamples(to: "A", limit: 4000)
        try store.assignUnownedSamples(to: "B", limit: 4000)
        let restored = try OttaiUploadOutbox(url: file)
        XCTAssertEqual(restored.pending(account: "A").map(\.dataNo), [7])
        XCTAssertTrue(restored.pending(account: "B").isEmpty)
        XCTAssertTrue(restored.pending(account: "").isEmpty)
    }

    func testPendingReplacementAndCapacitySurviveRestart() throws {
        let store = try OttaiUploadOutbox(url: file)
        for n in 1...3 { try store.enqueue(sample(n), account: "A", limit: 2) }
        try store.enqueue(sample(3, mmol: 6.2), account: "A", limit: 2)
        let pending = try OttaiUploadOutbox(url: file).pending(account: "A")
        XCTAssertEqual(pending.map(\.dataNo), [2, 3])
        XCTAssertEqual(pending.last?.mmol, 6.2)
    }

    func testCorruptStoreIsNotSilentlyReplaced() throws {
        let corrupt = Data("invalid JSON".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try OttaiUploadOutbox(url: file))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testFailedWriteCanBeRetriedWithoutLosingSample() throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked) // Parent is a file, so creating a directory fails.
        let destination = blocked.appendingPathComponent("sensor.json")
        let store = try OttaiUploadOutbox(url: destination)
        XCTAssertThrowsError(try store.enqueue(sample(7), account: "A", limit: 4000))
        try FileManager.default.removeItem(at: blocked)
        try store.save()
        XCTAssertEqual(try OttaiUploadOutbox(url: destination).pending(account: "A").map(\.dataNo), [7])
    }
}

final class OttaiCloudOperationTests: XCTestCase {
    func testConcurrentOperationsKeepTheirOwnFailure() {
        let firstStarted = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let finished = expectation(description: "both operations finished")
        finished.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            let result = OttaiCloudClient.perform {
                OttaiCloudClient.lastFailure = .init(text: "activation refused", code: "activation")
                firstStarted.signal()
                XCTAssertEqual(secondFinished.wait(timeout: .now() + 3), .success)
                return false
            }
            XCTAssertEqual(result.failure?.code, "activation")
            finished.fulfill()
        }
        DispatchQueue.global().async {
            XCTAssertEqual(firstStarted.wait(timeout: .now() + 3), .success)
            let result = OttaiCloudClient.perform {
                OttaiCloudClient.lastFailure = .init(text: "upload failed", code: "upload")
                return false
            }
            XCTAssertEqual(result.failure?.code, "upload")
            secondFinished.signal()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    func testResultKeepsFailureAcrossQueueHandoff() {
        let finished = expectation(description: "result delivered")
        DispatchQueue.global().async {
            let result = OttaiCloudClient.perform {
                OttaiCloudClient.lastFailure = .init(text: "sign-in failed", code: "auth")
                return false
            }
            _ = OttaiCloudClient.perform { OttaiCloudClient.lastFailure = nil }
            DispatchQueue.main.async {
                XCTAssertEqual(result.errorText, "sign-in failed")
                XCTAssertEqual(result.failure?.code, "auth")
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 3)
    }

    func testNestedOperationsRestoreOuterFailureAndStartClean() {
        let outer = OttaiCloudClient.perform {
            OttaiCloudClient.lastFailure = .init(text: "outer", code: "outer")
            let inner = OttaiCloudClient.perform { true }
            XCTAssertNil(inner.failure)
            XCTAssertEqual(OttaiCloudClient.lastFailure?.code, "outer")
            return false
        }
        XCTAssertEqual(outer.failure?.code, "outer")
        XCTAssertNil(OttaiCloudClient.perform { true }.failure)
    }

    func testNewBoundIdIsSavedBeforeFirstUpload() {
        var materials = OttaiRegistry.DeviceMaterials()
        materials.deviceId = 10
        var saved: [Int] = []
        let ready = OttaiCloudUploader.refreshBoundDeviceId(&materials, lookup: {
            XCTAssertEqual(saved, [0])
            return .thisSensor(deviceId: 20)
        }, save: { saved.append($0) })
        XCTAssertTrue(ready)
        XCTAssertEqual(materials.deviceId, 20)
        XCTAssertEqual(saved, [0, 20])
        XCTAssertEqual(OttaiCloudUploader.uploadBody(batch: [], materials: materials)["deviceId"] as? Int, 20)
    }

    func testFailedOrUnconfirmedLookupCannotReuseOldId() {
        let replies: [OttaiCloudClient.BindState?] = [nil, .unbound, .other("other"), .thisSensor(deviceId: 0)]
        for reply in replies {
            var materials = OttaiRegistry.DeviceMaterials()
            materials.deviceId = 10
            var saved: [Int] = []
            XCTAssertFalse(OttaiCloudUploader.refreshBoundDeviceId(&materials, lookup: { reply }, save: { saved.append($0) }))
            XCTAssertEqual(materials.deviceId, 0)
            XCTAssertEqual(saved, [0])
        }
    }
}

final class OttaiRecordWidthBackportTests: XCTestCase {
    func testLowCurrentHistoryCannotPoisonLearnedWidth() {
        let page = OttaiCrypto.hexToBytes("00000000d7140000ce0344e0898a13660cc60344e0798b13740cae0344e0698c137e0c870344e0598d13890c870344e0498e13920c870344e0398f139b0c6f0344e0299013a30c770344e0199113ac0c7f0344e0099213b50c770344e0f99213bd0c770344e0e99313c80c6f0344e0d99413cd0c7f0344e0c99513d60c870344e0b99613d50c9f0344e0a99713c50cbe0344e0999813bd0cdd0344e0899913b50c00000000000000")
        XCTAssertNil(OttaiParser.contentRecordSize(page))
        XCTAssertEqual(OttaiParser.chooseRecordSize(page, deviceVersion: "", learned: 9), 9)
        XCTAssertEqual(OttaiParser.frameRecords(page, deviceVersion: "", learned: 9).count, 17)
    }
    func testVersionCannotForceWidthThatDoesNotFit() {
        let page: [UInt8] = Array(repeating: 0, count: 16)
        XCTAssertEqual(OttaiParser.chooseRecordSize(page, deviceVersion: "E1.2.3", learned: 9), 8)
        XCTAssertEqual(OttaiParser.frameRecords(page, deviceVersion: "E1.2.3", learned: 9).count, 1)
    }
}

final class OttaiTimeBackportTests: XCTestCase {
    func testCorrectionRequiresIndependentFramesAndStaysWithinOneMinute() {
        var correction = OttaiArrivalStartCorrection()
        correction.seed(start: 1_000_000, arrivalStart: 1_000_000)
        XCTAssertNil(correction.accept(anchor: 1_000_000, counter: 10, received: 1_585_000))
        XCTAssertNil(correction.accept(anchor: 1_000_000, counter: 10, received: 1_585_000))
        XCTAssertEqual(correction.accept(anchor: 1_000_000, counter: 11, received: 1_645_000), 985_000)
        correction.seed(start: 1_000_000, arrivalStart: 1_000_000)
        XCTAssertNil(correction.accept(anchor: 1_000_000, counter: 100, received: 1_585_000))
        XCTAssertNil(correction.accept(anchor: 1_000_000, counter: 101, received: 1_645_000))
    }
    func testHistorySeedCannotBeCorrectedFromArrivals() {
        var correction = OttaiArrivalStartCorrection()
        correction.seed(start: 1_000_000, arrivalStart: 0)
        XCTAssertNil(correction.accept(anchor: 1_000_000, counter: 10, received: 1_585_000))
        XCTAssertNil(correction.accept(anchor: 1_000_000, counter: 11, received: 1_645_000))
    }
}

final class OttaiLegacyRegionalTransportTests: XCTestCase {
    func testBothMobileTokenShapes() {
        XCTAssertEqual(OttaiCloudClient.mobileAccessToken(["accessToken":"legacy"]), "legacy")
        XCTAssertEqual(OttaiCloudClient.mobileAccessToken(["jwtToken":["accessToken":"secure"]]), "secure")
    }

    func testRegionsAndLegacyWatchIsolation() throws {
        let path = "/cgm/app/server/user/apiToken"
        XCTAssertNotNil(try OttaiRegionalTransport.route("https://seas.ottai.com" + path, headers: [:]))
        XCTAssertNil(try OttaiRegionalTransport.route("https://api.syai.com" + path, headers: [:]))
        XCTAssertNil(try OttaiRegionalTransport.route("https://api.ottai.com" + path, headers: ["appName":"watch"]))
        XCTAssertNotNil(try OttaiRegionalTransport.route("https://api.ottai.com" + path, headers: ["appName":"ottai", "packageName":"com.ottai.tag"]))
        XCTAssertThrowsError(try OttaiRegionalTransport.route("http://seas.ottai.com" + path, headers: [:]))
    }

    func testEncryptedExchangeRequestAndBusinessFailure() throws {
        let result = try encryptedRequest()
        XCTAssertEqual(result.json["code"] as? String, "DEVICE_AUTH_SIGN_ERROR")
    }

    func testChangedReplyCannotPassAuthentication() {
        XCTAssertThrowsError(try encryptedRequest(tamperReply: true))
    }

    func testInvalidExchangeStopsBeforeSendingBusinessRequest() throws {
        let route = try XCTUnwrap(try OttaiRegionalTransport.route("https://seas.ottai.com/cgm/app/server/test", headers: [:]))
        var calls = 0
        XCTAssertThrowsError(try OttaiRegionalTransport.request("GET", route: route, body: nil, headers: ["deviceId": "test"]) { _, _, _, _ in
            calls += 1
            return (200, ["data": ["serverSignature": "wrong"]])
        })
        XCTAssertEqual(calls, 1)
    }

    private func encryptedRequest(tamperReply: Bool = false) throws -> OttaiRegionalTransport.Reply {
        let identity = "test-install", secret = "test-secret"
        let route = try XCTUnwrap(try OttaiRegionalTransport.route("https://seas.ottai.com/cgm/app/server/test?q=a%2Bb", headers: [:]))
        var aes: SymmetricKey?
        var signing: SymmetricKey?
        var calls = 0
        let aad = Data((identity + "|" + secret).utf8)
        func seal(_ data: Data, key: SymmetricKey) throws -> AES.GCM.SealedBox { try AES.GCM.seal(data, using: key, authenticating: aad) }
        let result = try OttaiRegionalTransport.request("POST", route: route, body: "{\"test\":true}", headers: ["deviceId":identity]) { method, url, body, headers in
            calls += 1
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(body).utf8)) as? [String: Any])
            if calls == 1 {
                XCTAssertTrue(url.hasSuffix("/security/exchangeKey"))
                let client = try P256.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: obj["clientPubKeyX"] as! String)! + Data(base64Encoded: obj["clientPubKeyY"] as! String)!)
                let server = P256.KeyAgreement.PrivateKey()
                let shared = try server.sharedSecretFromKeyAgreement(with: client)
                let x = server.publicKey.rawRepresentation.prefix(32).base64EncodedString()
                let y = server.publicKey.rawRepresentation.suffix(32).base64EncodedString()
                let time = Int64(Date().timeIntervalSince1970 * 1000), expiry = time + 60_000
                let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: shared.withUnsafeBytes { Data($0) }), salt: Data(secret.utf8), info: Data("\(identity)#\(expiry)#\(secret)".utf8), outputByteCount: 64).withUnsafeBytes { Data($0) }
                aes = SymmetricKey(data: derived.prefix(32))
                signing = SymmetricKey(data: derived.suffix(32))
                let proof = try seal(Data((x+y).utf8), key: aes!)
                return (200,["code":"200", "data":["serverPubKeyX":x,"serverPubKeyY":y,"serverTimestamp":time,"serverSignature":SHA256.hash(data: Data((identity+x+y+String(time)).utf8)).map { String(format:"%02x",$0) }.joined(),"secretId":secret,"expireTime":expiry,"iv":Data(proof.nonce).base64EncodedString(),"authTag":proof.tag.base64EncodedString(),"ciphertext":proof.ciphertext.base64EncodedString()]])
            }
            XCTAssertEqual(headers["webDeviceId"],identity)
            XCTAssertEqual(headers["cipherSeq"],"1")
            XCTAssertTrue(url.contains("cipherParamText="))
            XCTAssertNil(obj["test"])
            let signed = try XCTUnwrap(headers["cipherNonceId"]) + "1" + XCTUnwrap(headers["cipherTimeNow"]) + XCTUnwrap(obj["cipherBodyText"] as? String)
            let signature = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(obj["cipherBodySignature"] as? String)))
            XCTAssertTrue(HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(signed.utf8), using: try XCTUnwrap(signing)))
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(base64Encoded: obj["cipherBodyNonce"] as! String)!), ciphertext: Data(base64Encoded: obj["cipherBodyText"] as! String)!, tag: Data(base64Encoded: obj["cipherBodyMac"] as! String)!)
            XCTAssertEqual(String(decoding: try AES.GCM.open(box, using: aes!, authenticating: aad), as: UTF8.self), "{\"test\":true}")
            let reply = try seal(Data("{\"code\":\"DEVICE_AUTH_SIGN_ERROR\"}".utf8), key: aes!)
            var ciphertext = reply.ciphertext
            if tamperReply { ciphertext[ciphertext.startIndex] ^= 1 }
            return (200,["cipherSecretId":secret,"cipherText":ciphertext.base64EncodedString(),"cipherMac":reply.tag.base64EncodedString(),"cipherNonce":Data(reply.nonce).base64EncodedString()])
        }
        XCTAssertEqual(calls,2)
        return result
    }
}

final class OttaiPreparationTests: XCTestCase {
    private typealias MaterialsResult = OttaiCloudClient.OperationResult<OttaiRegistry.DeviceMaterials?>

    private func materials(version: String = "V1.7") -> OttaiRegistry.DeviceMaterials {
        var materials = OttaiRegistry.DeviceMaterials()
        materials.keyAHex = String(repeating: "01", count: 96)
        materials.deviceVersion = version
        materials.activeTimeMs = 1_800_000_000_000
        return materials
    }

    func testLostBindAndFailedLookupDoNotAllowAnotherBind() {
        let result = OttaiCloudClient.recoverPreparation(version: "V1.7", bind: {
            MaterialsResult(value: nil, failure: .init(text: "connection lost"))
        }, lookup: {
            MaterialsResult(value: nil, failure: .init(text: "session expired", code: "TOKEN_EXPIRED"))
        })
        XCTAssertNil(result.operation.value)
        XCTAssertFalse(result.bindRejected)
    }

    func testLookupOnlyFailureCannotProveThatBindWasRefused() {
        let result = OttaiCloudClient.recoverPreparation(version: "V1.7", bind: nil, lookup: {
            MaterialsResult(value: nil, failure: .init(text: "session expired", code: "TOKEN_EXPIRED"))
        })
        XCTAssertFalse(result.bindRejected)
    }

    func testExplicitBindRefusalAllowsAnotherBind() {
        let result = OttaiCloudClient.recoverPreparation(version: "V1.7", bind: {
            MaterialsResult(value: nil, failure: .init(text: "bind refused", code: "DEVICE_ALREADY_USED"))
        }, lookup: {
            MaterialsResult(value: nil, failure: nil)
        })
        XCTAssertTrue(result.bindRejected)
        XCTAssertEqual(result.operation.failure?.code, "DEVICE_ALREADY_USED")
    }

    func testIncompleteBindFallsBackToMatchingSavedMaterials() {
        var lookups = 0
        let result = OttaiCloudClient.recoverPreparation(version: "V1.7", bind: {
            MaterialsResult(value: self.materials(version: "V1.6"), failure: nil)
        }, lookup: {
            lookups += 1
            return MaterialsResult(value: self.materials(), failure: nil)
        })
        XCTAssertEqual(lookups, 1)
        XCTAssertNotNil(result.operation.value?.authKeys)
        XCTAssertEqual(result.operation.value?.activeTimeMs, 0)
        XCTAssertNil(result.operation.failure)
    }

    func testMatchingBindDoesNotNeedAnotherRequest() {
        let result = OttaiCloudClient.recoverPreparation(version: "V1.7", bind: {
            MaterialsResult(value: self.materials(), failure: nil)
        }, lookup: {
            XCTFail("A valid bind must not trigger a lookup")
            return MaterialsResult(value: nil, failure: nil)
        })
        XCTAssertNotNil(result.operation.value)
        XCTAssertEqual(result.operation.value?.activeTimeMs, 0)
    }

    func testWrongVersionFromLookupDoesNotAllowPreparation() {
        let result = OttaiCloudClient.recoverPreparation(version: "V1.7", bind: nil, lookup: {
            MaterialsResult(value: self.materials(version: "V1.8"), failure: nil)
        })
        XCTAssertNil(result.operation.value)
        XCTAssertFalse(result.bindRejected)
    }

    func testSavedKeysDoNotErasePendingPreparationAndRemovalClearsIt() {
        let id = "0000000000AB"
        OttaiRegistry.removeSensor(id)
        defer { OttaiRegistry.removeSensor(id) }
        OttaiRegistry.savePreparation(id, version: "V1.8", address: "test-ble")
        var materials = OttaiRegistry.DeviceMaterials()
        materials.calibrationK = 1
        materials.calibrationB = -2
        XCTAssertTrue(OttaiRegistry.saveMaterials(sensorId: id, materials))
        XCTAssertEqual(OttaiRegistry.preparation(id)?.version, "V1.8")
        XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: id).calibrationB, -2)
        OttaiRegistry.removeSensor(id)
        XCTAssertNil(OttaiRegistry.preparation(id))
        XCTAssertNil(OttaiRegistry.loadMaterials(sensorId: id).calibrationK)
    }

    func testFactoryCoefficientVectorAndCRC() throws {
        let packets = try OttaiPreparation.packets(version: "E1.2.6(V1.7.SH2616.1),STDRD", coefficients: "1,2", k: nil, b: nil, session: "")
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(Array(packets[0].prefix(10)), [9,2,0,0,128,63,0,0,0,64])
        var crc = 0xffff
        for byte in packets[0] {
            for bit in 0..<8 {
                let low = (crc ^ (Int(byte) >> bit)) & 1
                crc >>= 1
                if low != 0 { crc ^= 0xa001 }
            }
        }
        XCTAssertEqual(crc, 0)
    }
    func testInvalidParametersFailBeforeAnyPacketIsReturned() {
        for coefficients in ["", "1,,2", "NaN", "Infinity"] {
            XCTAssertThrowsError(try OttaiPreparation.packets(version: "V1.7", coefficients: coefficients, k: nil, b: nil, session: ""))
        }
        XCTAssertThrowsError(try OttaiPreparation.packets(version: "V1.8", coefficients: "1,2", k: nil, b: nil, session: ""))
        XCTAssertThrowsError(try OttaiPreparation.packets(version: "unknown", coefficients: "1,2", k: nil, b: nil, session: ""))
    }
    func testCalibrationUsesLocalSession() throws {
        let key = "00112233445566778899aabbccddeeff"
        let packets = try OttaiPreparation.packets(version: "V1.8", coefficients: "1", k: 1, b: -2, session: key)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[1].first, 11)
        let plain = try XCTUnwrap(OttaiCrypto.aesECB(.decrypt, key: OttaiCrypto.hexToBytes(key), data: Array(packets[1].dropFirst()), pkcs7Padded: false))
        XCTAssertEqual(plain, [0,0,0,0,0,0,240,63,0,0,0,0,0,0,0,192])
    }
    func testVersionIdentityRejectsDifferentBuildOrVariant() {
        XCTAssertTrue(OttaiPreparation.versionMatches("E1.2.6(V1.7.SH2616.1),STDRD", "E1.2.6(V1.7.SH2616.1)"))
        XCTAssertTrue(OttaiPreparation.versionMatches("E1.2.6(V1.7.SH2616.1),STDRD", "V1.7.SH2616.1"))
        XCTAssertFalse(OttaiPreparation.versionMatches("E1.2.6(V1.7.SH2616.1),STDRD", "E1.2.6(V1.7.SH2616.1),OTHER"))
        XCTAssertFalse(OttaiPreparation.versionMatches("V1.7.SH2616.1", "V1.7.SH2616.2"))
    }
}

final class OttaiSetupSafetyTests: XCTestCase {
    func testFreshGlobalHasExplicitPreparationWithoutChangingFetch() {
        func offer(_ api: String = OttaiConstants.apiBaseGlobal, signedIn: Bool = true,
                   hasKeys: Bool = false, pending: Bool = false, step: OttaiSetupStep = .fetch) -> Bool {
            OttaiNewSensorPreparationPolicy.shouldOffer(apiBase: api, signedIn: signedIn,
                hasKeys: hasKeys, bootstrapPending: pending, step: step)
        }
        XCTAssertTrue(offer())
        XCTAssertFalse(offer(signedIn: false))
        XCTAssertFalse(offer(hasKeys: true))
        XCTAssertFalse(offer(pending: true))
        XCTAssertFalse(offer(OttaiConstants.apiBase))
        XCTAssertFalse(offer(OttaiConstants.apiBaseSyai))
        for step in [OttaiSetupStep.active, .ended, .starting] { XCTAssertFalse(offer(step: step)) }
    }

    private let id = "0000000000AC"
    private let now: Int64 = 1_800_000_000_000

    func testOttaiUsesItsOwnSetupInsteadOfGenericStartAndStopActions() {
        XCTAssertFalse(CGMTransmitterType.ottai.allowManualSensorStart())
        XCTAssertTrue(CGMTransmitterType.dexcom.allowManualSensorStart())
    }

    private func step(sensorID: String = "0000000000AC", signedIn: Bool = true, keys: Bool = true,
                      bootstrap: Bool = false, pendingBind: Bool = false, requested: Bool = false,
                      started: Bool = false, command: Int = -1, savedCommand: Int = -1,
                      startMs: Int64 = 0) -> OttaiSetupStep {
        OttaiSetupStep.resolve(sensorID: sensorID, signedIn: signedIn, hasKeys: keys,
            bootstrapPending: bootstrap, pendingBind: pendingBind, activationRequested: requested,
            activationStarted: started, commandStatus: command, savedCommandStatus: savedCommand,
            startMs: startMs, nowMs: now)
    }

    func testSetupOffersOnlyTheNextRequiredStep() {
        XCTAssertEqual(step(sensorID: "", signedIn: false, keys: false), .enterID)
        XCTAssertEqual(step(signedIn: false, keys: false), .signIn)
        XCTAssertEqual(step(keys: false), .fetch)
        XCTAssertEqual(step(keys: false, bootstrap: true), .activate)
        XCTAssertEqual(step(keys: true), .connect)
        XCTAssertEqual(step(command: 2), .activate)
    }

    func testStartingAndWarmupDoNotOfferAnotherAction() {
        XCTAssertEqual(step(requested: true, command: 2), .starting)
        XCTAssertFalse(step(requested: true, command: 2).hasAction)
        let warming = step(started: true, startMs: now - 5 * 60_000)
        XCTAssertEqual(warming, .warmup(minutes: 55))
        XCTAssertFalse(warming.hasAction)
        XCTAssertEqual(step(started: true, startMs: now - 60 * 60_000), .active)
    }

    func testActiveOrEndedSensorWinsOverOldActivationRequest() {
        XCTAssertEqual(step(requested: true, command: 3), .active)
        XCTAssertEqual(step(requested: true, command: 4), .ended)
        XCTAssertEqual(step(requested: true, savedCommand: 3), .active)
        XCTAssertEqual(step(requested: true, savedCommand: 4), .ended)
    }

    func testSavedKeysWorkWithoutCloudSignIn() {
        XCTAssertEqual(step(signedIn: false), .connect)
        XCTAssertEqual(step(signedIn: false, command: 3), .active)
        XCTAssertEqual(step(signedIn: false, command: 1), .activate)
    }

    func testPendingBindCannotRestartSensor() {
        XCTAssertEqual(step(keys: false, pendingBind: true, started: true), .finishingSetup)
        XCTAssertEqual(step(signedIn: false, keys: false, pendingBind: true, started: true), .signIn)
    }

    func testCloudStartDateAloneDoesNotBlockAConfirmedNewSensor() {
        XCTAssertEqual(step(command: 2, startMs: now - 60_000), .activate)
        XCTAssertEqual(step(startMs: now - 60_000), .connect)
    }

    func testActivationWritesRequireFreshUnstartedStatus() {
        for status in [-1, 0, 1, 2, 3, 4, 5] {
            XCTAssertFalse(ottaiCanWriteActivation(commandStatus: status, activationStarted: true))
            XCTAssertEqual(ottaiCanWriteActivation(commandStatus: status, activationStarted: false), (0...2).contains(status))
        }
    }

    func testStartedStateSurvivesMaterialsRefreshAndReconnect() {
        OttaiRegistry.removeSensor(id)
        defer { OttaiRegistry.removeSensor(id) }
        OttaiRegistry.setActivationAttempted(id, true)
        OttaiRegistry.markActivationStarted(id)
        XCTAssertFalse(OttaiRegistry.loadActivationAttempted(id))
        XCTAssertTrue(OttaiRegistry.saveMaterials(sensorId: id, OttaiRegistry.DeviceMaterials()))
        XCTAssertTrue(OttaiRegistry.activationStarted(id))
        XCTAssertFalse(ottaiCanWriteActivation(commandStatus: -1, activationStarted: OttaiRegistry.activationStarted(id)))
        OttaiRegistry.saveSensorStatus(id, 3)
        OttaiRegistry.saveSensorStatus(id, -1)
        OttaiRegistry.saveSensorStatus(id, 2)
        XCTAssertEqual(OttaiRegistry.sensorStatus(id), 3)
        OttaiRegistry.removeSensor(id)
        XCTAssertFalse(OttaiRegistry.activationStarted(id))
        XCTAssertEqual(OttaiRegistry.sensorStatus(id), -1)
    }
}
