import Foundation
import LoopKit

/// Sweet Miranda: a hand-entered CGM session clock.
///
/// Miranda's G6 reaches Trio through **Nightscout as CGM**, and that path owns no
/// `CGMManagerUI` — `NightscoutManager.cgmProgressHighlight` is created nil and never
/// updated. So Trio's sensor arc and its remaining-time tag have nothing to draw and
/// stay blank, even though the sensor has a perfectly ordinary 10-day life.
///
/// This fills that gap from the one fact the phone can't discover on its own: the day
/// she put the sensor on. She enters it (or taps "I changed it just now") and everything
/// downstream — the countdown, the arc, the colour as it runs out — comes from that date.
///
/// It is deliberately a *fallback*: `HomeStateModel` consults it only when the active CGM
/// reports no lifecycle of its own, so a future plugin CGM that knows its own session
/// silently takes precedence and nothing here has to be removed.
final class SweetMirandaSensorSession: ObservableObject {
    static let shared = SweetMirandaSensorSession()

    // MARK: - Stored state

    private enum Key {
        static let startedAt = "sweetMiranda.sensor.startedAt"
        static let lifetimeDays = "sweetMiranda.sensor.lifetimeDays"
    }

    /// Dexcom G6: 10 days. Kept adjustable so a G7 (10 d) or a future sensor needs no code change.
    static let defaultLifetimeDays: Double = 10

    private let defaults: UserDefaults

    /// When the current sensor session began. `nil` until she enters one — and `nil` is a
    /// first-class state, not an error: the arc simply stays blank, exactly as it does today.
    @Published var startedAt: Date? {
        didSet {
            guard startedAt != oldValue else { return }
            if let startedAt {
                defaults.set(startedAt.timeIntervalSince1970, forKey: Key.startedAt)
            } else {
                defaults.removeObject(forKey: Key.startedAt)
            }
        }
    }

    @Published var lifetimeDays: Double {
        didSet {
            guard lifetimeDays != oldValue else { return }
            defaults.set(lifetimeDays, forKey: Key.lifetimeDays)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stamp = defaults.double(forKey: Key.startedAt)
        startedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        let days = defaults.double(forKey: Key.lifetimeDays)
        lifetimeDays = days > 0 ? days : Self.defaultLifetimeDays
    }

    // MARK: - Derived

    var lifetime: TimeInterval { lifetimeDays * 24 * 60 * 60 }

    /// End of the session, or `nil` when she hasn't entered a start date.
    var expiresAt: Date? {
        startedAt?.addingTimeInterval(lifetime)
    }

    /// Elapsed fraction of the session, clamped to 0...1. `nil` without a start date.
    func percentComplete(now: Date = Date()) -> Double? {
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard lifetime > 0 else { return nil }
        return max(0, min(1, elapsed / lifetime))
    }

    var timeRemaining: TimeInterval? {
        guard let expiresAt else { return nil }
        return max(0, expiresAt.timeIntervalSince(Date()))
    }

    /// Whole days left, rounded down — what the home orb shows.
    var daysRemaining: Int? {
        guard let timeRemaining else { return nil }
        return Int(timeRemaining / (24 * 60 * 60))
    }

    /// Trio's own arc colours come from this: green while there's room, orange in the last
    /// day and a bit, red once it's out. The thresholds are expressed in TIME rather than a
    /// bare percentage so they stay honest if the sensor lifetime is ever changed.
    func progressState(now: Date = Date()) -> DeviceLifecycleProgressState? {
        guard let expiresAt else { return nil }
        let remaining = expiresAt.timeIntervalSince(now)
        if remaining <= 0 { return .critical }
        if remaining <= 12 * 60 * 60 { return .critical }
        if remaining <= 36 * 60 * 60 { return .warning }
        return .normalCGM
    }

    /// The fallback Trio consumes. Shaped exactly like `AppGroupSource`'s and the
    /// simulator's so `HomeStateModel` can treat every source identically.
    func lifecycleProgress(now: Date = Date()) -> DeviceLifecycleProgress? {
        guard let percent = percentComplete(now: now), let state = progressState(now: now) else { return nil }
        return SweetMirandaLifecycleProgress(percentComplete: percent, progressState: state)
    }

    // MARK: - Actions

    /// "I changed it just now" — the one-tap path, which is how this will actually get used.
    func markChangedNow(now: Date = Date()) {
        startedAt = now
    }

    func clear() {
        startedAt = nil
    }

    /// A start date in the future is always a mis-tap, and one further back than two
    /// lifetimes is stale data rather than a real session.
    func isPlausible(_ date: Date, now: Date = Date()) -> Bool {
        date <= now && now.timeIntervalSince(date) <= lifetime * 2
    }
}

struct SweetMirandaLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}
