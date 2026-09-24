import Combine
import Foundation
import HealthKit
import LoopKit
import SwiftUI
import Swinject
import UserNotifications

/// Sweet Miranda ⇄ Trio: keeps the family's dashboard in sync with the settings this phone
/// runs on, and lets a proposal made there be applied here — only after the device owner
/// authenticates (Face ID / passcode).
///
/// Snapshots: whenever preferences, Trio settings, pump limits or any therapy schedule change,
/// the full settings document goes up to Nightscout as a treatment (kind "snapshot"); the
/// bridge on the family's server copies it to the dashboard and removes it again.
///
/// Proposals: after every loop cycle (and every 5 minutes in the foreground) Trio asks
/// Nightscout for pending proposals. A new one raises a local notification and, when the app
/// is on screen, the approval sheet. Approve → Face ID → validated changes are applied the
/// same way the in-app editors apply them (pump sync first for basal and limits) → a "result"
/// treatment reports what happened. Decline → a "result" too. Unanswered proposals expire
/// after 24 h.
protocol SweetMirandaSyncManager: AnyObject {
    func start()
    func checkNow()
    func uploadSnapshotIfChanged(force: Bool)
    func applicationBecameActive()
}

final class BaseSweetMirandaSyncManager: SweetMirandaSyncManager, Injectable, ObservableObject {
    @Injected() private var nightscoutManager: NightscoutManager!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var deviceManager: DeviceDataManager!
    @Injected() private var apsManager: APSManager!
    @Injected() private var unlockManager: UnlockManager!
    @Injected() private var router: Router!
    @Injected() private var broadcaster: Broadcaster!

    @Published private(set) var pending: SMProposal?
    @Published private(set) var pendingLines: [SMChangeLine] = []
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private let foregroundPoll: TimeInterval = 300
    private var pollTimer: Timer?
    private var snapshotDebounce: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var checking = false
    private var sheetShown = false

