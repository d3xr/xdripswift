import XCTest
@testable import xdrip

final class OttaiGlobalLoginTests: XCTestCase {
    private let owner = "ottai-seas:a:g:ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    private let timestamp: Int64 = 1_760_000_000_123
    private let email = "fixture@example.invalid"
    private let password = "Only-for-public-fixture-123!"
    private typealias Reply = OttaiCloudClient.RequestResult
    private var candidate: OttaiCloudClient.LoginResult { .init(userId: "42", accessToken: "fixture-native-token", glucoseSecretKey: "fixture-root-key") }
    private var goodReplies: [Reply] { [
        .init(body: ["code": "OK", "data": "fixture-api-token"], failure: nil),
        .init(body: ["code": "OK", "data": ["userId": 42, "accessToken": "fixture-native-token", "glucoseSecretKey": "fixture-root-key"]], failure: nil),
        .init(body: ["code": "OK", "data": ["mac": "AABBCCDDEEFF"]], failure: nil),
        .init(body: ["code": "OK", "data": ["items": []]], failure: nil)
    ] }

    private func authenticate(_ replies: [Reply], observe: (OttaiGlobalContract.Request, Int) -> Void = { _, _ in }) -> Result<OttaiCloudClient.LoginResult, OttaiCloudClient.CloudFailure> {
        var index = 0
        return OttaiGlobalContract.authenticate(email: email, password: password, deviceID: owner, deviceModel: "Fixture device", send: { request in
            observe(request, index)
            guard index < replies.count else { XCTFail("Unexpected extra request"); return .init(body: nil, failure: .init(text: "Unexpected extra request")) }
            defer { index += 1 }
            return replies[index]
        }, clock: { self.timestamp })
    }

    private func defaults(_ work: (UserDefaults) throws -> Void) throws {
        let suite = "OttaiGlobalLoginTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(OttaiConstants.apiBaseGlobal, forKey: "ottai_api_base")
        try work(defaults)
    }

    func testOfficialURLDTOAndIndependentOpenSSLVector() throws {
        XCTAssertEqual(OttaiGlobalContract.loginURL, "https://seas.ottai.com/cgm/app/server/user/login/variousLogin")
        XCTAssertEqual(OttaiCloudClient.signForProfile(.globalPhone, deviceId: owner, ts: timestamp), "3272fb39aa3780046d9acbcd4cf85e8d")
        let signature = OttaiCloudClient.signForProfile(.globalPhone, deviceId: owner, ts: timestamp, "fixture-api-token", email, password)
        XCTAssertEqual(signature, "e33f72a1b8a45b827af4c52a81390c26")
        let body = try XCTUnwrap(OttaiGlobalContract.passwordBody(email: email, password: password, apiToken: "fixture-api-token", signature: signature))
        XCTAssertEqual(Set(body.keys), Set(["encryptInfo", "apiToken", "signature", "type", "phoneCode"]))
        XCTAssertEqual(body["type"] as? String, "2")
        XCTAssertEqual(body["phoneCode"] as? String, "")
        XCTAssertEqual(body["encryptInfo"] as? String, "Qpkz1BFBblAQvjg/STUUV30UgPhp91VauXazwylXdSndxJm8csX7pjdX1v/cnJemmbZX7bI/JWDPtIjrgnM6QVYrv1jQZ7l4KUNkDq8QQQsAQ8i+qeOR51dK0xtNpapV")
    }

