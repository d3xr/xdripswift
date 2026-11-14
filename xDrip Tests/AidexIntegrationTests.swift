import XCTest
@testable import xdrip

final class AidexIntegrationTests: XCTestCase {
    func testTimestampAcceptanceNeverReplacesHistoryWithNow() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertFalse(AidexReadingPolicy.accepts(timestamp: now.addingTimeInterval(601), now: now))
        XCTAssertFalse(AidexReadingPolicy.accepts(timestamp: Date(timeIntervalSince1970: 0), now: now))
        let historical = now.addingTimeInterval(-3600)
        XCTAssertTrue(AidexReadingPolicy.accepts(timestamp: historical, now: now))
        XCTAssertEqual(historical.timeIntervalSince1970, 1_789_996_400)
    }

    func testUnknownSessionStartCannotGenerateFreshGlucoseTimestamp() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertNil(AidexReadingPolicy.timestamp(startTimeMs: 0, offsetMinutes: 2, now: now))
        XCTAssertNil(AidexReadingPolicy.timestamp(startTimeMs: 1_790_000_000_000, offsetMinutes: -1, now: now))
        XCTAssertNil(AidexReadingPolicy.timestamp(startTimeMs: 1_790_000_000_000, offsetMinutes: 11, now: now))
        XCTAssertEqual(AidexReadingPolicy.timestamp(startTimeMs: 1_789_999_000_000, offsetMinutes: 2, now: now), Date(timeIntervalSince1970: 1_789_999_120))
    }

    func testHeartbeatCannotPublishSensorNameAsBluetoothUUID() {
        XCTAssertNil(AidexReadingPolicy.heartbeatIdentifier("AiDEX123456"))
        XCTAssertNil(AidexReadingPolicy.heartbeatIdentifier(nil))
        let uuid = "E9F7A234-6366-4FB4-ACB8-DF3B092D6E72"
        XCTAssertEqual(AidexReadingPolicy.heartbeatIdentifier(uuid.lowercased()), uuid)
    }

    func testF003LengthsCRCScalingAndSentinel() throws {
        var payload = Data(repeating: 0, count: 15)
        payload[0] = 0xD2
        payload[1] = 120
        payload[6] = 200
        let valid = CRC16.append(payload)
        XCTAssertTrue(AidexParser.validateFrameCRC(valid))
        let parsed = try XCTUnwrap(AidexParser.parseDataFrame(valid))
        XCTAssertTrue(parsed.isValid)
        XCTAssertEqual(parsed.glucoseMgDl, 100)
        XCTAssertEqual(parsed.timeOffsetMinutes, 2)
        var corrupt = valid
        corrupt[6] ^= 1
        XCTAssertFalse(AidexParser.validateFrameCRC(corrupt))
        XCTAssertNil(AidexParser.parseDataFrame(Data(valid.prefix(16))))
        XCTAssertNil(AidexParser.parseDataFrame(valid + Data([0])))
        payload[6] = 0xFF
        payload[7] = 0x03
        XCTAssertFalse(try XCTUnwrap(AidexParser.parseDataFrame(CRC16.append(payload))).isValid)
    }

    func testRangeUsesScaledMgDlWhileSentinelUsesRawValue() throws {
        let cases: [(UInt8, Int, Float, Bool)] = [
            (0xD2, 40, 20, true), (0xD2, 39, 19.5, false),
            (0xD2, 600, 300, true), (0xD2, 1000, 500, true),
            (0xD2, 1001, 500.5, false), (0xD2, 1023, 511.5, false),
            (0xA1, 20, 20, true), (0xA1, 500, 500, true), (0xA1, 501, 501, false)
        ]
        for (opcode, raw, expected, valid) in cases {
            var payload = Data(repeating: 0, count: 15)
            payload[0] = opcode
            payload[6] = UInt8(raw & 0xFF)
            payload[7] = UInt8(raw >> 8)
            let frame = try XCTUnwrap(AidexParser.parseDataFrame(CRC16.append(payload)))
            XCTAssertEqual(frame.glucoseMgDl, expected, "opcode=\(opcode) raw=\(raw)")
            XCTAssertEqual(frame.isValid, valid, "opcode=\(opcode) raw=\(raw)")
        }
    }

    @MainActor
    func testWarmupIsOneHourFromExistingSessionStart() {
        XCTAssertEqual(ConstantsAidex.warmupMinutes, 60)
        XCTAssertEqual(AidexSensor.warmupDurationSeconds, 3600)
        XCTAssertEqual(AidexTimeout.warmupDurationSec, 3600)
        XCTAssertTrue(RootApplicationCoordinator.shouldSuppressReadingDuringWarmup(sensorAgeInSeconds: 3599, minimumWarmUpRequiredInMinutes: ConstantsAidex.warmupMinutes))
        XCTAssertFalse(RootApplicationCoordinator.shouldSuppressReadingDuringWarmup(sensorAgeInSeconds: 3600, minimumWarmUpRequiredInMinutes: ConstantsAidex.warmupMinutes))
        XCTAssertFalse(RootApplicationCoordinator.shouldSuppressReadingDuringWarmup(sensorAgeInSeconds: 86400, minimumWarmUpRequiredInMinutes: ConstantsAidex.warmupMinutes))
        for model in ["AiDex X", "LinX", "LumiFlex"] { XCTAssertTrue(ConstantsAidex.matchesModelDescription(model)) }
        XCTAssertFalse(ConstantsAidex.matchesModelDescription("Ottai/Syai"))
    }

    func testExistingTypesRemainRegisteredAlongsideAidex() {
        for type in [BluetoothPeripheralType.OttaiType, .AidexType, .DexcomType, .Libre2Type, .MedtrumTouchCareNanoType] {
            XCTAssertEqual(type.category(), .CGM)
        }
    }
}
