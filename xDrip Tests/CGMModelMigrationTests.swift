import CoreData
import XCTest
@testable import xdrip

final class CGMModelMigrationTests: XCTestCase {
    func testV33StoreMigratesToV34PreservingOttaiAndGlucose() throws {
        let bundle = Bundle(for: Ottai.self)
        let modelDirectory = try XCTUnwrap(bundle.url(forResource: "xdrip", withExtension: "momd"))
        let old = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("xdrip personal v33.mom")))
        let new = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("xdrip personal v34.mom")))
        XCTAssertNil(old.entitiesByName["Aidex"])
        XCTAssertNotNil(new.entitiesByName["Aidex"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("migration.sqlite")
        let first = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try first.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = first
        func insert(_ name: String) -> NSManagedObject {
            let entity = old.entitiesByName[name]!
            let object = NSManagedObject(entity: entity, insertInto: context)
            for attribute in entity.attributesByName.values where !attribute.isOptional && attribute.defaultValue == nil {
                switch attribute.attributeType {
                case .stringAttributeType: object.setValue("fixture", forKey: attribute.name)
                case .dateAttributeType: object.setValue(Date(timeIntervalSince1970: 1_790_000_000), forKey: attribute.name)
                case .booleanAttributeType: object.setValue(false, forKey: attribute.name)
                case .doubleAttributeType, .floatAttributeType, .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: object.setValue(0, forKey: attribute.name)
                default: break
                }
            }
            return object
        }
        let ottai = insert("Ottai")
        ottai.setValue("6CA04230E260", forKey: "ottaiSensorId")
        let peripheral = insert("BLEPeripheral")
        peripheral.setValue("E9F7A234-6366-4FB4-ACB8-DF3B092D6E72", forKey: "address")
        ottai.setValue(peripheral, forKey: "blePeripheral")
        let sensor = insert("Sensor")
        let reading = insert("BgReading")
        reading.setValue("preserved-reading", forKey: "id")
        reading.setValue(123.0, forKey: "calculatedValue")
        reading.setValue(sensor, forKey: "sensor")
        try context.save()
        context.reset()
        try first.remove(store)

        let second = NSPersistentStoreCoordinator(managedObjectModel: new)
        _ = try second.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let migrated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migrated.persistentStoreCoordinator = second
        let preserved = try XCTUnwrap(migrated.fetch(NSFetchRequest<NSManagedObject>(entityName: "Ottai")).first)
        XCTAssertEqual(preserved.value(forKey: "ottaiSensorId") as? String, "6CA04230E260")
        XCTAssertNotNil(preserved.value(forKey: "blePeripheral"))
        let glucose = try XCTUnwrap(migrated.fetch(NSFetchRequest<NSManagedObject>(entityName: "BgReading")).first)
        XCTAssertEqual(glucose.value(forKey: "id") as? String, "preserved-reading")
        XCTAssertEqual(glucose.value(forKey: "calculatedValue") as? Double, 123)
        _ = NSManagedObject(entity: try XCTUnwrap(new.entitiesByName["Aidex"]), insertInto: migrated)
        try migrated.save()
        XCTAssertEqual(try migrated.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Aidex")), 1)
    }
    func testV34StoreMigratesToV35PreservingOttaiAidexAndGlucose() throws {
        let bundle = Bundle(for: Ottai.self)
        let modelDirectory = try XCTUnwrap(bundle.url(forResource: "xdrip", withExtension: "momd"))
        let old = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("xdrip personal v34.mom")))
        let new = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("xdrip personal v35.mom")))
        XCTAssertNil(old.entitiesByName["SibionicsCN"])
        XCTAssertNotNil(new.entitiesByName["SibionicsCN"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("migration.sqlite")
        let first = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try first.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = first
        func insert(_ name: String) -> NSManagedObject {
            let entity = old.entitiesByName[name]!
            let object = NSManagedObject(entity: entity, insertInto: context)
            for attribute in entity.attributesByName.values where !attribute.isOptional && attribute.defaultValue == nil {
                switch attribute.attributeType {
                case .stringAttributeType: object.setValue("fixture", forKey: attribute.name)
                case .dateAttributeType: object.setValue(Date(timeIntervalSince1970: 1_790_000_000), forKey: attribute.name)
                case .booleanAttributeType: object.setValue(false, forKey: attribute.name)
                case .doubleAttributeType, .floatAttributeType, .integer16AttributeType, .integer32AttributeType, .integer64AttributeType: object.setValue(0, forKey: attribute.name)
                default: break
                }
            }
            return object
        }
        let ottai = insert("Ottai")
        ottai.setValue("6CA04230E260", forKey: "ottaiSensorId")
        let peripheral = insert("BLEPeripheral")
        peripheral.setValue("E9F7A234-6366-4FB4-ACB8-DF3B092D6E72", forKey: "address")
        ottai.setValue(peripheral, forKey: "blePeripheral")
        let sensor = insert("Sensor")
        let reading = insert("BgReading")
        reading.setValue("preserved-reading", forKey: "id")
        reading.setValue(123.0, forKey: "calculatedValue")
        reading.setValue(sensor, forKey: "sensor")
        let aidex = insert("Aidex")
        aidex.setValue("preserved-aidex", forKey: "modelName")
        try context.save()
        context.reset()
        try first.remove(store)

        let second = NSPersistentStoreCoordinator(managedObjectModel: new)
        _ = try second.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true])
        let migrated = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        migrated.persistentStoreCoordinator = second
        let preserved = try XCTUnwrap(migrated.fetch(NSFetchRequest<NSManagedObject>(entityName: "Ottai")).first)
        XCTAssertEqual(preserved.value(forKey: "ottaiSensorId") as? String, "6CA04230E260")
        XCTAssertNotNil(preserved.value(forKey: "blePeripheral"))
        let glucose = try XCTUnwrap(migrated.fetch(NSFetchRequest<NSManagedObject>(entityName: "BgReading")).first)
        XCTAssertEqual(glucose.value(forKey: "id") as? String, "preserved-reading")
        XCTAssertEqual(glucose.value(forKey: "calculatedValue") as? Double, 123)
        let preservedAidex = try XCTUnwrap(migrated.fetch(NSFetchRequest<NSManagedObject>(entityName: "Aidex")).first)
        XCTAssertEqual(preservedAidex.value(forKey: "modelName") as? String, "preserved-aidex")
        let gs1 = NSManagedObject(entity: try XCTUnwrap(new.entitiesByName["SibionicsCN"]), insertInto: migrated)
        XCTAssertEqual(gs1.value(forKey: "startAuthorized") as? Bool, false)
        try migrated.save()
        XCTAssertEqual(try migrated.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "SibionicsCN")), 1)
    }
}
