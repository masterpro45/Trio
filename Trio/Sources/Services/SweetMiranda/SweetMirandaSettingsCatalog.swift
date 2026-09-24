import CryptoKit
import Foundation
import HealthKit
import LoopKit

/// Reads every setting Trio runs on into one JSON document (the *snapshot*) and applies a
/// validated set of changes back (a *proposal*). Pure data work; the manager owns the
/// Face ID gate, the pump sync and the Nightscout traffic.
enum SweetMirandaSettingsCatalog {
    // MARK: - Allow-lists and bounds

    /// TrioSettings keys a proposal may touch. Feed/plumbing keys (units, cgm, uploads,
    /// local glucose source, Apple Health) are deliberately absent: a wrong value there
    /// stops the loop's data and nobody on the phone would know why.
    static let settingsAllowed: Set<String> = [
        "dosingMode", "low", "high", "maxCarbs", "maxFat", "maxProtein",
        "confirmBolus", "confirmBolusFaster", "requireAdjustmentsConfirmation",
        "useFPUconversion", "individualAdjustmentFactor", "minuteInterval", "delay",
        "fattyMeals", "fattyMealFactor", "sweetMeals", "sweetMealFactor", "overrideFactor",
        "carbsRequiredThreshold", "showCarbsRequiredBadge", "smoothGlucose",
        "displayGlucoseForecasts", "timeInRangeType", "eA1cDisplayUnit", "forecastDisplayType",
        "glucoseColorScheme", "bolusShortcut", "enableQuickPickTreatments", "displayPresets",
        "bolusDisplayThreshold", "showCobIobChart", "homeStatsPanelFace"
    ]

    /// Numeric bounds (inclusive). Anything outside is refused before Face ID is even asked.
    static let bounds: [String: ClosedRange<Double>] = [
        "pref.max_iob": 0 ... 30,
        "pref.autosens_max": 1 ... 3,
        "pref.autosens_min": 0.1 ... 1,
        "pref.smb_delivery_ratio": 0.3 ... 0.7,
        "pref.maxSMBBasalMinutes": 30 ... 180,
        "pref.maxUAMSMBBasalMinutes": 30 ... 180,
        "pref.SMBInterval": 1 ... 10,
        "pref.half_basal_exercise_target": 100 ... 300,
        "pref.maxCOB": 0 ... 300,
        "pref.enableSMB_high_bg_target": 70 ... 300,
        "pref.threshold_setting": 60 ... 120,
        "pref.adjustmentFactor": 0.1 ... 3,
        "pref.adjustmentFactorSigmoid": 0.1 ... 3,
        "pref.weightPercentage": 0 ... 1,
        "pref.bolus_increment": 0.05 ... 1,
        "pref.insulinPeakTime": 35 ... 120,
        "pref.maxDelta_bg_threshold": 0.1 ... 0.4,
        "pref.max_daily_safety_multiplier": 1 ... 10,
        "pref.current_basal_safety_multiplier": 1 ... 10,
        "pref.min_5m_carbimpact": 1 ... 30,
        "pref.remainingCarbsFraction": 0 ... 1,
        "pref.remainingCarbsCap": 0 ... 200,
        "pref.carbsReqThreshold": 0 ... 50,
        "pref.noisyCGMTargetMultiplier": 1 ... 3,
        "pref.maxMealAbsorptionTime": 1 ... 12,
        "pref.updateInterval": 5 ... 60,
        "pump.maxBolus": 0.5 ... 30,
        "pump.maxBasal": 0.1 ... 30,
        "pump.insulin_action_curve": 3 ... 14,
        "settings.low": 40 ... 120,
        "settings.high": 120 ... 400,
        "settings.maxCarbs": 0 ... 500,
        "settings.maxFat": 0 ... 500,
        "settings.maxProtein": 0 ... 500,
        "settings.individualAdjustmentFactor": 0.1 ... 1,
        "settings.fattyMealFactor": 0.1 ... 1,
        "settings.sweetMealFactor": 0.5 ... 2,
        "settings.overrideFactor": 0.1 ... 1,
        "settings.carbsRequiredThreshold": 0 ... 100,
        "settings.minuteInterval": 5 ... 120,
        "settings.delay": 0 ... 240
    ]