    func testFullFlowUsesOneNativePasswordPostAndSameIdentityForValidation() throws {
        var calls: [OttaiGlobalContract.Request] = []
        let login = try authenticate(goodReplies) { request, _ in calls.append(request) }.get()
        XCTAssertEqual(login.userId, "42")
        XCTAssertEqual(calls.map(\.method), ["GET", "POST", "GET", "GET"])
        XCTAssertEqual(calls.map(\.url), [OttaiConstants.apiBaseGlobal + OttaiConstants.epApiToken, OttaiGlobalContract.loginURL,
            OttaiConstants.apiBaseGlobal + OttaiConstants.epGetBindDevice, OttaiConstants.apiBaseGlobal + OttaiConstants.epDeviceList])
        for (index, request) in calls.enumerated() {
            XCTAssertEqual(request.headers["deviceId"], owner)
            XCTAssertEqual(request.headers["appName"], "ottai-seas")
            XCTAssertEqual(request.headers["applicationType"], "ottai_seas")
            XCTAssertEqual(request.headers["packageName"], "com.ottai.seas")
            XCTAssertEqual(request.headers["Authorization"], index < 2 ? nil : "fixture-native-token")
            XCTAssertEqual(request.headers["timestamp"], String(timestamp))
        }
    }

    func testTokenHTTPFailureOrMalformedDataNeverSendsPassword() {
        for first in [Reply(body: ["data": "do-not-accept"], failure: .init(text: "failed", httpStatus: 500)),
                      Reply(body: ["data": ["apiToken": "unsupported"]], failure: nil), Reply(body: ["data": ""], failure: nil)] {
            var count = 0
            XCTAssertThrowsError(try authenticate([first]) { _, _ in count += 1 }.get())
            XCTAssertEqual(count, 1)
        }
    }

    func testPasswordFailureHasNoRetryAndNoFreeFormServerMessage() {
        var replies = goodReplies
        replies[1] = .init(body: ["data": ["accessToken": "must-not-use"]], failure: .init(text: "password=\(password) token=unsafe", code: "User_PasswordInvalid", httpStatus: 400, origin: "authenticated"))
        var count = 0
        XCTAssertThrowsError(try authenticate(replies) { _, _ in count += 1 }.get()) { error in
            let failure = error as? OttaiCloudClient.CloudFailure
            XCTAssertEqual(failure?.code, "User_PasswordInvalid")
            XCTAssertFalse(failure?.displayText.contains(self.password) ?? true)
            XCTAssertFalse(failure?.displayText.contains("unsafe") ?? true)
        }
        XCTAssertEqual(count, 2)
    }

    func testCompleteCandidateRequiresUserIDBeforeAnySensorRead() {
        var replies = goodReplies
        replies[1] = .init(body: ["data": ["accessToken": "token", "glucoseSecretKey": "root"]], failure: nil)
        var count = 0
        XCTAssertThrowsError(try authenticate(replies) { _, _ in count += 1 }.get())
        XCTAssertEqual(count, 2)
    }

    func testRejectedOrMalformedBindingCannotValidateCandidate() {
        for current in [Reply(body: ["data": ["mac": "AABBCCDDEEFF"]], failure: .init(text: "unauthorized", code: "AuthFailed_TokenInvalid", httpStatus: 401)),
                        Reply(body: ["data": ["unsupported": true]], failure: nil)] {
            var replies = goodReplies; replies[2] = current
            var count = 0
            XCTAssertThrowsError(try authenticate(replies) { _, _ in count += 1 }.get())
            XCTAssertEqual(count, 3)
        }
    }

    func testHistoryFailureOrMalformedHistoryCannotValidateCandidate() {
        for history in [Reply(body: ["data": ["items": []]], failure: .init(text: "unavailable", httpStatus: 500)),
                        Reply(body: ["data": ["notItems": []]], failure: nil),
                        Reply(body: ["data": ["items": [[:]]]], failure: nil)] {
            var replies = goodReplies; replies[3] = history
            XCTAssertThrowsError(try authenticate(replies).get())
        }
    }

    func testValidEmptyAccountStillAuthenticates() throws {
        var replies = goodReplies; replies[2] = .init(body: ["code": "OK", "data": NSNull()], failure: nil)
        XCTAssertTrue(try authenticate(replies).get().ok)
    }

