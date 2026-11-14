import Foundation

/// Shared default for AiDex/LinX/LumiFlex; measured from the existing session start.
enum ConstantsAidex {
    // LinX manufacturer user guide (1034-PMTL-413.V03) specifies one hour:
    // https://microtechmd.com/utils/down?fileName=1034-PMTL-413.V03%20LinX%20CGMS%EF%BC%88CE%EF%BC%89.pdf&myfile=%2Fmtsc%2Fuploads%2Fsingle%2F1034-PMTL-413.V03_LinX_CGMS%EF%BC%88CE%EF%BC%89.pdf
    // LumiFlex instructions also specify 60 minutes: https://lumiflex.ru/help/linx-step-1/
    static let warmupMinutes: Double = 60

    static func matchesModelDescription(_ description: String) -> Bool {
        let lower = description.lowercased()
        return ["aidex", "linx", "lumiflex"].contains { lower.contains($0) }
    }
}