    static let scheduleBounds: [String: ClosedRange<Double>] = [
        SweetMiranda.Key.basal: 0.05 ... 30,
        SweetMiranda.Key.isf: 5 ... 600,
        SweetMiranda.Key.cr: 1 ... 150,
        SweetMiranda.Key.targets: 70 ... 200
    ]

    // MARK: - Snapshot

    struct Sources {
        let preferences: Preferences
        let settings: TrioSettings
        let pump: PumpSettings
        let basal: [BasalProfileEntry]
        let isf: InsulinSensitivities
        let cr: CarbRatios
        let targets: BGTargets
        let pumpName: String
        let supportedBasalRates: [Decimal]?
        let remoteControlEnabled: Bool
    }

    /// The full picture, as plain JSON.
    static func snapshot(_ s: Sources) throws -> [String: Any] {
        var settingsAll = try jsonObject(s.settings)
        settingsAll = settingsAll
            .filter { settingsAllowed.contains($0.key) || ["units", "cgm", "isUploadEnabled", "uploadGlucose"].contains($0.key) }
        var pumpDict = try jsonObject(s.pump)
        pumpDict["name"] = s.pumpName
        if let rates = s.supportedBasalRates, !rates.isEmpty {
            pumpDict["supportedBasalRates"] = ["min": dbl(rates.min()!), "max": dbl(rates.max()!), "count": rates.count]
        }
        let doc: [String: Any] = [
            "preferences": try jsonObject(s.preferences),
            "settings": settingsAll,
            "pump": pumpDict,
            "basal": s.basal.map { ["start": $0.start, "minutes": $0.minutes, "rate": dbl($0.rate)] },
            "isf": s.isf.sensitivities.map { ["start": $0.start, "offset": $0.offset, "sensitivity": dbl($0.sensitivity)] },
            "cr": s.cr.schedule.map { ["start": $0.start, "offset": $0.offset, "ratio": dbl($0.ratio)] },
            "targets": s.targets.targets
                .map { ["start": $0.start, "offset": $0.offset, "low": dbl($0.low), "high": dbl($0.high)] },
            "remoteControlEnabled": s.remoteControlEnabled,
            "app": [
                "version": Bundle.main.appDevVersion ?? "unknown",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "branch": BuildDetails.shared.branchAndSha
            ],
            "takenAt": SMDates.string(Date())
        ]
        return doc
    }

