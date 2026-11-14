import CoreData
import CryptoKit
import Foundation
import XCTest
@testable import xdrip

final class CGMUpstreamMigrationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    private var modelBundle: Bundle { Bundle(for: Sensor.self) }

    private func modelDirectory() throws -> URL {
        try XCTUnwrap(modelBundle.url(forResource: "xdrip", withExtension: "momd"))
    }

    private func model(_ name: String) throws -> NSManagedObjectModel {
        try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory().appendingPathComponent(name + ".mom")), name)
    }

    private func currentModel() throws -> NSManagedObjectModel {
        try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory()))
    }

    private func fingerprint(_ model: NSManagedObjectModel) -> String {
        let hashes = model.entityVersionHashesByName
        let canonical = hashes.keys.sorted().map { name in
            name + "=" + hashes[name]!.map { String(format: "%02x", $0) }.joined()
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("TEST-migration.sqlite")
    }

    // Frozen from compiled .mom resources in the installed personal 4241 lineage,
    // not from a patient store. Renaming a model-version file must preserve these.
    func testPersonalModelAliasesPreserveInstalledLineageVersionHashes() throws {
        let fixtures = [
            (33, 25, "99ba096f90a4825db06f98fe287f1a01fc49322e8719d99470ec76bb373dc692"),
            (34, 26, "fee550115cd183ddbf1bcfc13f2eea20a467057aac13706d36da4d768f4a7ae0"),
            (35, 27, "4ec76320d893230c3b15863b021b72c8a3a800080ec4494b55f842b52018fca1")
        ]
        for (version, entityCount, hash) in fixtures {
            let source = try model("xdrip personal v\(version)")
            XCTAssertEqual(source.entities.count, entityCount)
            XCTAssertEqual(fingerprint(source), hash, "Personal v\(version) is no longer compatible with its installed schema")
        }
    }

    func testUnion38IsCurrentAndPreservesEveryUpstreamEntityExceptTheExtendedPeripheral() throws {
        let upstream = try model("xdrip v37")
        let destination = try model("xdrip v38")
        XCTAssertEqual(try currentModel().entityVersionHashesByName, destination.entityVersionHashesByName)
        XCTAssertEqual(Set(destination.entitiesByName.keys), Set(upstream.entitiesByName.keys).union(["Ottai", "Aidex", "SibionicsCN"]))
        XCTAssertEqual(destination.entities.count, 28)
        for (name, hash) in upstream.entityVersionHashesByName where name != "BLEPeripheral" {
            XCTAssertEqual(destination.entityVersionHashesByName[name], hash, "Upstream schema changed for \(name)")
        }
        let originalPeripheral = try XCTUnwrap(upstream.entitiesByName["BLEPeripheral"])
        let newPeripheral = try XCTUnwrap(destination.entitiesByName["BLEPeripheral"])
        for (name, property) in originalPeripheral.propertiesByName {
            XCTAssertEqual(newPeripheral.propertiesByName[name]?.versionHash, property.versionHash, name)
        }
        for (property, entity) in [("ottai", "Ottai"), ("aidex", "Aidex"), ("sibionicsCN", "SibionicsCN")] {
            let relationship = try XCTUnwrap(newPeripheral.relationshipsByName[property])
            XCTAssertTrue(relationship.isOptional)
            XCTAssertFalse(relationship.isToMany)
            XCTAssertEqual(relationship.destinationEntity?.name, entity)
            XCTAssertEqual(relationship.inverseRelationship?.name, "blePeripheral")
            XCTAssertEqual(relationship.deleteRule, .cascadeDeleteRule)
        }
        let authorization = try XCTUnwrap(destination.entitiesByName["SibionicsCN"]?.attributesByName["startAuthorized"])
        XCTAssertEqual((authorization.defaultValue as? NSNumber)?.boolValue, false)
    }

    @MainActor
    func testBothLineagesAreDiscoverableAndMappingsCanBeInferredWithoutCustomMappings() throws {
        for name in ["xdrip personal v35", "xdrip v37", "xdrip v33 Ottai"] {
            let source = try model(name), destination = try currentModel(), url = try temporaryStoreURL()
            let store = try Store(model: source, url: url)
            try store.close()
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
            let discovered = try XCTUnwrap(NSManagedObjectModel.mergedModel(from: [modelBundle], forStoreMetadata: metadata), name)
            XCTAssertEqual(discovered.entityVersionHashesByName, source.entityVersionHashesByName)
            XCTAssertTrue(discovered.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
            XCTAssertFalse(destination.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
            XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: discovered, destinationModel: destination))
        }
    }

    @MainActor
    func testDonorOttaiSQLiteMigratesPreservingReadingsAndDeviceRelationship() throws {
        let url = try temporaryStoreURL()
        let source = try Store(model: model("xdrip v33 Ottai"), url: url)
        _ = try seedCommon(source)
        try seedOttai(source)
        try source.context.save()
        try source.close()
        let migrated = try migratedStore(at: url)
        defer { try? migrated.close() }
        try assertCommon(migrated)
        try assertOttai(migrated)
        XCTAssertEqual(try migrated.count("Aidex"), 0)
        XCTAssertEqual(try migrated.count("SibionicsCN"), 0)
    }

    @MainActor
    func testPersonal35SQLiteMigratesTo38PreservingCGMsRelationshipsAndExistingAuthorization() throws {
        let url = try temporaryStoreURL()
        let source = try Store(model: model("xdrip personal v35"), url: url)
        _ = try seedCommon(source)
        try seedOttai(source)
        try seedAidex(source)
        for (code, authorized) in [("TESTGS1A", true), ("TESTGS1B", false)] {
            let sensor = try source.insert("SibionicsCN", date: date)
            sensor.setValue(code, forKey: "sensorCode")
            sensor.setValue("TEST-MAC-" + code, forKey: "declaredMAC")
            sensor.setValue(authorized, forKey: "startAuthorized")
            sensor.setValue(try peripheral(source, identity: code), forKey: "blePeripheral")
        }
        try source.context.save()
        try source.close()

        let migrated = try migratedStore(at: url)
        defer { try? migrated.close() }
        try assertCommon(migrated)
        try assertOttai(migrated)
        try assertAidex(migrated)
        for (code, authorized) in [("TESTGS1A", true), ("TESTGS1B", false)] {
            let sensor = try migrated.one("SibionicsCN", key: "sensorCode", value: code)
            XCTAssertEqual(sensor.value(forKey: "declaredMAC") as? String, "TEST-MAC-" + code)
            XCTAssertEqual((sensor.value(forKey: "startAuthorized") as? NSNumber)?.boolValue, authorized)
            let device = try XCTUnwrap(sensor.value(forKey: "blePeripheral") as? NSManagedObject)
            XCTAssertEqual(device.value(forKey: "address") as? String, "TEST-BLE-" + code)
            XCTAssertEqual((device.value(forKey: "sibionicsCN") as? NSManagedObject)?.objectID, sensor.objectID)
        }
        XCTAssertEqual(try migrated.count("Libre3"), 0)
        let reading = try migrated.one("BgReading", key: "id", value: "TEST-READING")
        XCTAssertEqual((reading.value(forKey: "valueIsFromWatch") as? NSNumber)?.boolValue, false)
        for property in ["phoneCollectedLive", "watchCollectedLive", "watchCollectedAt", "watchReceivedAt"] {
            XCTAssertNil(reading.value(forKey: property), property)
        }
        let alert = try migrated.one("AlertType", key: "name", value: "TEST-ALERT")
        XCTAssertEqual((alert.value(forKey: "repeatSound") as? NSNumber)?.boolValue, false)
        try assertNewGS1IsUnauthorized(migrated)
        try migrated.context.save()
        try migrated.close()
        try assertReopensWithoutMigration(at: url, expectedReadings: 1, expectedGS1: 3)
    }

    @MainActor
    func testUpstream37SQLiteMigratesTo38PreservingLibre3WatchProvenanceAndRepeatedAlerts() throws {
        let url = try temporaryStoreURL()
        let source = try Store(model: model("xdrip v37"), url: url)
        let common = try seedCommon(source)
        common.reading.setValue(true, forKey: "valueIsFromWatch")
        common.reading.setValue(false, forKey: "phoneCollectedLive")
        common.reading.setValue(true, forKey: "watchCollectedLive")
        common.reading.setValue(date.addingTimeInterval(3), forKey: "watchCollectedAt")
        common.reading.setValue(date.addingTimeInterval(8), forKey: "watchReceivedAt")
        common.alert.setValue(true, forKey: "repeatSound")
        for (identifier, phone, watch) in [("TEST-PHONE", true, false), ("TEST-UNKNOWN", false, false)] {
            let reading = try source.insert("BgReading", date: date)
            reading.setValue(identifier, forKey: "id")
            reading.setValue(111, forKey: "calculatedValue")
            reading.setValue(common.sensor, forKey: "sensor")
            if identifier == "TEST-PHONE" {
                reading.setValue(phone, forKey: "phoneCollectedLive")
                reading.setValue(watch, forKey: "watchCollectedLive")
            }
        }
        let libre = try source.insert("Libre3", date: date)
        libre.setValue("TEST-FIRMWARE", forKey: "firmware")
        libre.setValue("TEST-STATUS", forKey: "status")
        libre.setValue(30, forKey: "warmupMinutes")
        libre.setValue(14400, forKey: "wearMinutes")
        libre.setValue(date.addingTimeInterval(-3600), forKey: "startedAt")
        libre.setValue(try peripheral(source, identity: "LIBRE3"), forKey: "blePeripheral")
        try source.context.save()
        try source.close()

        let migrated = try migratedStore(at: url)
        defer { try? migrated.close() }
        try assertCommon(migrated)
        let reading = try migrated.one("BgReading", key: "id", value: "TEST-READING")
        XCTAssertEqual((reading.value(forKey: "valueIsFromWatch") as? NSNumber)?.boolValue, true)
        XCTAssertEqual((reading.value(forKey: "phoneCollectedLive") as? NSNumber)?.boolValue, false)
        XCTAssertEqual((reading.value(forKey: "watchCollectedLive") as? NSNumber)?.boolValue, true)
        XCTAssertEqual(reading.value(forKey: "watchCollectedAt") as? Date, date.addingTimeInterval(3))
        XCTAssertEqual(reading.value(forKey: "watchReceivedAt") as? Date, date.addingTimeInterval(8))
        let phone = try migrated.one("BgReading", key: "id", value: "TEST-PHONE")
        XCTAssertEqual((phone.value(forKey: "phoneCollectedLive") as? NSNumber)?.boolValue, true)
        XCTAssertEqual((phone.value(forKey: "watchCollectedLive") as? NSNumber)?.boolValue, false)
        let unknown = try migrated.one("BgReading", key: "id", value: "TEST-UNKNOWN")
        for property in ["phoneCollectedLive", "watchCollectedLive", "watchCollectedAt", "watchReceivedAt"] {
            XCTAssertNil(unknown.value(forKey: property), property)
        }
        let alert = try migrated.one("AlertType", key: "name", value: "TEST-ALERT")
        XCTAssertEqual((alert.value(forKey: "repeatSound") as? NSNumber)?.boolValue, true)
        let preservedLibre = try XCTUnwrap(migrated.objects("Libre3").first)
        XCTAssertEqual(preservedLibre.value(forKey: "firmware") as? String, "TEST-FIRMWARE")
        XCTAssertEqual(preservedLibre.value(forKey: "status") as? String, "TEST-STATUS")
        XCTAssertEqual((preservedLibre.value(forKey: "warmupMinutes") as? NSNumber)?.intValue, 30)
        XCTAssertEqual((preservedLibre.value(forKey: "wearMinutes") as? NSNumber)?.intValue, 14400)
        XCTAssertEqual(preservedLibre.value(forKey: "startedAt") as? Date, date.addingTimeInterval(-3600))
        let device = try XCTUnwrap(preservedLibre.value(forKey: "blePeripheral") as? NSManagedObject)
        XCTAssertEqual(device.value(forKey: "address") as? String, "TEST-BLE-LIBRE3")
        XCTAssertEqual((device.value(forKey: "libre3") as? NSManagedObject)?.objectID, preservedLibre.objectID)
        for entity in ["Ottai", "Aidex", "SibionicsCN"] { XCTAssertEqual(try migrated.count(entity), 0) }
        try assertNewGS1IsUnauthorized(migrated)
        try migrated.context.save()
        try migrated.close()
        try assertReopensWithoutMigration(at: url, expectedReadings: 3, expectedGS1: 1)
    }

    @MainActor
    func testEarlierPersonal33And34StoresAlsoMigrateDirectlyToUnion38() throws {
        for version in [33, 34] {
            let url = try temporaryStoreURL()
            let source = try Store(model: model("xdrip personal v\(version)"), url: url)
            _ = try seedCommon(source)
            try seedOttai(source)
            if version == 34 { try seedAidex(source) }
            try source.context.save()
            try source.close()
            let migrated = try migratedStore(at: url)
            defer { try? migrated.close() }
            try assertCommon(migrated)
            try assertOttai(migrated)
            if version == 34 { try assertAidex(migrated) }
            else { XCTAssertEqual(try migrated.count("Aidex"), 0) }
            XCTAssertEqual(try migrated.count("SibionicsCN"), 0)
            XCTAssertEqual(try migrated.count("Libre3"), 0)
            try assertNewGS1IsUnauthorized(migrated)
            try migrated.context.save()
        }
    }

    @MainActor
    private func migratedStore(at url: URL) throws -> Store {
        try Store(model: currentModel(), url: url, options: [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ])
    }

    @MainActor
    private func assertReopensWithoutMigration(at url: URL, expectedReadings: Int, expectedGS1: Int) throws {
        let model = try currentModel()
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url, options: nil)
        XCTAssertTrue(model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata))
        let reopened = try Store(model: model, url: url)
        defer { try? reopened.close() }
        try assertCommon(reopened)
        XCTAssertEqual(try reopened.count("BgReading"), expectedReadings)
        XCTAssertEqual(try reopened.count("SibionicsCN"), expectedGS1)
    }

    @MainActor
    private func seedCommon(_ store: Store) throws -> (sensor: NSManagedObject, reading: NSManagedObject, alert: NSManagedObject) {
        let sensor = try store.insert("Sensor", date: date)
        sensor.setValue("TEST-SENSOR", forKey: "id")
        sensor.setValue(date.addingTimeInterval(-7200), forKey: "startDate")
        let calibration = try store.insert("Calibration", date: date)
        calibration.setValue("TEST-CALIBRATION", forKey: "id")
        calibration.setValue(1.25, forKey: "slope")
        calibration.setValue(sensor, forKey: "sensor")
        let reading = try store.insert("BgReading", date: date)
        reading.setValue("TEST-READING", forKey: "id")
        reading.setValue(126, forKey: "calculatedValue")
        reading.setValue(120, forKey: "rawData")
        reading.setValue(sensor, forKey: "sensor")
        reading.setValue(calibration, forKey: "calibration")
        let alert = try store.insert("AlertType", date: date)
        alert.setValue("TEST-ALERT", forKey: "name")
        alert.setValue(true, forKey: "enabled")
        return (sensor, reading, alert)
    }

    @MainActor
    private func assertCommon(_ store: Store) throws {
        let reading = try store.one("BgReading", key: "id", value: "TEST-READING")
        XCTAssertEqual((reading.value(forKey: "calculatedValue") as? NSNumber)?.doubleValue, 126)
        XCTAssertEqual((reading.value(forKey: "rawData") as? NSNumber)?.doubleValue, 120)
        XCTAssertEqual(reading.value(forKey: "timeStamp") as? Date, date)
        let sensor = try XCTUnwrap(reading.value(forKey: "sensor") as? NSManagedObject)
        XCTAssertEqual(sensor.value(forKey: "id") as? String, "TEST-SENSOR")
        XCTAssertEqual(sensor.value(forKey: "startDate") as? Date, date.addingTimeInterval(-7200))
        let calibration = try XCTUnwrap(reading.value(forKey: "calibration") as? NSManagedObject)
        XCTAssertEqual(calibration.value(forKey: "id") as? String, "TEST-CALIBRATION")
        XCTAssertEqual((calibration.value(forKey: "slope") as? NSNumber)?.doubleValue, 1.25)
        XCTAssertEqual((calibration.value(forKey: "sensor") as? NSManagedObject)?.objectID, sensor.objectID)
        XCTAssertTrue((sensor.value(forKey: "readings") as? NSSet)?.contains(reading) == true)
        XCTAssertTrue((sensor.value(forKey: "calibrations") as? NSSet)?.contains(calibration) == true)
        let alert = try store.one("AlertType", key: "name", value: "TEST-ALERT")
        XCTAssertEqual((alert.value(forKey: "enabled") as? NSNumber)?.boolValue, true)
    }

    @MainActor
    private func peripheral(_ store: Store, identity: String) throws -> NSManagedObject {
        let device = try store.insert("BLEPeripheral", date: date)
        device.setValue("TEST-BLE-" + identity, forKey: "address")
        device.setValue("TEST DEVICE " + identity, forKey: "name")
        device.setValue(false, forKey: "shouldconnect")
        return device
    }

    @MainActor
    private func seedOttai(_ store: Store) throws {
        let device = try store.insert("Ottai", date: date)
        device.setValue("TEST-OTTAI-SENSOR", forKey: "ottaiSensorId")
        device.setValue(try peripheral(store, identity: "OTTAI"), forKey: "blePeripheral")
    }

    @MainActor
    private func assertOttai(_ store: Store) throws {
        let sensor = try store.one("Ottai", key: "ottaiSensorId", value: "TEST-OTTAI-SENSOR")
        let device = try XCTUnwrap(sensor.value(forKey: "blePeripheral") as? NSManagedObject)
        XCTAssertEqual(device.value(forKey: "address") as? String, "TEST-BLE-OTTAI")
        XCTAssertEqual((device.value(forKey: "shouldconnect") as? NSNumber)?.boolValue, false)
        XCTAssertEqual((device.value(forKey: "ottai") as? NSManagedObject)?.objectID, sensor.objectID)
    }

    @MainActor
    private func seedAidex(_ store: Store) throws {
        let sensor = try store.insert("Aidex", date: date)
        sensor.setValue("TEST-AIDEX", forKey: "peripheralIdentifier")
        sensor.setValue("TEST-FIRMWARE", forKey: "firmwareVersion")
        sensor.setValue("TEST-MODEL", forKey: "modelName")
        sensor.setValue(try peripheral(store, identity: "AIDEX"), forKey: "blePeripheral")
    }

    @MainActor
    private func assertAidex(_ store: Store) throws {
        let sensor = try store.one("Aidex", key: "peripheralIdentifier", value: "TEST-AIDEX")
        XCTAssertEqual(sensor.value(forKey: "firmwareVersion") as? String, "TEST-FIRMWARE")
        XCTAssertEqual(sensor.value(forKey: "modelName") as? String, "TEST-MODEL")
        let device = try XCTUnwrap(sensor.value(forKey: "blePeripheral") as? NSManagedObject)
        XCTAssertEqual(device.value(forKey: "address") as? String, "TEST-BLE-AIDEX")
        XCTAssertEqual((device.value(forKey: "aidex") as? NSManagedObject)?.objectID, sensor.objectID)
    }

    @MainActor
    private func assertNewGS1IsUnauthorized(_ store: Store) throws {
        let sensor = try store.insert("SibionicsCN", date: date)
        sensor.setValue("TEST-NEW", forKey: "sensorCode")
        XCTAssertEqual((sensor.value(forKey: "startAuthorized") as? NSNumber)?.boolValue, false)
    }

    @MainActor
    private final class Store {
        let coordinator: NSPersistentStoreCoordinator
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)

        init(model: NSManagedObjectModel, url: URL, options: [AnyHashable: Any]? = nil) throws {
            coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            context.persistentStoreCoordinator = coordinator
            _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options)
        }

        func insert(_ name: String, date: Date) throws -> NSManagedObject {
            let entity = try XCTUnwrap(coordinator.managedObjectModel.entitiesByName[name], name)
            let object = NSManagedObject(entity: entity, insertInto: context)
            for attribute in entity.attributesByName.values where !attribute.isOptional && attribute.defaultValue == nil {
                switch attribute.attributeType {
                case .stringAttributeType: object.setValue("TEST-REQUIRED-" + attribute.name, forKey: attribute.name)
                case .dateAttributeType: object.setValue(date, forKey: attribute.name)
                case .booleanAttributeType: object.setValue(false, forKey: attribute.name)
                case .doubleAttributeType, .floatAttributeType, .integer16AttributeType, .integer32AttributeType, .integer64AttributeType:
                    object.setValue(0, forKey: attribute.name)
                default:
                    throw NSError(domain: "CGMUpstreamMigrationTests", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unsupported required TEST fixture field \(name).\(attribute.name)"])
                }
            }
            return object
        }

        func objects(_ entity: String) throws -> [NSManagedObject] {
            try context.fetch(NSFetchRequest<NSManagedObject>(entityName: entity))
        }

        func one(_ entity: String, key: String, value: String) throws -> NSManagedObject {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.predicate = NSPredicate(format: "%K == %@", key, value)
            let values = try context.fetch(request)
            XCTAssertEqual(values.count, 1, "TEST identity must remain unique: \(entity).\(key)")
            return try XCTUnwrap(values.first)
        }

        func count(_ entity: String) throws -> Int {
            try context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: entity))
        }

        func close() throws {
            context.reset()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
    }
}
