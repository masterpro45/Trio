import CoreData
import Foundation

/// Sweet Miranda: "insulin already working" guard on her BOLUS hold (Wilson 2026-11-13).
///
/// Why: Trio's own math already counts insulin on board. After a dose it cuts basal and
/// recommends 0 more. The lows came from doses typed BY HAND on top of that. On 2026-11-12
/// at 23:55 ET Trio had 6.4 U working and recommended 0. Then 5.5 U and 2 U more were given
/// by hand (13 U on board, Trio's forecast −271), and she reached 39 mg/dL around 02:00.
///
/// The guard uses Trio's own numbers only: its recommendation, its insulin on board and
/// its forecast with the typed dose. It never computes a dose and never changes the
/// algorithm. It only decides whether her hold button is the normal one, a deliberate
/// "give it anyway", or blocked.
enum SweetMirandaStackGuard {
    /// A hand bolus in this window counts as "insulin already working" even when the loop's
    /// IOB is low. Matches the rapid-acting curve doing most of its work in 2 to 3 h.
    static let recentWindowHours: Double = 3
    /// Insulin on board at or above this counts as "already working".
    static let workingIOB: Decimal = 1.0
    /// Typed amounts this close to Trio's recommendation are treated as following it.
    static let tolerance: Decimal = 0.05
    /// Trio's own "very low" line (`bolusWarning` in TreatmentsRootView). Below this,
    /// her phone does not offer the extra dose at all.
    static let blockBelow: Decimal = 54
    /// The extra-dose hold. Deliberately longer than the normal 1 s hold.
    static let overrideHoldSeconds: Double = 3

    struct Inputs: Equatable {
        var amount: Decimal
        var recommended: Decimal
        var iob: Decimal
        var recentManualTotal: Decimal
        /// Trio's simulated lowest forecast with the typed dose. 0 means unknown.
        var forecastLowest: Decimal
    }

    enum Verdict: Equatable {
        /// Normal hold button.
        case ok
        /// More than Trio says while insulin is already working. Offer Trio's amount, or a 3 s hold.
        case stacking
        /// Same as stacking, but Trio's forecast with this dose is under 54. Not offered on her phone.
        case blocked
    }

    static func evaluate(_ i: Inputs) -> Verdict {
        guard i.amount > 0 else { return .ok }
        let over = i.amount > max(i.recommended, 0) + tolerance
        let working = i.iob >= workingIOB || i.recentManualTotal > 0
        guard over, working else { return .ok }
        if i.forecastLowest != 0, i.forecastLowest < blockBelow { return .blocked }
        return .stacking
    }

    struct Recent: Equatable {
        var total: Decimal = 0
        var last: Date?
        var lastAmount: Decimal = 0
    }

    /// Her own pump boluses (not Trio's SMBs, not external pen doses) in the last 3 h.
    static func fetchRecentManual(now: Date = Date()) async -> Recent {
        let context = CoreDataStack.shared.newTaskContext()
        context.name = "sweetMirandaStackGuard"
        let since = now.addingTimeInterval(-recentWindowHours * 3600)
        return await context.perform {
            let request = PumpEventStored.fetchRequest()
            request.predicate = NSPredicate(
                format: "type == %@ AND timestamp >= %@ AND bolus.isExternal == %@ AND bolus.isSMB == %@",
                PumpEventStored.EventType.bolus.rawValue,
                since as NSDate,
                false as NSNumber,
                false as NSNumber
            )
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            guard let events = try? context.fetch(request) else { return Recent() }
            var r = Recent()
            for e in events {
                let u = (e.bolus?.amount as Decimal?) ?? 0
                guard u > 0 else { continue }
                r.total += u
                if r.last == nil {
                    r.last = e.timestamp
                    r.lastAmount = u
                }
            }
            return r
        }
    }
}
