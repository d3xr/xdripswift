import XCTest
import CoreData
@testable import xdrip

final class GlucoseAdjustmentTests: XCTestCase {
    func testOffsetWarningAndLimitBoundariesInBothDirections() {
        for sign in [-1.0, 1.0] {
            XCTAssertFalse(ConstantsBgAdjustment.offsetNeedsWarning(sign * 30))
            XCTAssertTrue(ConstantsBgAdjustment.offsetNeedsWarning(sign * 30.1))
            XCTAssertTrue(ConstantsBgAdjustment.isValidOffset(sign * 50))
            XCTAssertFalse(ConstantsBgAdjustment.isValidOffset(sign * 50.1))
        }
        XCTAssertFalse(ConstantsBgAdjustment.isValidOffset(.nan))
        XCTAssertFalse(ConstantsBgAdjustment.isValidOffset(.infinity))
        XCTAssertFalse(ConstantsBgAdjustment.isValidOffset(-.infinity))
    }

    func testOffsetLimitsUseMgDlAfterMmolConversion() {
        XCTAssertFalse(ConstantsBgAdjustment.offsetNeedsWarning(1.6.mmolToMgdl()))
        XCTAssertTrue(ConstantsBgAdjustment.offsetNeedsWarning(1.7.mmolToMgdl()))
        XCTAssertTrue(ConstantsBgAdjustment.isValidOffset(2.7.mmolToMgdl()))
        XCTAssertFalse(ConstantsBgAdjustment.isValidOffset(2.8.mmolToMgdl()))
    }

    func testCurveDefaultsToDisabledWithoutMigration() throws {
        let name = "GlucoseAdjustmentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.enableAdjustment = true
        XCTAssertTrue(defaults.enableGlucoseAdjustment)
        XCTAssertFalse(defaults.enableCurveAdjustment)
        XCTAssertNil(defaults.object(forKey: UserDefaults.Key.enableCurveAdjustment.rawValue))
    }