    /// sha256 over the canonical (sorted-keys) JSON of everything that is a setting —
    /// `takenAt` and the app block are left out so an unchanged phone hashes the same.
    static func hash(of snapshot: [String: Any]) -> String {
        var s = snapshot
        s.removeValue(forKey: "takenAt")
        s.removeValue(forKey: "app")
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Validation

    /// Checks every change against the allow-lists and bounds. Returns human lines for the
    /// approval sheet; throws on the first thing that must not be applied.
    static func validate(changes: [String: Any], against current: Sources) throws -> [SMChangeLine] {
        var lines: [SMChangeLine] = []
        let prefNow = try jsonObject(current.preferences)
        let setNow = try jsonObject(current.settings)
        let pumpNow = try jsonObject(current.pump)

        for (key, raw) in changes.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix(SweetMiranda.Key.prefPrefix) {
                let k = String(key.dropFirst(SweetMiranda.Key.prefPrefix.count))
                guard let old = prefNow[k] else { throw SMError.invalid("Unknown preference \(k)") }
                try checkScalar(key: key, new: raw, old: old)
                lines.append(SMChangeLine(id: key, group: "Algorithm", label: prettyPref(k), from: show(old), to: show(raw)))
            } else if key.hasPrefix(SweetMiranda.Key.settingsPrefix) {
                let k = String(key.dropFirst(SweetMiranda.Key.settingsPrefix.count))
                guard settingsAllowed.contains(k) else { throw SMError.invalid("Setting \(k) cannot be changed remotely") }
                guard let old = setNow[k] else { throw SMError.invalid("Unknown setting \(k)") }
                try checkScalar(key: key, new: raw, old: old)
                lines.append(SMChangeLine(id: key, group: "Trio", label: prettySetting(k), from: show(old), to: show(raw)))
            } else if key.hasPrefix(SweetMiranda.Key.pumpPrefix) {
                let k = String(key.dropFirst(SweetMiranda.Key.pumpPrefix.count))
                guard let old = pumpNow[k] else { throw SMError.invalid("Unknown pump limit \(k)") }
                try checkScalar(key: key, new: raw, old: old)
                lines.append(SMChangeLine(id: key, group: "Limits", label: prettyPump(k), from: show(old), to: show(raw)))
            } else if key == SweetMiranda.Key.basal {
                let entries = try parseBasal(raw, supported: current.supportedBasalRates)
                lines.append(SMChangeLine(
                    id: key,
                    group: "Therapy",
                    label: "Basal schedule",
                    from: describeSchedule(current.basal.map { ($0.minutes, dbl($0.rate)) }, unit: "U/h"),
                    to: describeSchedule(entries.map { ($0.minutes, dbl($0.rate)) }, unit: "U/h")
                ))
            } else if key == SweetMiranda.Key.isf {
                let entries = try parseSchedule(raw, valueKey: "sensitivity", bounds: scheduleBounds[key]!)
                lines.append(SMChangeLine(
                    id: key,
                    group: "Therapy",
                    label: "Correction factor (ISF)",
                    from: describeSchedule(
                        current.isf.sensitivities.map { ($0.offset, dbl($0.sensitivity)) },
                        unit: "mg/dL"
                    ),
                    to: describeSchedule(entries.map { ($0.0, $0.1) }, unit: "mg/dL")
                ))
            } else if key == SweetMiranda.Key.cr {
                let entries = try parseSchedule(raw, valueKey: "ratio", bounds: scheduleBounds[key]!)
                lines.append(SMChangeLine(
                    id: key,
                    group: "Therapy",
                    label: "Carb ratio",
                    from: describeSchedule(
                        current.cr.schedule.map { ($0.offset, dbl($0.ratio)) },
                        unit: "g/U"
                    ),
                    to: describeSchedule(entries.map { ($0.0, $0.1) }, unit: "g/U")
                ))
            } else if key == SweetMiranda.Key.targets {
                let entries = try parseSchedule(raw, valueKey: "low", bounds: scheduleBounds[key]!)
                lines.append(SMChangeLine(
                    id: key,
                    group: "Therapy",
                    label: "Glucose target",
                    from: describeSchedule(
                        current.targets.targets.map { ($0.offset, dbl($0.low)) },
                        unit: "mg/dL"
                    ),
                    to: describeSchedule(entries.map { ($0.0, $0.1) }, unit: "mg/dL")
                ))
            } else {
                throw SMError.invalid("Unknown change key \(key)")
            }
        }
        guard !lines.isEmpty else { throw SMError.invalid("The proposal contains no changes") }
        return lines
    }

    // MARK: - Building new values