    func testCandidateNotPersistedDuringAnyRequestAndCommitPreservesBLE() throws {
        try defaults { defaults in
            defaults.set("old-token", forKey: "ottai_access_token")
            defaults.set("old-root", forKey: "ottai_glucose_secret_key")
            defaults.set("old-user", forKey: "ottai_user_id")
            defaults.set("WATCH", forKey: "ottai_session_profile")
            defaults.set("old@example.invalid", forKey: "ottai_account_login")
            defaults.set("sensor-keys", forKey: "ottai_keya_AABBCCDDEEFF")
            defaults.set(123, forKey: "ottai_pending_bind_AABBCCDDEEFF")
            let context = try XCTUnwrap(OttaiRegistry.beginGlobalLogin(in: defaults))
            let candidate = try authenticate(goodReplies) { _, _ in
                XCTAssertEqual(defaults.string(forKey: "ottai_access_token"), "old-token")
                XCTAssertEqual(defaults.string(forKey: "ottai_glucose_secret_key"), "old-root")
                XCTAssertEqual(defaults.string(forKey: "ottai_account_login"), "old@example.invalid")
            }.get()
            XCTAssertTrue(OttaiRegistry.commitGlobalLogin(candidate, email: email, requested: context, in: defaults))
            XCTAssertEqual(defaults.string(forKey: "ottai_access_token"), "fixture-native-token")
            XCTAssertEqual(OttaiRegistry.loadSessionProfile(in: defaults), .globalPhone)
            XCTAssertEqual(defaults.string(forKey: "ottai_account_login"), email)
            XCTAssertEqual(defaults.string(forKey: "ottai_keya_AABBCCDDEEFF"), "sensor-keys")
            XCTAssertEqual(defaults.integer(forKey: "ottai_pending_bind_AABBCCDDEEFF"), 123)
            XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == password })
        }
    }

    func testFailedCandidateKeepsPriorAccountAndBLEState() throws {
        try defaults { defaults in
            defaults.set("old-token", forKey: "ottai_access_token")
            defaults.set("sensor-keys", forKey: "ottai_keya_AABBCCDDEEFF")
            _ = OttaiRegistry.beginGlobalLogin(in: defaults)
            var replies = goodReplies; replies[3] = .init(body: nil, failure: .init(text: "failed", httpStatus: 401))
            XCTAssertThrowsError(try authenticate(replies).get())
            XCTAssertEqual(defaults.string(forKey: "ottai_access_token"), "old-token")
            XCTAssertEqual(defaults.string(forKey: "ottai_keya_AABBCCDDEEFF"), "sensor-keys")
        }
    }

    func testStaleGenerationRegionAndAccountCannotCommit() throws {
        for change in ["generation", "region", "account", "user"] {
            try defaults { defaults in
                let context = try XCTUnwrap(OttaiRegistry.beginGlobalLogin(in: defaults))
                switch change {
                case "generation": _ = OttaiRegistry.beginGlobalLogin(in: defaults)
                case "region": defaults.set(OttaiConstants.apiBaseSyai, forKey: "ottai_api_base")
                case "account": defaults.set("other@example.invalid", forKey: "ottai_account_login")
                default: defaults.set("other-user", forKey: "ottai_user_id")
                }
                XCTAssertFalse(OttaiRegistry.commitGlobalLogin(candidate, email: email, requested: context, in: defaults))
                XCTAssertNil(defaults.string(forKey: "ottai_access_token"))
            }
        }
    }

    func testGlobalOwnerPersistsAcrossReloadAndSessionReset() throws {
        try defaults { defaults in
            let first = OttaiRegistry.loadOrCreateGlobalHeaderDeviceId(in: defaults)
            XCTAssertTrue(OttaiGlobalContract.validDeviceID(first))
            XCTAssertEqual(first, OttaiRegistry.loadOrCreateGlobalHeaderDeviceId(in: defaults))
            OttaiRegistry.clearAccountSession(in: defaults)
            XCTAssertEqual(first, OttaiRegistry.loadOrCreateGlobalHeaderDeviceId(in: defaults))
            XCTAssertFalse(first.contains("ottai-watch"))
        }
    }

    func testProfilesRemainRegionSpecificAndMissingProfileRemainsWatch() throws {
        try defaults { defaults in XCTAssertEqual(OttaiRegistry.loadSessionProfile(in: defaults), .watch) }
        XCTAssertEqual(OttaiCloudClient.activeProfile(OttaiConstants.apiBaseGlobal, stored: .watch), .watch)
        XCTAssertEqual(OttaiCloudClient.activeProfile(OttaiConstants.apiBaseGlobal, stored: .globalPhone), .globalPhone)
        XCTAssertEqual(OttaiCloudClient.activeProfile(OttaiConstants.apiBase, stored: .cnPhone), .cnPhone)
        XCTAssertEqual(OttaiCloudClient.activeProfile(OttaiConstants.apiBase, stored: .globalPhone), .watch)
        XCTAssertEqual(OttaiCloudClient.activeProfile(OttaiConstants.apiBaseSyai, stored: .globalPhone), .watch)
    }

    func testInvalidOwnerStopsBeforeNetwork() {
        let result = OttaiGlobalContract.authenticate(email: email, password: password, deviceID: "bare-uuid", deviceModel: "Fixture", send: { _ in
            XCTFail("Invalid identity must not send requests"); return .init(body: nil, failure: nil)
        })
        XCTAssertThrowsError(try result.get())
    }
}