    @Persisted(key: "SweetMiranda.lastSnapshotHash") private var lastSnapshotHash: String = ""
    @Persisted(key: "SweetMiranda.lastSnapshotAt") private var lastSnapshotAt: Date = .distantPast
    @Persisted(key: "SweetMiranda.handledProposalIds") private var handledIds: [String] = []

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PreferencesObserver.self, observer: self)
        broadcaster.register(BasalProfileObserver.self, observer: self)
        broadcaster.register(InsulinSensitivitiesObserver.self, observer: self)
        broadcaster.register(CarbRatiosObserver.self, observer: self)
        broadcaster.register(BGTargetsObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)

        // after every loop cycle — this is what keeps working while the app is in the background
        apsManager.lastLoopDateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.checkNow() }
            .store(in: &subscriptions)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: self.foregroundPoll, repeats: true) { [weak self] _ in
                self?.checkNow()
                self?.uploadSnapshotIfChanged(force: false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.uploadSnapshotIfChanged(force: false)
            self?.checkNow()
        }
        debug(.remoteControl, "SweetMiranda: sync started")
    }

    func applicationBecameActive() {
        checkNow()
        Task { @MainActor in self.presentPendingIfNeeded() }
    }

    // MARK: - Proposals in

    func checkNow() {
        guard started, !checking else { return }
        checking = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.checking = false }
            let docs = await self.nightscoutManager.sweetMirandaFetchPending()
            let proposals = docs.compactMap(SMProposal.init(document:))
                .filter { !self.handledIds.contains($0.id) }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            guard let next = proposals.first else { return }
            if next.isExpired {
                await self.report(next, status: .expired, message: "Expired before anyone answered on the phone", applied: nil)
                self.markHandled(next.id)
                return
            }
            await MainActor.run {
                guard self.pending?.id != next.id else { return }
                do {
                    let lines = try SweetMirandaSettingsCatalog.validate(changes: next.changes, against: self.sources())
                    self.pending = next
                    self.pendingLines = lines
                    self.lastError = nil
                    self.notify(next)
                    self.presentPendingIfNeeded()
                } catch {
                    // the proposal itself is bad — answer it so the dashboard shows why, and drop it
                    Task {
                        await self.report(next, status: .failed, message: error.localizedDescription, applied: nil)
                        self.markHandled(next.id)
                    }
                }
            }
        }
    }

    @MainActor private func presentPendingIfNeeded() {
        guard let p = pending, !sheetShown, UIApplication.shared.applicationState == .active else { return }
        sheetShown = true
        let view = SweetMirandaProposalView(manager: self, proposal: p, lines: pendingLines)
        router.mainSecondaryModalView.send(AnyView(view))
    }

    private func notify(_ p: SMProposal) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Sweet Miranda sent new settings")
        content.body = p.note.isEmpty
            ? String(localized: "\(p.from) proposes \(pendingLines.count) change(s). Open Trio to review.")
            : "\(p.from): \(p.note)"
        content.sound = .default
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        let req = UNNotificationRequest(identifier: "SweetMiranda.proposal.\(p.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { debug(.remoteControl, "SweetMiranda: notification failed \(error)") }
        }
    }

    // MARK: - Decisions (called from the sheet)

    @MainActor func sheetDismissed() {
        sheetShown = false
    }

    @MainActor func decline(_ p: SMProposal) {
        busy = true
        Task {
            await report(p, status: .declined, message: "Declined on the phone", applied: nil)
            markHandled(p.id)
            await MainActor.run {
                self.busy = false
                self.clearPending(p)
            }
        }
    }

    @MainActor func approve(_ p: SMProposal) {
        busy = true
        lastError = nil
        Task {
            do {
                // 1. the device owner, and nobody else
                let ok = try await unlockManager.unlock()
                guard ok else { throw SMError.notAuthenticated }
                // 2. re-validate against what the phone runs NOW (it may have changed since the sheet opened)
                let current = sources()
                _ = try SweetMirandaSettingsCatalog.validate(changes: p.changes, against: current)
                // 3. apply, pump first
                let applied = try await apply(p.changes, current: current)
                // 4. tell everyone
                uploadSnapshotIfChanged(force: true)
                let hash = (try? SweetMirandaSettingsCatalog.hash(of: SweetMirandaSettingsCatalog.snapshot(sources()))) ?? ""
                await report(p, status: .applied, message: "Applied on the phone after Face ID", applied: applied, hash: hash)
                markHandled(p.id)
                await nightscoutManager
                    .uploadNoteTreatment(note: "Sweet Miranda settings applied: \(applied.keys.sorted().joined(separator: ", "))")
                await MainActor.run {
                    self.busy = false
                    self.clearPending(p)
                }
            } catch {
                let message = error.localizedDescription
                debug(.remoteControl, "SweetMiranda: apply failed — \(message)")
                if case SMError.notAuthenticated = error {
                    await MainActor.run { self.busy = false
                        self.lastError = message }
                    return
                }
                if (error as NSError).domain == "com.apple.LocalAuthentication" {
                    await MainActor.run { self.busy = false
                        self.lastError = SMError.notAuthenticated.localizedDescription }
                    return
                }
                await report(p, status: .failed, message: message, applied: nil)
                markHandled(p.id)
                await MainActor.run {
                    self.busy = false
                    self.lastError = message
                    self.clearPending(p)
                }
            }
        }
    }

    @MainActor private func clearPending(_ p: SMProposal) {
        if pending?.id == p.id { pending = nil
            pendingLines = [] }
        router.mainSecondaryModalView.send(nil)
        sheetShown = false
        checkNow()
    }

    private func markHandled(_ id: String) {
        var ids = handledIds
        ids.append(id)
        if ids.count > 60 { ids.removeFirst(ids.count - 60) }
        handledIds = ids
    }

    // MARK: - Applying

    /// Applies in a fixed order: pump limits → basal (pump sync) → ISF/CR/targets → preferences →
    /// Trio settings. Anything the pump refuses throws before a file is touched, so a half-applied
    /// proposal cannot leave the phone in a state the pump disagrees with.
    private func apply(_ changes: [String: Any], current: SweetMirandaSettingsCatalog.Sources) async throws -> [String: Any] {
        var applied: [String: Any] = [:]

        if let newPump = SweetMirandaSettingsCatalog.newPumpSettings(current.pump, changes: changes) {
            let stored = try await syncDeliveryLimits(newPump)
            storage.save(stored, as: OpenAPS.Settings.settings)
            broadcaster.notify(PumpSettingsObserver.self, on: .main) { $0.pumpSettingsDidChange(stored) }
            for (k, v) in changes where k.hasPrefix(SweetMiranda.Key.pumpPrefix) { applied[k] = v }
        }

        if let raw = changes[SweetMiranda.Key.basal] {
            let profile = try SweetMirandaSettingsCatalog.parseBasal(raw, supported: current.supportedBasalRates)
            try await syncBasal(profile)
            storage.save(profile, as: OpenAPS.Settings.basalProfile)
            broadcaster.notify(BasalProfileObserver.self, on: .main) { $0.basalProfileDidChange(profile) }
            applied[SweetMiranda.Key.basal] = raw
        }

        if let raw = changes[SweetMiranda.Key.isf] {
            let profile = try SweetMirandaSettingsCatalog.parseISF(raw)
            storage.save(profile, as: OpenAPS.Settings.insulinSensitivities)
            broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) { $0.insulinSensitivitiesDidChange(profile) }
            applied[SweetMiranda.Key.isf] = raw
        }

        if let raw = changes[SweetMiranda.Key.cr] {
            let profile = try SweetMirandaSettingsCatalog.parseCR(raw)
            storage.save(profile, as: OpenAPS.Settings.carbRatios)
            broadcaster.notify(CarbRatiosObserver.self, on: .main) { $0.carbRatiosDidChange(profile) }
            applied[SweetMiranda.Key.cr] = raw
        }

        if let raw = changes[SweetMiranda.Key.targets] {
            let profile = try SweetMirandaSettingsCatalog.parseTargets(raw)
            storage.save(profile, as: OpenAPS.Settings.bgTargets)
            broadcaster.notify(BGTargetsObserver.self, on: .main) { $0.bgTargetsDidChange(profile) }
            applied[SweetMiranda.Key.targets] = raw
        }

        if changes.keys.contains(where: { $0.hasPrefix(SweetMiranda.Key.prefPrefix) }) {
            let new = try SweetMirandaSettingsCatalog.newPreferences(settingsManager.preferences, changes: changes)
            settingsManager.preferences = new
            for (k, v) in changes where k.hasPrefix(SweetMiranda.Key.prefPrefix) { applied[k] = v }
        }

        if changes.keys.contains(where: { $0.hasPrefix(SweetMiranda.Key.settingsPrefix) }) {
            let new = try SweetMirandaSettingsCatalog.newSettings(settingsManager.settings, changes: changes)
            settingsManager.settings = new
            for (k, v) in changes where k.hasPrefix(SweetMiranda.Key.settingsPrefix) { applied[k] = v }
        }

        if applied.keys
            .contains(where: {
                [SweetMiranda.Key.basal, SweetMiranda.Key.isf, SweetMiranda.Key.cr, SweetMiranda.Key.targets].contains($0) || $0
                    .hasPrefix(SweetMiranda.Key.pumpPrefix) })
        {
            try? await nightscoutManager.uploadProfiles()
        }
        return applied
    }

    private func syncDeliveryLimits(_ settings: PumpSettings) async throws -> PumpSettings {
        guard let pump = deviceManager.pumpManager else { return settings }
        let limits = DeliveryLimits(
            maximumBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(settings.maxBasal)),
            maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: Double(settings.maxBolus))
        )
        return try await withCheckedThrowingContinuation { cont in
            pump.syncDeliveryLimits(limits: limits) { result in
                switch result {
                case let .success(actual):
                    cont.resume(returning: PumpSettings(
                        insulinActionCurve: settings.insulinActionCurve,
                        maxBolus: Decimal(
                            actual.maximumBolus?
                                .doubleValue(for: .internationalUnit()) ?? Double(settings.maxBolus)
                        ),
                        maxBasal: Decimal(
                            actual.maximumBasalRate?
                                .doubleValue(for: .internationalUnitsPerHour) ?? Double(settings.maxBasal)
                        )
                    ))
                case let .failure(error):
                    cont
                        .resume(
                            throwing: SMError
                                .pumpUnavailable("The pump refused the new limits: \(error.localizedDescription)")
                        )
                }
            }
        }
    }

    private func syncBasal(_ profile: [BasalProfileEntry]) async throws {
        guard let pump = deviceManager.pumpManager else {
            throw SMError.pumpUnavailable("No pump is connected, so the basal schedule cannot be changed")
        }
        let items = profile.map { RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate)) }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pump.syncBasalRateSchedule(items: items) { result in
                switch result {
                case .success: cont.resume()
                case let .failure(error): cont
                    .resume(
                        throwing: SMError
                            .pumpUnavailable("The pump refused the basal schedule: \(error.localizedDescription)")
                    )
                }
            }
        }
    }

    // MARK: - Reporting

    private func report(
        _ p: SMProposal,
        status: SweetMiranda.Status,
        message: String,
        applied: [String: Any]?,
        hash: String = ""
    ) async {
        var doc: [String: Any] = [
            "eventType": SweetMiranda.eventType,
            "enteredBy": NightscoutTreatment.local,
            "created_at": SMDates.string(Date()),
            "smKind": SweetMiranda.Kind.result.rawValue,
            "smId": p.id,
            "smStatus": status.rawValue,
            "smMessage": message,
            "notes": "Sweet Miranda settings \(status.rawValue)"
        ]
        if let applied { doc["smApplied"] = applied }
        if !hash.isEmpty { doc["smSnapshotHash"] = hash }
        if let ns = p.nsId { doc["smProposalNsId"] = ns }
        let ok = await nightscoutManager.sweetMirandaUpload(document: doc)
        debug(.remoteControl, "SweetMiranda: result \(status.rawValue) for \(p.id) uploaded=\(ok) — \(message)")
    }

    // MARK: - Snapshots out

    func uploadSnapshotIfChanged(force: Bool) {
        guard started else { return }
        snapshotDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let doc = try SweetMirandaSettingsCatalog.snapshot(self.sources())
                    let hash = SweetMirandaSettingsCatalog.hash(of: doc)
                    let stale = Date().timeIntervalSince(self.lastSnapshotAt) > 12 * 3600
                    guard force || hash != self.lastSnapshotHash || stale else { return }
                    var out: [String: Any] = [
                        "eventType": SweetMiranda.eventType,
                        "enteredBy": NightscoutTreatment.local,
                        "created_at": SMDates.string(Date()),
                        "smKind": SweetMiranda.Kind.snapshot.rawValue,
                        "smHash": hash,
                        "smSettings": doc,
                        "notes": "Sweet Miranda settings snapshot"
                    ]
                    out["smApp"] = doc["app"]
                    if await self.nightscoutManager.sweetMirandaUpload(document: out) {
                        self.lastSnapshotHash = hash
                        self.lastSnapshotAt = Date()
                        debug(.remoteControl, "SweetMiranda: snapshot \(hash.prefix(10)) uploaded")
                    }
                } catch {
                    debug(.remoteControl, "SweetMiranda: snapshot failed \(error)")
                }
            }
        }
        snapshotDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (force ? 0.5 : 10), execute: work)
    }

    private func sources() -> SweetMirandaSettingsCatalog.Sources {
        SweetMirandaSettingsCatalog.Sources(
            preferences: settingsManager.preferences,
            settings: settingsManager.settings,
            pump: settingsManager.pumpSettings,
            basal: storage.retrieve(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? [],
            isf: storage.retrieve(OpenAPS.Settings.insulinSensitivities, as: InsulinSensitivities.self)
                ?? InsulinSensitivities(units: .mgdL, userPreferredUnits: .mgdL, sensitivities: []),
            cr: storage.retrieve(OpenAPS.Settings.carbRatios, as: CarbRatios.self) ?? CarbRatios(units: .grams, schedule: []),
            targets: storage.retrieve(OpenAPS.Settings.bgTargets, as: BGTargets.self)
                ?? BGTargets(units: .mgdL, userPreferredUnits: .mgdL, targets: []),
            pumpName: deviceManager.pumpName.value,
            supportedBasalRates: deviceManager.pumpManager?.supportedBasalRates.filter { $0 > 0 }.map { Decimal($0) },
            remoteControlEnabled: UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled")
        )
    }
}

// MARK: - Change observers → snapshot

extension BaseSweetMirandaSyncManager: SettingsObserver, PreferencesObserver, BasalProfileObserver,
    InsulinSensitivitiesObserver, CarbRatiosObserver, BGTargetsObserver, PumpSettingsObserver
{
    func settingsDidChange(_: TrioSettings) { uploadSnapshotIfChanged(force: false) }
    func preferencesDidChange(_: Preferences) { uploadSnapshotIfChanged(force: false) }
    func basalProfileDidChange(_: [BasalProfileEntry]) { uploadSnapshotIfChanged(force: false) }
    func insulinSensitivitiesDidChange(_: InsulinSensitivities) { uploadSnapshotIfChanged(force: false) }
    func carbRatiosDidChange(_: CarbRatios) { uploadSnapshotIfChanged(force: false) }
    func bgTargetsDidChange(_: BGTargets) { uploadSnapshotIfChanged(force: false) }
    func pumpSettingsDidChange(_: PumpSettings) { uploadSnapshotIfChanged(force: false) }
}