    static func newPreferences(_ current: Preferences, changes: [String: Any]) throws -> Preferences {
        var dict = try jsonObject(current)
        for (key, raw) in changes where key.hasPrefix(SweetMiranda.Key.prefPrefix) {
            dict[String(key.dropFirst(SweetMiranda.Key.prefPrefix.count))] = raw
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let new = try JSONCoding.decoder.decode(Preferences.self, from: data)
        // Preferences' decoder is lenient (a wrong type keeps the default) — prove every key landed.
        let after = try jsonObject(new)
        for (key, raw) in changes where key.hasPrefix(SweetMiranda.Key.prefPrefix) {
            let k = String(key.dropFirst(SweetMiranda.Key.prefPrefix.count))
            guard let got = after[k], sameValue(got, raw) else {
                throw SMError.invalid("Preference \(k) did not accept the value \(show(raw))")
            }
        }
        return new
    }

    static func newSettings(_ current: TrioSettings, changes: [String: Any]) throws -> TrioSettings {
        var dict = try jsonObject(current)
        for (key, raw) in changes where key.hasPrefix(SweetMiranda.Key.settingsPrefix) {
            dict[String(key.dropFirst(SweetMiranda.Key.settingsPrefix.count))] = raw
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let new = try JSONCoding.decoder.decode(TrioSettings.self, from: data)
        let after = try jsonObject(new)
        for (key, raw) in changes where key.hasPrefix(SweetMiranda.Key.settingsPrefix) {
            let k = String(key.dropFirst(SweetMiranda.Key.settingsPrefix.count))
            guard let got = after[k], sameValue(got, raw) else {
                throw SMError.invalid("Setting \(k) did not accept the value \(show(raw))")
            }
        }
        return new
    }

    static func newPumpSettings(_ current: PumpSettings, changes: [String: Any]) -> PumpSettings? {
        var dia = current.insulinActionCurve, maxBolus = current.maxBolus, maxBasal = current.maxBasal
        var touched = false
        for (key, raw) in changes where key.hasPrefix(SweetMiranda.Key.pumpPrefix) {
            guard let v = decimal(raw) else { continue }
            switch String(key.dropFirst(SweetMiranda.Key.pumpPrefix.count)) {
            case "insulin_action_curve": dia = v
                touched = true
            case "maxBolus": maxBolus = v
                touched = true
            case "maxBasal": maxBasal = v
                touched = true
            default: break
            }
        }
        return touched ? PumpSettings(insulinActionCurve: dia, maxBolus: maxBolus, maxBasal: maxBasal) : nil
    }

    static func parseBasal(_ raw: Any, supported: [Decimal]?) throws -> [BasalProfileEntry] {
        let rows = try parseSchedule(raw, valueKey: "rate", bounds: scheduleBounds[SweetMiranda.Key.basal]!)
        return try rows.map { minutes, value in
            let rate = Decimal(string: String(format: "%.3f", value)) ?? Decimal(value)
            if let supported, !supported.isEmpty, !supported.contains(where: { abs(dbl($0) - value) < 0.0001 }) {
                throw SMError.invalid("Basal rate \(value) U/h is not a rate this pump can deliver")
            }
            return BasalProfileEntry(start: startString(minutes), minutes: minutes, rate: rate)
        }
    }

    static func parseISF(_ raw: Any) throws -> InsulinSensitivities {
        let rows = try parseSchedule(raw, valueKey: "sensitivity", bounds: scheduleBounds[SweetMiranda.Key.isf]!)
        return InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: rows.map {
            InsulinSensitivityEntry(sensitivity: Decimal($0.1), offset: $0.0, start: startString($0.0))
        })
    }

    static func parseCR(_ raw: Any) throws -> CarbRatios {
        let rows = try parseSchedule(raw, valueKey: "ratio", bounds: scheduleBounds[SweetMiranda.Key.cr]!)
        return CarbRatios(units: .grams, schedule: rows.map {
            CarbRatioEntry(
                start: startString($0.0),
                offset: $0.0,
                ratio: Decimal(string: String(format: "%.2f", $0.1)) ?? Decimal($0.1)
            )
        })
    }

    static func parseTargets(_ raw: Any) throws -> BGTargets {
        let rows = try parseSchedule(raw, valueKey: "low", bounds: scheduleBounds[SweetMiranda.Key.targets]!)
        return BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: rows.map {
            BGTargetEntry(low: Decimal($0.1), high: Decimal($0.1), start: startString($0.0), offset: $0.0)
        })
    }

    // MARK: - Helpers