// Synthetic encrypted cloud fixtures exercise the actual preparation API; no HTTP/BLE is used.
extension OttaiGlobalLoginTests {
    private var preparationMAC: String { "AABBCCDDEEFF" }
    private var preparationFirmware: String { "E1.2.6(V1.7.SH2616.1),STDRD" }
    private var preparationRoot: String { "0123456789ABCDEF" }

    private func withPreparationAccount(base: String = OttaiConstants.apiBaseGlobal,
                                        _ work: (OttaiAccountContext) throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("ottai_") }
        let previousFailure = OttaiCloudClient.lastFailure
        defer {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ottai_") { defaults.removeObject(forKey: key) }
            for (key, value) in previous { defaults.set(value, forKey: key) }
            OttaiCloudClient.lastFailure = previousFailure
        }
        for key in previous.keys { defaults.removeObject(forKey: key) }
        defaults.set(base, forKey: "ottai_api_base")
        defaults.set(base == OttaiConstants.apiBase ? "CN_PHONE" : "GLOBAL_PHONE", forKey: "ottai_session_profile")
        defaults.set("fixture-native-token", forKey: "ottai_access_token")
        defaults.set("42", forKey: "ottai_user_id")
        defaults.set(preparationRoot, forKey: "ottai_glucose_secret_key")
        defaults.set(UUID().uuidString, forKey: "ottai_session_generation")
        defaults.set(owner, forKey: "ottai_global_common_device_id")
        defaults.set("fixture-cn-installation", forKey: "ottai_cn_common_device_id")
        OttaiCloudClient.lastFailure = nil
        try work(OttaiRegistry.accountContext())
    }

    private func preparationResponse(mac: String? = nil, firmware: String? = nil, invalidKeys: Bool = false) throws -> Reply {
        let mac = mac ?? preparationMAC
        let fieldTime: Int64 = 1_760_000_000_000
        let key = OttaiCrypto.deriveFieldKey(glucoseSecretKey: preparationRoot, fieldTimestamp: fieldTime, mac: mac)
        func encrypted(_ plain: String) throws -> String { try XCTUnwrap(OttaiCrypto.encryptCloudField(plaintext: plain, fieldKey: key)) }
        return .init(body: ["code": "OK", "data": ["cgmDeviceRespVO": [
            "mac": mac, "deviceVersion": firmware ?? preparationFirmware,
            "keyA": try encrypted(invalidKeys ? "invalid" : String(repeating: "01", count: 96)),
            "produceTime": fieldTime, "activeTime": fieldTime, "activeExpireTime": Int64(14 * 86_400_000),
            "id": 123], "cgmDeviceMethodVO": ["method": try encrypted("C0"), "coefficient": try encrypted("1"),
                "methodUpdateTime": fieldTime, "coeffUpdateTime": fieldTime]]], failure: nil)
    }

    func testFreshPreparationBindsFullLiveRevisionWithSecondsAndKeepsSyntheticStartZero() throws {
        for base in [OttaiConstants.apiBaseGlobal, OttaiConstants.apiBase] {
            try withPreparationAccount(base: base) { context in
                let response = try preparationResponse()
                var calls: [OttaiGlobalContract.Request] = []
                let result = OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                    requestedContext: context, bindAlreadyAttempted: false, send: { request in
                        calls.append(request)
                        return calls.count == 1 ? .init(body: ["code": "OK", "data": NSNull()], failure: nil) : response
                    })
                XCTAssertEqual(calls.map(\.method), ["GET", "POST"])
                let bind = try XCTUnwrap(calls.last)
                XCTAssertEqual(bind.url, base + OttaiConstants.epBindV3)
                XCTAssertEqual(bind.body?["deviceVersion"] as? String, preparationFirmware)
                XCTAssertEqual(bind.body?["newBindType"] as? Int, 2)
                XCTAssertEqual(bind.body?["userId"] as? String, "42")
                XCTAssertEqual(bind.body?["deviceType"] as? String, "cgm")
                let seconds = try XCTUnwrap(bind.body?["activeTime"] as? Int64)
                XCTAssertLessThan(abs(seconds - Int64(Date().timeIntervalSince1970)), 5)
                XCTAssertEqual(bind.headers["Authorization"], "fixture-native-token")
                XCTAssertEqual(bind.headers["appName"], base == OttaiConstants.apiBase ? "ottai" : "ottai-seas")
                XCTAssertEqual(result?.activeTimeMs, 0)
                XCTAssertEqual(result?.coefficient, "1")
                XCTAssertNotNil(result?.authKeys)
                XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: preparationMAC).keyAHex, "", "The serial runtime owns material persistence")
            }
        }
    }

    func testPreparationLostBindReplyReconcilesWithOneReadAndNoRepeatedPost() throws {
        try withPreparationAccount { context in
            let response = try preparationResponse(firmware: "E1.2.6(V1.7.SH2616.1)")
            var methods: [String] = []
            let result = OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                requestedContext: context, bindAlreadyAttempted: false, send: { request in
                    methods.append(request.method)
                    switch methods.count {
                    case 1: return .init(body: ["data": NSNull()], failure: nil)
                    case 2: return .init(body: nil, failure: .init(text: "synthetic lost response"))
                    default: return response
                    }
                })
            XCTAssertEqual(methods, ["GET", "POST", "GET"])
            XCTAssertEqual(result?.activeTimeMs, 0)
        }
    }

    func testPreparationRecoveryNeverRepeatsAnUncertainBind() throws {
        try withPreparationAccount { context in
            for bound in [false, true] {
                var methods: [String] = []
                let response: Reply = bound ? try preparationResponse() : .init(body: ["data": NSNull()], failure: nil)
                let result = OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                    requestedContext: context, bindAlreadyAttempted: true, send: { request in methods.append(request.method); return response })
                XCTAssertEqual(methods, ["GET"])
                XCTAssertEqual(result != nil, bound)
            }
        }
    }

    func testPreparationRejectsAnotherSensorWrongBuildWrongVariantAndUndecryptableKeys() throws {
        try withPreparationAccount { context in
            for response in [try preparationResponse(mac: "112233445566"),
                             try preparationResponse(firmware: "E1.2.7(V1.7.SH2616.1),STDRD"),
                             try preparationResponse(firmware: "E1.2.6(V1.7.SH2616.1),OTHER"),
                             try preparationResponse(invalidKeys: true),
                             Reply(body: ["code": "OK"], failure: nil),
                             Reply(body: ["data": ["cgmDeviceRespVO": ["deviceId": 123]]], failure: nil),
                             Reply(body: ["data": ["unexpected": "nonempty"]], failure: nil)] {
                var methods: [String] = []
                XCTAssertNil(OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                    requestedContext: context, bindAlreadyAttempted: false, send: { request in methods.append(request.method); return response }))
                XCTAssertEqual(methods, ["GET"])
            }
        }
    }

    func testPreparationAccountChangeOrCancellationAfterGetPreventsBind() {
        for changeAccount in [false, true] {
            withPreparationAccount { context in
                var authorized = true, calls = 0
                let result = OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                    requestedContext: context, bindAlreadyAttempted: false, send: { _ in
                        calls += 1
                        if changeAccount { UserDefaults.standard.set(UUID().uuidString, forKey: "ottai_session_generation") }
                        else { authorized = false }
                        return .init(body: ["data": NSNull()], failure: nil)
                    }, stillAuthorized: { authorized })
                XCTAssertNil(result)
                XCTAssertEqual(calls, 1)
            }
        }
    }

    func testPreparationExpiredSessionAndMissingDecryptKeyStopWithoutFollowup() {
        withPreparationAccount { context in
            var calls = 0
            XCTAssertNil(OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                requestedContext: context, bindAlreadyAttempted: false, send: { _ in
                    calls += 1
                    return calls == 1 ? .init(body: ["data": NSNull()], failure: nil)
                        : .init(body: nil, failure: .init(text: "expired", code: "AuthFailed_TokenInvalid", httpStatus: 401))
                }))
            XCTAssertEqual(calls, 2)
            UserDefaults.standard.removeObject(forKey: "ottai_glucose_secret_key")
            XCTAssertNil(OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                requestedContext: context, bindAlreadyAttempted: false, send: { _ in
                    XCTFail("Missing local decryption key must not bind"); return .init(body: nil, failure: nil)
                }))
        }
    }

    func testExplicitBootstrapCheckUsesOneReadOnlyV3ValidationAndPreservesNativeIdentity() {
        withPreparationAccount { context in
            var calls: [OttaiGlobalContract.Request] = []
            XCTAssertTrue(OttaiCloudClient.checkActivationBootstrap(mac: preparationMAC, requestedContext: context, send: { request in
                calls.append(request)
                return .init(body: ["data": ["mac": self.preparationMAC, "deviceVersion": self.preparationFirmware]], failure: nil)
            }))
            XCTAssertEqual(calls.map(\.url), [OttaiConstants.apiBaseGlobal + OttaiConstants.epValidateByMacV3])
            XCTAssertEqual(calls.first?.headers["deviceId"], owner)
            XCTAssertEqual(calls.first?.headers["appName"], "ottai-seas")
            XCTAssertTrue(OttaiRegistry.isV3CredentialBootstrapPending(preparationMAC))
            XCTAssertEqual(OttaiRegistry.loadLastValidatedDeviceVersion(sensorId: preparationMAC), preparationFirmware)
            XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: preparationMAC).keyAHex, "")
        }
    }

    func testFreshFirmwareMatchingKeepsBuildAndNamedVariantsDistinct() {
        XCTAssertEqual(OttaiGlobalContract.preparationBindVersion(preparationFirmware + "\0stale"), preparationFirmware)
        XCTAssertTrue(OttaiGlobalContract.preparationVersionMatches(sensor: preparationFirmware, cloud: "E1.2.6(V1.7.SH2616.1)"))
        XCTAssertTrue(OttaiGlobalContract.preparationVersionMatches(sensor: preparationFirmware, cloud: "V1.7.SH2616.1"))
        for other in ["E1.2.7(V1.7.SH2616.1)", "E1.2.6(V1.7.SH2616.2)", "E1.2.6(V1.7.SH2616.1),OTHER", "V1.8", "garbage"] {
            XCTAssertFalse(OttaiGlobalContract.preparationVersionMatches(sensor: preparationFirmware, cloud: other))
        }
    }
}