    @MainActor
    func testInvalidOffsetRejectsTheWholeApplyBeforeChangingState() throws {
        try withManager { manager, core, start in
            XCTAssertTrue(apply(manager, at: start, offset: 24))
            let originalID = manager.latestActiveBgAdjustment()?.id
            for offset in [50.1, -50.1, .nan, .infinity] {
                XCTAssertFalse(apply(manager, at: start, offset: offset, smoothing: true))
                XCTAssertEqual(manager.latestActiveBgAdjustment()?.id, originalID)
                XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 24)
                XCTAssertFalse(UserDefaults.standard.enableSmoothing)
                XCTAssertEqual(UserDefaults.standard.postProcessingApplyFromTimeStamp, start)
            }
            XCTAssertEqual(try core.mainManagedObjectContext.count(for: BgAdjustment.fetchRequest()), 1)
        }
    }

    @MainActor
    func testOffsetAndCurveCanBeAppliedIndependently() throws {
        try withManager { manager, _, start in
            XCTAssertTrue(apply(manager, at: start, offset: 80, slope: 1.2, glucose: false, curve: true))
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 0)
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.slope, 1.2)
            XCTAssertFalse(UserDefaults.standard.enableGlucoseAdjustment)
            XCTAssertTrue(UserDefaults.standard.enableCurveAdjustment)
            XCTAssertTrue(UserDefaults.standard.enableAdjustment)

            XCTAssertTrue(apply(manager, at: start, offset: -50, slope: 1.7))
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, -50)
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.slope, 1)
            XCTAssertTrue(UserDefaults.standard.enableGlucoseAdjustment)
            XCTAssertFalse(UserDefaults.standard.enableCurveAdjustment)

            XCTAssertTrue(apply(manager, at: start, offset: 50, slope: 1.2, curve: true))
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 50)
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.slope, 1.2)

            XCTAssertTrue(apply(manager, at: start, offset: 80, glucose: false, smoothing: true))
            XCTAssertFalse(UserDefaults.standard.enableAdjustment)
            XCTAssertFalse(UserDefaults.standard.enableCurveAdjustment)
            XCTAssertTrue(UserDefaults.standard.enableSmoothing)
        }
    }

    @MainActor
    func testRepeatedApplyDoesNotAccumulateOffsets() throws {
        try withManager { manager, core, start in
            // The accessor has an exclusive lower bound; measure after the session/apply start.
            let reading = BgReading(timeStamp: start.addingTimeInterval(15), sensor: SensorsAccessor(coreDataManager: core).fetchActiveSensor(), calibration: nil, rawData: 112, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = 112
            XCTAssertTrue(core.saveChangesSynchronously())
            for _ in 0..<2 {
                XCTAssertTrue(apply(manager, at: start, offset: 24))
                XCTAssertEqual(reading.calculatedValue, 112)
                XCTAssertEqual(reading.adjustedValue?.doubleValue, 136)
            }
        }
    }

    @MainActor
    func testLegacyOversizedOffsetIsNotSilentlyReplaced() throws {
        try withManager { manager, core, start in
            let defaults = UserDefaults.standard
            let identifier = try XCTUnwrap(defaults.postProcessingSourceContextIdentifier)
            let legacy = BgAdjustmentsAccessor(coreDataManager: core).createBgAdjustment(timeStamp: start, applyFromTimeStamp: start, slope: 1, intercept: 80, adjustmentShapeType: 1, isEnabled: true, isBasicAdjustment: false, enteredBgValue: nil, sourceCalculatedValue: nil, sourceDescription: nil, sourceContextIdentifier: identifier, on: core.mainManagedObjectContext)
            defaults.enableAdjustment = true
            XCTAssertTrue(core.saveChangesSynchronously())
            XCTAssertFalse(apply(manager, at: start, offset: 80))
            XCTAssertTrue(legacy.isEnabled)
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 80)
            XCTAssertTrue(apply(manager, at: start, offset: 50))
            XCTAssertFalse(legacy.isEnabled)
            XCTAssertEqual(manager.latestActiveBgAdjustment()?.intercept, 50)
        }
    }

    @MainActor
    func testFractionalApplyFromBoundaryIsInclusiveForLookupAndReplacement() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let accessor = BgAdjustmentsAccessor(coreDataManager: core)
        let context = core.mainManagedObjectContext
        // These Date reference timestamps round in opposite directions when converted
        // through Unix seconds. Exercise both inclusive predicates at the exact stored date.
        for (index, referenceSeconds) in [817_000_000.1234568, 817_000_000.1234571].enumerated() {
            let date = Date(timeIntervalSinceReferenceDate: referenceSeconds)
            let identifier = "fractional-boundary|\(index)"
            let adjustment = accessor.createBgAdjustment(timeStamp: date, applyFromTimeStamp: date, slope: 1.25, intercept: 24, adjustmentShapeType: BgAdjustmentShapeType.neutral.rawValue, isEnabled: true, isBasicAdjustment: false, enteredBgValue: nil, sourceCalculatedValue: nil, sourceDescription: nil, sourceContextIdentifier: identifier, on: context)
            XCTAssertTrue(core.saveChangesSynchronously())
            context.refreshAllObjects()
            XCTAssertEqual(adjustment.applyFromTimeStamp, date)

            // An enabled adjustment applies to a reading exactly at its lower boundary.
            XCTAssertEqual(accessor.latestApplicableBgAdjustment(forSourceContextIdentifier: identifier, readingTimeStamp: date, on: context)?.objectID, adjustment.objectID)

            // Replacing that same window must disable the old row, including equality.
            accessor.disableBgAdjustments(forSourceContextIdentifier: identifier, fromApplyFromTimeStamp: date, on: context)
            context.refreshAllObjects()
            XCTAssertFalse(adjustment.isEnabled)
            XCTAssertNil(accessor.latestActiveBgAdjustment(forSourceContextIdentifier: identifier, on: context))
        }
    }

    @MainActor
    func testCustomSourcesApplyOffsetAndCurveToStoredFinalValuesIndependently() throws {
        for transmitter in [CGMTransmitterType.ottai, .Aidex, .sibionicsCN] {
            try withManager(transmitter: transmitter) { manager, core, start in
                let defaults = UserDefaults.standard
                let sensor = try XCTUnwrap(manager.currentSensorForPostProcessing())
                let identifier = try XCTUnwrap(defaults.postProcessingSourceContextIdentifier)
                XCTAssertEqual(defaults.cgmTransmitterType, transmitter)
                XCTAssertTrue(manager.shouldAllowBgAdjustmentForCurrentSource())
                // Samples follow activation; fromDate intentionally excludes the start itself.
                let readings = [80.0, 100.0, 140.0].enumerated().map { index, value in
                    let reading = BgReading(timeStamp: start.addingTimeInterval(Double(index + 1) * 15), sensor: sensor, calibration: nil, rawData: value, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
                    reading.calculatedValue = value
                    return reading
                }
                XCTAssertTrue(core.saveChangesSynchronously())

                // Disabled controls must not contribute their entered values or validation.
                XCTAssertTrue(apply(manager, at: start, offset: 24, slope: .nan))
                XCTAssertEqual(readings.map(\.finalValue), [104, 124, 164])
                XCTAssertTrue(defaults.enableGlucoseAdjustment)
                XCTAssertFalse(defaults.enableCurveAdjustment)

                XCTAssertTrue(apply(manager, at: start, offset: 80, slope: 1.25, glucose: false, curve: true))
                XCTAssertEqual(readings.map(\.finalValue), [75, 100, 150])
                XCTAssertFalse(defaults.enableGlucoseAdjustment)
                XCTAssertTrue(defaults.enableCurveAdjustment)
                XCTAssertTrue(defaults.enableAdjustment)

                XCTAssertTrue(apply(manager, at: start, offset: 24, slope: 1.25, curve: true))
                XCTAssertEqual(readings.map(\.finalValue), [99, 124, 174])
                let adjustment = try XCTUnwrap(manager.latestActiveBgAdjustment())
                XCTAssertEqual(adjustment.sourceContextIdentifier, identifier)
                XCTAssertEqual(adjustment.intercept, 24)
                XCTAssertEqual(adjustment.slope, 1.25)
                XCTAssertTrue(core.saveChangesSynchronously())
                core.mainManagedObjectContext.refreshAllObjects()

                // A new manager must resolve the same persisted sensor and adjustment.
                let reloaded = BgPostProcessingManager(coreDataManager: core, nightscoutSyncManager: nil, healthKitManager: nil)
                reloaded.refreshSourceContext()
                XCTAssertEqual(reloaded.currentSensorForPostProcessing()?.objectID, sensor.objectID)
                XCTAssertEqual(reloaded.latestActiveBgAdjustment()?.id, adjustment.id)
                _ = reloaded.processLatestReadings(previousVisibleReadingTimeStamp: nil)
                XCTAssertEqual(readings.map(\.finalValue), [99, 124, 174])
                XCTAssertEqual(readings.map(\.loopShareValue), [99, 124, 174])
                XCTAssertEqual(readings.map(\.calculatedValue), [80, 100, 140])

                XCTAssertTrue(apply(reloaded, at: start, offset: .nan, slope: .nan, glucose: false))
                XCTAssertFalse(defaults.enableAdjustment)
                XCTAssertFalse(defaults.enableGlucoseAdjustment)
                XCTAssertFalse(defaults.enableCurveAdjustment)
                XCTAssertEqual(readings.map(\.finalValue), [80, 100, 140])
                XCTAssertTrue(readings.allSatisfy { $0.adjustedValue == nil && $0.smoothedValue == nil })
            }
        }
    }

    @MainActor
    func testCustomSourcesRejectInvalidApplyWithoutChangingStoredReadingsOrSettings() throws {
        for transmitter in [CGMTransmitterType.ottai, .Aidex, .sibionicsCN] {
            try withManager(transmitter: transmitter) { manager, core, start in
                let defaults = UserDefaults.standard
                let reading = BgReading(timeStamp: start.addingTimeInterval(15), sensor: manager.currentSensorForPostProcessing(), calibration: nil, rawData: 140, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
                reading.calculatedValue = 140
                XCTAssertTrue(core.saveChangesSynchronously())
                XCTAssertTrue(apply(manager, at: start, offset: 24, slope: 1.25, curve: true))
                let adjustment = try XCTUnwrap(manager.latestActiveBgAdjustment())
                let originalID = adjustment.id
                let keys: [UserDefaults.Key] = [.enableAdjustment, .enableGlucoseAdjustment, .enableCurveAdjustment,
                    .enableSmoothing, .useFiveMinuteReadings, .bgSmoothingPeriodInMinutes, .bgSmoothingStrength,
                    .bgSmoothingAlgorithm, .postProcessingApplyFromTimeStamp, .postProcessingStartTimeStamp,
                    .fiveMinuteReadingsStartTimeStamp, .postProcessingSourceContextIdentifier]
                func settings() -> NSDictionary {
                    NSDictionary(dictionary: Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                        defaults.object(forKey: key.rawValue).map { (key.rawValue, $0) }
                    }))
                }
                let originalSettings = settings()
                let originalNoteCount = try core.mainManagedObjectContext.count(for: TreatmentEntry.fetchRequest())
                let invalidValues: [(offset: Double, slope: Double)] = [
                    (50.1, 1.25), (-50.1, 1.25), (.nan, 1.25), (.infinity, 1.25), (-.infinity, 1.25),
                    (24, .nan), (24, .infinity), (24, 0.24), (24, 1.76)
                ]
                for values in invalidValues {
                    XCTAssertFalse(apply(manager, at: start.addingTimeInterval(30), offset: values.offset, slope: values.slope, curve: true, smoothing: true))
                    XCTAssertEqual(settings(), originalSettings)
                    XCTAssertEqual(manager.latestActiveBgAdjustment()?.id, originalID)
                    XCTAssertTrue(adjustment.isEnabled)
                    XCTAssertEqual(adjustment.intercept, 24)
                    XCTAssertEqual(adjustment.slope, 1.25)
                    XCTAssertEqual(reading.calculatedValue, 140)
                    XCTAssertEqual(reading.finalValue, 174)
                    XCTAssertEqual(reading.adjustedValue?.doubleValue, 174)
                    XCTAssertNil(reading.smoothedValue)
                    XCTAssertEqual(try core.mainManagedObjectContext.count(for: BgAdjustment.fetchRequest()), 1)
                    XCTAssertEqual(try core.mainManagedObjectContext.count(for: TreatmentEntry.fetchRequest()), originalNoteCount)
                }
                XCTAssertTrue(core.saveChangesSynchronously())
                core.mainManagedObjectContext.refreshAllObjects()
                XCTAssertEqual(reading.finalValue, 174)
                XCTAssertEqual(manager.latestActiveBgAdjustment()?.id, originalID)
            }
        }
    }

    @MainActor
    func testCustomSourceReplacementResetsBothAdjustmentControlsAndPreservesOldHistory() throws {
        for transmitter in [CGMTransmitterType.ottai, .Aidex, .sibionicsCN] {
            try withManager(transmitter: transmitter) { manager, core, start in
                let defaults = UserDefaults.standard
                let sensor = try XCTUnwrap(manager.currentSensorForPostProcessing())
                let oldReading = BgReading(timeStamp: start.addingTimeInterval(15), sensor: sensor, calibration: nil, rawData: 140, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
                oldReading.calculatedValue = 140
                XCTAssertTrue(core.saveChangesSynchronously())
                XCTAssertTrue(apply(manager, at: start, offset: 24, slope: 1.25, curve: true))
                let oldAdjustment = try XCTUnwrap(manager.latestActiveBgAdjustment())
                let oldIdentifier = try XCTUnwrap(defaults.postProcessingSourceContextIdentifier)
                let replacementStart = start.addingTimeInterval(30)
                sensor.endDate = replacementStart
                let replacement = Sensor(startDate: replacementStart, nsManagedObjectContext: core.mainManagedObjectContext)
                let newReading = BgReading(timeStamp: replacementStart.addingTimeInterval(15), sensor: replacement, calibration: nil, rawData: 140, deviceName: nil, nsManagedObjectContext: core.mainManagedObjectContext)
                newReading.calculatedValue = 140
                XCTAssertTrue(core.saveChangesSynchronously())

                manager.refreshSourceContext()
                XCTAssertEqual(manager.currentSensorForPostProcessing()?.objectID, replacement.objectID)
                XCTAssertNotEqual(defaults.postProcessingSourceContextIdentifier, oldIdentifier)
                XCTAssertFalse(defaults.enableAdjustment)
                XCTAssertFalse(defaults.enableGlucoseAdjustment)
                XCTAssertFalse(defaults.enableCurveAdjustment)
                XCTAssertNil(manager.latestActiveBgAdjustment())
                _ = manager.processLatestReadings(previousVisibleReadingTimeStamp: oldReading.timeStamp)
                XCTAssertEqual(newReading.finalValue, 140)
                XCTAssertNil(newReading.adjustedValue)
                XCTAssertEqual(oldReading.finalValue, 174)
                XCTAssertEqual(oldAdjustment.sourceContextIdentifier, oldIdentifier)
                XCTAssertTrue(oldAdjustment.isEnabled)
            }
        }
    }

    @MainActor
    private func apply(_ manager: BgPostProcessingManager, at start: Date, offset: Double, slope: Double = 1, glucose: Bool = true, curve: Bool = false, smoothing: Bool = false) -> Bool {
        manager.applyPostProcessing(enableGlucoseAdjustment: glucose, enableCurveAdjustment: curve, slope: slope, intercept: offset, adjustmentShapeType: .neutral, applyFromTimeStamp: start, isBasicAdjustment: false, enteredBgValue: nil, sourceCalculatedValue: nil, enableSmoothing: smoothing, useFiveMinuteReadings: false, smoothingPeriodInMinutes: ConstantsBgSmoothing.defaultSmoothingPeriodInMinutes, smoothingStrength: 1)
    }

    @MainActor
    private func withManager(transmitter: CGMTransmitterType = .dexcomG7, _ body: (BgPostProcessingManager, CoreDataManager, Date) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys: [UserDefaults.Key] = [.isMaster, .transmitterTypeAsString, .enableAdjustment,
            .enableGlucoseAdjustment, .enableCurveAdjustment, .enableSmoothing, .bgSmoothingStrength,
            .bgSmoothingAlgorithm, .bgSmoothingPeriodInMinutes, .useFiveMinuteReadings,
            .postProcessingSourceContextIdentifier, .activeSensorStartDate, .postProcessingApplyFromTimeStamp,
            .postProcessingStartTimeStamp, .fiveMinuteReadingsStartTimeStamp]
        let original = keys.map { ($0.rawValue, defaults.object(forKey: $0.rawValue)) }
        defer { for (key, value) in original { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0.rawValue) }
        defaults.isMaster = true
        defaults.cgmTransmitterTypeAsString = transmitter.rawValue
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        // Whole seconds survive the accessors' Date -> Unix seconds -> NSDate conversion
        // exactly, so equal apply-from dates select/replace the same adjustment deterministically.
        // Leave one minute for activation followed by the samples used by these tests.
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
        _ = Sensor(startDate: start, nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        let manager = BgPostProcessingManager(coreDataManager: core, nightscoutSyncManager: nil, healthKitManager: nil)
        manager.refreshSourceContext()
        try body(manager, core, start)
    }
}
