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
    /// Each range is the narrower of ours and Trio's own settings screen (`DecimalPickerSettings`), so a
    /// proposal can never set a value a person could not pick in Trio itself (2026-09-28: DIA 3 was
    /// accepted here, Trio's loop requires at least 5 and stopped).
    static let bounds: [String: ClosedRange<Double>] = [
        "pref.max_iob": 0 ... 30, // maxIOB 0…30
        "pref.autosens_max": 1 ... 2, // autosensMax 0.5…2
        "pref.autosens_min": 0.5 ... 1, // autosensMin 0.5…1
        "pref.smb_delivery_ratio": 0.3 ... 0.7, // smbDeliveryRatio 0.3…0.7
        "pref.maxSMBBasalMinutes": 30 ... 180, // 15…180
        "pref.maxUAMSMBBasalMinutes": 30 ... 180, // 15…180
        "pref.SMBInterval": 1 ... 10, // smbInterval 1…10
        "pref.half_basal_exercise_target": 105 ... 300, // halfBasalExerciseTarget 105…300
        "pref.maxCOB": 0 ... 300, // maxCOB 0…300
        "pref.enableSMB_high_bg_target": 70 ... 200, // enableSMB_high_bg_target 70…200
        "pref.threshold_setting": 60 ... 120, // threshold_setting 60…120
        "pref.adjustmentFactor": 0.3 ... 3, // adjustmentFactor 0.3…3
        "pref.adjustmentFactorSigmoid": 0.1 ... 2, // adjustmentFactorSigmoid 0.1…2
        "pref.weightPercentage": 0.05 ... 1, // weightPercentage 0.05…1
        "pref.bolus_increment": 0.05 ... 1, // bolusIncrement 0.05…1
        "pref.insulinPeakTime": 35 ... 120, // insulinPeakTime 35…120
        "pref.maxDelta_bg_threshold": 0.1 ... 0.4, // maxDeltaBGthreshold 0.1…0.4
        "pref.max_daily_safety_multiplier": 1 ... 5, // maxDailySafetyMultiplier 1…5
        "pref.current_basal_safety_multiplier": 1 ... 5, // currentBasalSafetyMultiplier 1…5
        "pref.min_5m_carbimpact": 1 ... 20, // min5mCarbimpact 1…20
        "pref.remainingCarbsFraction": 0.5 ... 1, // remainingCarbsFraction 0.5…1
        "pref.remainingCarbsCap": 0 ... 200, // remainingCarbsCap 0…200
        "pref.carbsReqThreshold": 0 ... 10, // carbsReqThreshold 0…10
        "pref.noisyCGMTargetMultiplier": 1 ... 2, // noisyCGMTargetMultiplier 1…2
        "pref.maxMealAbsorptionTime": 4 ... 10, // maxMealAbsorptionTime 4…10
        "pref.updateInterval": 5 ... 60, // updateInterval 1…60
        "pump.maxBolus": 0.5 ... 30, // maxBolus 0.5…30
        "pump.maxBasal": 0.5 ... 30, // maxBasal 0.5…30
        "pump.insulin_action_curve": 5 ... 10, // dia 5…10 (the loop refuses < 5)
        "settings.low": 40 ... 100, // low 40…100
        "settings.high": 120 ... 400, // high 100…400
        "settings.maxCarbs": 0 ... 300, // maxCarbs 0…300
        "settings.maxFat": 0 ... 300, // maxFat 0…300
        "settings.maxProtein": 0 ... 300, // maxProtein 0…300
        "settings.individualAdjustmentFactor": 0.1 ... 1, // 0.1…1.2
        "settings.fattyMealFactor": 0.1 ... 1, // 0.05…1
        "settings.sweetMealFactor": 0.5 ... 2, // 0.05…2
        "settings.overrideFactor": 0.1 ... 1, // 0.05…1.5
        "settings.carbsRequiredThreshold": 0 ... 100, // carbsRequiredThreshold 0…100
        "settings.minuteInterval": 30 ... 60, // minuteInterval 30…60
        "settings.delay": 15 ... 120 // delay 15…120
    ]

    /// Preference values Trio accepts in its model but its loop cannot run with.
    /// `bilinear`: `IobCalculation.lookupPeak` has no peak for it, so every loop stops with an IOB error.
    static let refusedPreferenceValues: [String: Set<String>] = [
        "curve": [InsulinCurve.bilinear.rawValue]
    ]

    /// Preferences a proposal may never set (bookkeeping, not a setting).
    static let refusedPreferences: Set<String> = ["timestamp"]

    /// Keys whose values Trio's loop reads: a proposal touching any of them gets the loop preflight
    /// and is watched after it is applied (rolled back if the loop fails with it).
    static let loopSettingsKeys: Set<String> = ["settings.dosingMode", "settings.smoothGlucose"]

    static func touchesLoop(_ changes: [String: Any]) -> Bool {
        changes.keys.contains { k in
            k.hasPrefix(SweetMiranda.Key.prefPrefix) || k.hasPrefix(SweetMiranda.Key.pumpPrefix)
                || [SweetMiranda.Key.basal, SweetMiranda.Key.isf, SweetMiranda.Key.cr, SweetMiranda.Key.targets].contains(k)
                || loopSettingsKeys.contains(k)
        }
    }

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
        let approvers: [SMApprover]
        let podKeepAlive: String?
    }

    /// The full picture, as plain JSON.
    static func snapshot(_ s: Sources) throws -> [String: Any] {
        var settingsAll = try jsonObject(s.settings)
        settingsAll = settingsAll
            .filter { settingsAllowed.contains($0.key) || ["units", "cgm", "isUploadEnabled", "uploadGlucose"].contains($0.key) }
        var pumpDict = try jsonObject(s.pump)
        pumpDict["name"] = s.pumpName
        if let keepAlive = s.podKeepAlive { pumpDict["podKeepAlive"] = keepAlive }
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
            "approvers": s.approvers.map { ["keyId": $0.keyId, "name": $0.name, "addedAt": SMDates.string($0.addedAt)] },
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
                guard !refusedPreferences.contains(k) else { throw SMError.invalid("Preference \(k) cannot be changed remotely") }
                guard let old = prefNow[k] else { throw SMError.invalid("Unknown preference \(k)") }
                try checkScalar(key: key, new: raw, old: old)
                if let refused = refusedPreferenceValues[k], let s = raw as? String, refused.contains(s) {
                    throw SMError.invalid(
                        "\(prettyPref(k)) \"\(s)\" is not supported by Trio's loop (it cannot compute insulin on board " +
                            "with it and stops). Use rapid-acting or ultra-rapid."
                    )
                }
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
            } else if key == SweetMiranda.Key.approverAdd {
                let a = try SMApprovers.parseAdd(raw)
                guard !current.approvers.contains(where: { $0.keyId == a.keyId }) else {
                    throw SMError.invalid("\(a.name) is already an approver")
                }
                lines.append(SMChangeLine(
                    id: key,
                    group: "Approvers",
                    label: "Approve settings with Face ID from another phone",
                    from: "Not allowed",
                    to: "\(a.name) · key \(a.keyId.prefix(8))"
                ))
            } else if key == SweetMiranda.Key.approverRemove {
                guard let keyId = raw as? String, let a = current.approvers.first(where: { $0.keyId == keyId }) else {
                    throw SMError.invalid("That approver is not on this phone")
                }
                lines.append(SMChangeLine(
                    id: key,
                    group: "Approvers",
                    label: "Stop Face ID approvals from",
                    from: "\(a.name) · key \(a.keyId.prefix(8))",
                    to: "Removed"
                ))
            } else {
                throw SMError.invalid("Unknown change key \(key)")
            }
        }
        guard !lines.isEmpty else { throw SMError.invalid("The proposal contains no changes") }
        try checkCrossField(changes: changes, against: current)
        return lines
    }

    /// Rules between two values, checked on what the phone would have after the proposal
    /// (a changed value, else the one in use now). Only when the proposal touches one of the pair.
    static func checkCrossField(changes: [String: Any], against current: Sources) throws {
        let maxBasalKey = SweetMiranda.Key.pumpPrefix + "maxBasal"
        let basalRaw = changes[SweetMiranda.Key.basal]
        if basalRaw != nil || changes[maxBasalKey] != nil {
            let maxBasal = changes[maxBasalKey].flatMap(decimal) ?? current.pump.maxBasal
            let rates = try basalRaw.map { try parseBasal($0, supported: current.supportedBasalRates).map(\.rate) }
                ?? current.basal.map(\.rate)
            if let top = rates.max(), top > maxBasal {
                throw SMError.invalid(
                    "The basal schedule goes up to \(show(num(top))) U/h, above the max basal rate of \(show(num(maxBasal))) U/h"
                )
            }
        }

        let aMaxKey = SweetMiranda.Key.prefPrefix + "autosens_max"
        let aMinKey = SweetMiranda.Key.prefPrefix + "autosens_min"
        if changes[aMaxKey] != nil || changes[aMinKey] != nil {
            let aMax = changes[aMaxKey].flatMap(decimal) ?? current.preferences.autosensMax
            let aMin = changes[aMinKey].flatMap(decimal) ?? current.preferences.autosensMin
            guard aMin <= aMax else {
                throw SMError.invalid("Autosens min (\(show(num(aMin)))) cannot be above autosens max (\(show(num(aMax))))")
            }
        }

        let lowKey = SweetMiranda.Key.settingsPrefix + "low"
        let highKey = SweetMiranda.Key.settingsPrefix + "high"
        if changes[lowKey] != nil || changes[highKey] != nil {
            let low = changes[lowKey].flatMap(decimal) ?? current.settings.low
            let high = changes[highKey].flatMap(decimal) ?? current.settings.high
            guard low < high else {
                throw SMError.invalid("The low glucose line (\(show(num(low)))) must be below the high line (\(show(num(high))))")
            }
        }
    }

    private static func num(_ d: Decimal) -> NSNumber { NSNumber(value: dbl(d)) }

    // MARK: - Would-be settings and the loop preflight

    /// A proposal parsed once into the values Trio stores. The same values are preflighted and applied;
    /// nil means the proposal leaves that part alone.
    struct Parsed {
        var pump: PumpSettings?
        var basal: [BasalProfileEntry]?
        var isf: InsulinSensitivities?
        var cr: CarbRatios?
        var targets: BGTargets?
        var preferences: Preferences?
        var settings: TrioSettings?
    }

    static func parse(changes: [String: Any], current: Sources) throws -> Parsed {
        var p = Parsed()
        p.pump = newPumpSettings(current.pump, changes: changes)
        if let raw = changes[SweetMiranda.Key.basal] { p.basal = try parseBasal(raw, supported: current.supportedBasalRates) }
        if let raw = changes[SweetMiranda.Key.isf] { p.isf = try parseISF(raw) }
        if let raw = changes[SweetMiranda.Key.cr] { p.cr = try parseCR(raw) }
        if let raw = changes[SweetMiranda.Key.targets] { p.targets = try parseTargets(raw) }
        if changes.keys.contains(where: { $0.hasPrefix(SweetMiranda.Key.prefPrefix) }) {
            p.preferences = try newPreferences(current.preferences, changes: changes)
        }
        if changes.keys.contains(where: { $0.hasPrefix(SweetMiranda.Key.settingsPrefix) }) {
            p.settings = try newSettings(current.settings, changes: changes)
        }
        return p
    }

    /// Throws when Trio's loop would refuse the settings the phone would have after `p` (see `loopProblem`).
    static func preflight(_ p: Parsed, current: Sources, now: Date = Date()) throws {
        if let why = loopProblem(p, current: current, now: now) {
            throw SMError.invalid("Trio's loop would refuse these settings, so nothing was changed. The algorithm says: \(why)")
        }
    }

    /// Runs Trio's own profile builder — the first step of every loop cycle — on the settings the phone
    /// would have after `p`, at every schedule boundary of the day and now, and checks the insulin curve
    /// the way the IOB calculation does. Returns the algorithm's own words if the loop would refuse them,
    /// nil if it accepts them. Pure: reads nothing from storage, writes nothing.
    static func loopProblem(_ p: Parsed, current: Sources, now: Date = Date()) -> String? {
        let pump = p.pump ?? current.pump
        let basal = p.basal ?? current.basal
        let isf = p.isf ?? current.isf
        let cr = p.cr ?? current.cr
        let targets = p.targets ?? current.targets
        let mode = (p.settings ?? current.settings).dosingMode
        // the loop hands the profile builder these, clamped for the loop mode (OpenAPS.createProfiles)
        let prefs = (p.preferences ?? current.preferences).clamped(for: mode)

        guard IobCalculation.lookupPeak(
            curve: prefs.curve,
            useCustomPeakTime: prefs.useCustomPeakTime,
            insulinPeakTime: prefs.insulinPeakTime
        ) != nil else {
            return "the insulin curve \"\(prefs.curve.rawValue)\" is not supported (no insulin peak time)"
        }

        var minutes = Set(stride(from: 0, to: 1440, by: 30))
        minutes.formUnion(basal.map(\.minutes))
        minutes.formUnion(isf.sensitivities.map(\.offset))
        minutes.formUnion(cr.schedule.map(\.offset))
        minutes.formUnion(targets.targets.map(\.offset))
        let day = Calendar.current.startOfDay(for: now)
        let clocks = [now] + minutes.filter { $0 >= 0 && $0 < 1440 }.sorted()
            .map { day.addingTimeInterval(TimeInterval($0 * 60)) }
        for clock in clocks {
            do {
                _ = try ProfileGenerator.generate(
                    pumpSettings: pump,
                    bgTargets: targets,
                    basalProfile: basal,
                    isf: isf,
                    preferences: prefs,
                    carbRatios: cr,
                    tempTargets: [],
                    clock: clock
                )
            } catch {
                let at = clock == now ? "" : " (at \(startString(Int(clock.timeIntervalSince(day) / 60)).dropLast(3)))"
                return error.localizedDescription + at
            }
        }
        return nil
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