    /// A schedule is [{minutes|offset, <valueKey>}], sorted, starting at 0, on 30-minute marks.
    private static func parseSchedule(_ raw: Any, valueKey: String, bounds: ClosedRange<Double>) throws -> [(Int, Double)] {
        guard let arr = raw as? [[String: Any]],
              !arr.isEmpty else { throw SMError.invalid("Schedule \(valueKey) is empty or malformed") }
        var out: [(Int, Double)] = []
        for row in arr {
            let m = (row["minutes"] as? NSNumber)?.intValue ?? (row["offset"] as? NSNumber)?.intValue
            guard let minutes = m, let v = (row[valueKey] as? NSNumber)?.doubleValue else {
                throw SMError.invalid("Schedule row for \(valueKey) is missing minutes or value")
            }
            guard minutes >= 0, minutes < 1440,
                  minutes % 30 == 0 else { throw SMError.invalid("Schedule times must fall on 30-minute marks") }
            guard bounds.contains(v)
            else { throw SMError.invalid("\(valueKey) \(v) is outside \(bounds.lowerBound)–\(bounds.upperBound)") }
            out.append((minutes, v))
        }
        out.sort { $0.0 < $1.0 }
        guard out.first?.0 == 0 else { throw SMError.invalid("A schedule must start at 00:00") }
        guard Set(out.map(\.0)).count == out.count else { throw SMError.invalid("A schedule cannot repeat a start time") }
        return out
    }

    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func checkScalar(key: String, new: Any, old: Any) throws {
        if isBool(old) {
            guard isBool(new) else { throw SMError.invalid("\(key) expects on/off") }
            return
        }
        if let range = bounds[key] {
            guard let v = (new as? NSNumber)?.doubleValue, range.contains(v) else {
                throw SMError.invalid("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
            }
            return
        }
        if old is NSNumber {
            guard let v = (new as? NSNumber)?.doubleValue, v.isFinite else { throw SMError.invalid("\(key) expects a number") }
            return
        }
        if old is String {
            guard new is String else { throw SMError.invalid("\(key) expects a choice") }
            return
        }
        throw SMError.invalid("\(key) has a shape that cannot be changed remotely")
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONCoding.encoder.encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SMError.invalid("Could not read current settings")
        }
        return obj
    }

    private static func sameValue(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? NSNumber, let y = b as? NSNumber { return abs(x.doubleValue - y.doubleValue) < 0.00001 }
        if let x = a as? String, let y = b as? String { return x == y }
        return false
    }

    static func decimal(_ raw: Any) -> Decimal? {
        if let n = raw as? NSNumber { return n.decimalValue }
        if let s = raw as? String { return Decimal(string: s) }
        return nil
    }

