import Foundation

enum AidexReadingPolicy {
    static func timestamp(startTimeMs: Int64, offsetMinutes: Int, now: Date) -> Date? {
        guard startTimeMs > 0, offsetMinutes >= 0 else { return nil }
        let timestamp = Date(timeIntervalSince1970: Double(startTimeMs) / 1000 + Double(offsetMinutes) * 60)
        return accepts(timestamp: timestamp, now: now) ? timestamp : nil
    }

    static func accepts(timestamp: Date, now: Date) -> Bool {
        let time = timestamp.timeIntervalSince1970
        return time.isFinite && time > 0 && timestamp <= now.addingTimeInterval(10 * 60)
    }

    static func heartbeatIdentifier(_ value: String?) -> String? {
        value.flatMap(UUID.init(uuidString:))?.uuidString
    }
}