extension OttaiGlobalLoginTests {
    func testPreparationRequestsKeepOneCapturedWireIdentityAcrossTokenRefresh() throws {
        try withPreparationAccount { context in
            let response = try preparationResponse()
            var calls: [OttaiGlobalContract.Request] = []
            let result = OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                requestedContext: context, bindAlreadyAttempted: false, send: { request in
                    calls.append(request)
                    if calls.count == 1 {
                        OttaiRegistry.saveAccessToken("replacement-token")
                        return .init(body: ["data": NSNull()], failure: nil)
                    }
                    return response
                })
            XCTAssertNotNil(result)
            XCTAssertEqual(calls.count, 2)
            XCTAssertTrue(calls.allSatisfy { $0.headers["Authorization"] == "fixture-native-token" })
            XCTAssertTrue(calls.allSatisfy { $0.headers["deviceId"] == self.owner })
        }
    }
}

extension OttaiGlobalLoginTests {
    func testPreparationRecordsBindIntentOnlyAtTheActualPostAndStopsOnSaveFailure() {
        for getFails in [false, true] {
            withPreparationAccount { context in
                var calls = 0, marks = 0
                XCTAssertNil(OttaiCloudClient.prepareActivationMaterials(mac: preparationMAC, liveFirmware: preparationFirmware,
                    requestedContext: context, bindAlreadyAttempted: false, send: { _ in
                        calls += 1
                        return getFails ? .init(body: nil, failure: .init(text: "synthetic GET failure"))
                            : .init(body: ["data": NSNull()], failure: nil)
                    }, willBind: { marks += 1; return false }))
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(marks, getFails ? 0 : 1)
            }
        }
    }
}