    static func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }

    static func startString(_ minutes: Int) -> String {
        String(format: "%02d:%02d:00", minutes / 60, minutes % 60)
    }

    private static func describeSchedule(_ rows: [(Int, Double)], unit: String) -> String {
        rows.map { String(format: "%02d:%02d %@", $0.0 / 60, $0.0 % 60, trim($0.1)) }.joined(separator: " · ") + " " + unit
    }

    static func show(_ v: Any) -> String {
        if let n = v as? NSNumber {
            if isBool(n) { return n.boolValue ? "on" : "off" }
            return trim(n.doubleValue)
        }
        if let s = v as? String { return s }
        return "\(v)"
    }

    private static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func prettyPref(_ k: String) -> String {
        let names: [String: String] = [
            "max_iob": "Max IOB", "autosens_max": "Autosens max", "autosens_min": "Autosens min",
            "smb_delivery_ratio": "SMB delivery ratio", "rewind_resets_autosens": "Rewind resets autosens",
            "high_temptarget_raises_sensitivity": "High temp target raises sensitivity",
            "low_temptarget_lowers_sensitivity": "Low temp target lowers sensitivity",
            "sensitivity_raises_target": "Sensitivity raises target", "resistance_lowers_target": "Resistance lowers target",
            "half_basal_exercise_target": "Half basal exercise target", "maxCOB": "Max COB",
            "enableUAM": "Enable UAM", "enableSMB_with_COB": "Enable SMB with COB",
            "enableSMB_with_temptarget": "Enable SMB with temp target", "enableSMB_always": "Enable SMB always",
            "enableSMB_after_carbs": "Enable SMB after carbs", "allowSMB_with_high_temptarget": "Allow SMB with high temp target",
            "maxSMBBasalMinutes": "Max SMB basal minutes", "maxUAMSMBBasalMinutes": "Max UAM SMB basal minutes",
            "SMBInterval": "SMB interval", "bolus_increment": "Bolus increment", "curve": "Insulin curve",
            "useCustomPeakTime": "Use custom peak time", "insulinPeakTime": "Insulin peak time",
            "enableSMB_high_bg": "Enable SMB with high glucose", "enableSMB_high_bg_target": "High glucose target for SMB",
            "sigmoid": "Dynamic ISF: sigmoid", "adjustmentFactor": "Dynamic adjustment factor",
            "adjustmentFactorSigmoid": "Sigmoid adjustment factor", "useNewFormula": "Dynamic ISF enabled",
            "useWeightedAverage": "Weighted TDD average", "weightPercentage": "TDD weight",
            "tddAdjBasal": "Adjust basal (dynamic)",
            "threshold_setting": "Low glucose threshold", "maxDelta_bg_threshold": "Max delta-BG threshold",
            "maxDailySafetyMultiplier": "Max daily safety multiplier",
            "max_daily_safety_multiplier": "Max daily safety multiplier",
            "current_basal_safety_multiplier": "Current basal safety multiplier", "suspend_zeros_iob": "Suspend zeros IOB",
            "min_5m_carbimpact": "Min 5-min carb impact", "remainingCarbsFraction": "Remaining carbs fraction",
            "remainingCarbsCap": "Remaining carbs cap", "carbsReqThreshold": "Carbs required threshold",
            "noisyCGMTargetMultiplier": "Noisy CGM target multiplier", "maxMealAbsorptionTime": "Max meal absorption time",
            "skip_neutral_temps": "Skip neutral temps", "unsuspend_if_no_temp": "Unsuspend if no temp",
            "wide_bg_target_range": "Wide target range", "exercise_mode": "Exercise mode",
            "adv_target_adjustments": "Advanced target adjustments", "A52_risk_enable": "A52 risk enable",
            "updateInterval": "Update interval"
        ]
        return names[k] ?? k
    }

    private static func prettySetting(_ k: String) -> String {
        let names: [String: String] = [
            "dosingMode": "Loop mode", "low": "Low glucose line", "high": "High glucose line", "maxCarbs": "Max carbs per entry",
            "maxFat": "Max fat per entry", "maxProtein": "Max protein per entry", "confirmBolus": "Confirm bolus",
            "confirmBolusFaster": "Confirm bolus faster", "requireAdjustmentsConfirmation": "Confirm adjustments",
            "useFPUconversion": "Fat & protein conversion", "individualAdjustmentFactor": "FPU adjustment factor",
            "minuteInterval": "FPU interval", "delay": "FPU delay", "fattyMeals": "Fatty meals",
            "fattyMealFactor": "Fatty meal factor",
            "sweetMeals": "Sweet meals", "sweetMealFactor": "Sweet meal factor", "overrideFactor": "Bolus calculator factor",
            "carbsRequiredThreshold": "Carbs required threshold", "showCarbsRequiredBadge": "Carbs required badge",
            "smoothGlucose": "Smooth glucose", "displayGlucoseForecasts": "Show forecasts",
            "timeInRangeType": "Time in range type",
            "eA1cDisplayUnit": "eA1c unit", "forecastDisplayType": "Forecast style", "glucoseColorScheme": "Glucose colours",
            "bolusShortcut": "Bolus shortcut", "enableQuickPickTreatments": "Quick-pick treatments",
            "displayPresets": "Show presets",
            "bolusDisplayThreshold": "Bolus display threshold", "showCobIobChart": "COB/IOB chart",
            "homeStatsPanelFace": "Home stats face"
        ]
        return names[k] ?? k
    }

    private static func prettyPump(_ k: String) -> String {
        ["maxBolus": "Max bolus", "maxBasal": "Max basal rate", "insulin_action_curve": "Duration of insulin action"][k] ?? k
    }
}
