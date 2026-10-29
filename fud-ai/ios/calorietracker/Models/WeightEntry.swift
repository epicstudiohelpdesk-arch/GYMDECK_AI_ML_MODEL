import Foundation

struct WeightEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    var weightKg: Double

    init(id: UUID = UUID(), date: Date = .now, weightKg: Double) {
        self.id = id
        self.date = date
        self.weightKg = weightKg
    }

    var weightLbs: Double {
        weightKg * 2.20462
    }
}

/// One body-mass reading read from Apple Health.
struct WeightHealthSample: Equatable {
    let weightKg: Double
    let date: Date
    /// The `fudai_weight_id` metadata Fud AI tags its own samples with; nil for
    /// readings from other sources (scales, Apple Watch, the Health app).
    let fudaiID: UUID?
}

/// A weight entry the user deleted in Fud AI. Remembered so a reading that
/// still exists in Apple Health (another source's sample, or one of ours whose
/// Health delete failed) is not imported back into the history.
struct WeightDeletionTombstone: Codable, Equatable {
    let entryID: UUID
    let date: Date
    let weightKg: Double

    /// Fud AI's own samples match by entry id (or the exact reading), so the
    /// same value logged again later still counts. Other sources' samples match
    /// by same day + same value, the rule the import dedupes with: Health often
    /// holds one weigh-in from two sources (a scale and an app mirroring it) and
    /// Fud AI only ever showed one of them, so the other must stay deleted too.
    func matches(_ sample: WeightHealthSample, calendar: Calendar = .current) -> Bool {
        if let fudaiID = sample.fudaiID, fudaiID == entryID { return true }
        guard abs(sample.weightKg - weightKg) < 0.01 else { return false }
        if abs(sample.date.timeIntervalSince(date)) < 1 { return true }
        return sample.fudaiID == nil && calendar.isDate(sample.date, inSameDayAs: date)
    }
}