extension OttaiGlobalLoginTests {
    func testFreshRevisionParserRequiresCompletePrintableVendorGrammar() {
        for value in ["E1.2.6(V1.7.SH2616.1),STDRD", "vE1.2.3(V1.7.SH2542.1)", "V1.7.0", "v1.7.SH2616.1", "1.7.0"] {
            XCTAssertEqual(OttaiGlobalContract.preparationBindVersion(value), value)
        }
        XCTAssertTrue(OttaiGlobalContract.preparationVersionMatches(sensor: preparationFirmware, cloud: "V1.7"))
        XCTAssertTrue(OttaiGlobalContract.preparationVersionMatches(sensor: "V01.007.0", cloud: "v1.7"))
        for malformed in ["junk E1.2.6(V1.7.SH2616.1),STDRD", "junk(V1.7.0)", "V1.7.0 V1.8.0",
                          "E1.2.6(V1.7.0)(V1.8.0)", "V1.7.0\n", "\nV1.7.0", "V1.7.0\t", "V1.7.é",
                          "E1.2.6(V1.7.SH2616.1),STDRD,V1.8", String(repeating: "x", count: 513), ""] {
            XCTAssertNil(OttaiGlobalContract.preparationBindVersion(malformed))
            XCTAssertFalse(OttaiGlobalContract.preparationVersionMatches(sensor: malformed, cloud: malformed))
        }
    }

    func testUnfinishedPreparationBlocksCloudFetchWithoutAdoptingBindTimestamp() {
        withPreparationAccount { context in
            let checkpoint = OttaiPreparationCheckpoint(sensorID: preparationMAC, bluetoothID: UUID().uuidString,
                apiBase: context.apiBase, userID: context.userId, authorizedAtMs: timestamp,
                liveFirmware: preparationFirmware, bindAttempted: true, materialsSaved: true, factoryComplete: true)
            XCTAssertTrue(OttaiRegistry.savePreparationCheckpoint(checkpoint))
            if case .failed = OttaiCloudClient.fetchAndSaveMaterials(cloudId: preparationMAC, requestedContext: context) {} else {
                XCTFail("An unfinished physical activation must not consume a synthetic cloud bind timestamp")
            }
            XCTAssertEqual(OttaiRegistry.loadMaterials(sensorId: preparationMAC).activeTimeMs, 0)
            XCTAssertNotNil(OttaiRegistry.loadPreparationCheckpoint(preparationMAC))
        }
    }
}
