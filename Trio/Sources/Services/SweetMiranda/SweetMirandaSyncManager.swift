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
/// Nightscout for pending proposals. A proposal signed with Face ID on a registered approver's
/// own phone (LoopFollow) is applied without the sheet; approver changes never are. A new one raises a local notification and, when the app
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
    @Injected() private var glucoseStorage: GlucoseStorage!

    @Published private(set) var pending: SMProposal?
    @Published private(set) var pendingLines: [SMChangeLine] = []
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private let foregroundPoll: TimeInterval = 300
    /// In the background the loop fires this after every cycle; never ask Nightscout more often than this.
    private let backgroundMinInterval: TimeInterval = 240
    private var lastCheckAt: Date = .distantPast
    private var pollTimer: Timer?
    private var snapshotDebounce: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var checking = false
    private var sheetShown = false

    @Persisted(key: "SweetMiranda.lastSnapshotHash") private var lastSnapshotHash: String = ""
    @Persisted(key: "SweetMiranda.lastSnapshotAt") private var lastSnapshotAt: Date = .distantPast
    @Persisted(key: "SweetMiranda.handledProposalIds") private var handledIds: [String] = []
    /// Set right before a proposal is applied and cleared right after (success or error). If Trio starts
    /// and finds it still set, the previous run ended while applying: a crash. That proposal is then
    /// reported failed and never retried, so one bad proposal can never stop the loop twice (2026-09-28:
    /// Trio crashed applying an approved proposal, then again on every relaunch).
    @Persisted(key: "SweetMiranda.applyingProposalId") private var applyingId: String = ""
    @Persisted(key: "SweetMiranda.applyingKeys") private var applyingKeys: String = ""
    /// Loop date at the last applied proposal; the next remote approval waits for a newer loop cycle.
    @Persisted(key: "SweetMiranda.lastApplyLoopDate") private var lastApplyLoopDate: Date = .distantPast
    /// The values a loop-relevant proposal replaced (JSON of `SMRollbackRecord`), kept until Trio's loop
    /// has run with the new ones. If the loop fails with them, they are put back (once).
    @Persisted(key: "SweetMiranda.rollbackRecord") private var rollbackJSON: String = ""
    /// How long after an apply a successful loop cycle must happen before the change is rolled back.
    private static let rollbackWindow: TimeInterval = 12 * 60
    private var rollbackTimer: Timer?
    /// A loop cycle started after the last apply finished (after a relaunch every new cycle is later).
    private var loopStartedSinceApply = false
    private var rollingBack = false
    /// Set by `apply` once it has written something (so a failed apply knows whether to watch).
    private var applyWrote = false

    /// Caregivers' phones whose Face ID may approve proposals. Changed only on this phone.
    @Persisted(key: "SweetMiranda.approvers") private(set) var approvers: [SMApprover] = []

    /// For the Settings row that lists and removes approvers (the manager is a container singleton).
    private(set) weak static var current: BaseSweetMirandaSyncManager?

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Self.current = self
        let interruptedId = recoverInterruptedApply()
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
            .sink { [weak self] date in
                self?.watchLoopSucceeded(at: date)
                self?.checkNow()
            }
            .store(in: &subscriptions)

        // the rollback watch: which loop cycles ran after the last apply, and how they ended
        apsManager.isLooping
            .receive(on: DispatchQueue.main)
            .sink { [weak self] looping in if looping { self?.watchLoopStarted() } }
            .store(in: &subscriptions)
        apsManager.lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in if let error { self?.watchLoopFailed(error) } }
            .store(in: &subscriptions)

        // Dream Mode resumes insulin on time. A paused pod stops loop cycles, so this rides on every
        // new G6 reading instead — it keeps arriving every 5 min with the phone locked.
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.tickDreamMode()
                self?.checkRollbackDeadline()
            }
            .store(in: &subscriptions)

        DispatchQueue.main.async { [weak self] in
            self?.resumeRollbackWatch(interruptedId: interruptedId)
            self?.repairInvalidDIA()
        }

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

    /// Runs first thing at start: a marker left behind means the last run died mid-apply.
    /// Returns the id of that proposal (it has been reported), or nil.
    @discardableResult private func recoverInterruptedApply() -> String? {
        let id = applyingId
        guard !id.isEmpty else { return nil }
        let keys = applyingKeys
        // clear and remember BEFORE any network, so even if reporting fails it is never retried
        applyingId = ""
        applyingKeys = ""
        markHandled(id)
        UserDefaults.standard.synchronize()
        debug(.remoteControl, "SweetMiranda: Trio stopped while applying \(id) (\(keys)), reported failed, not retried")
        Task { await self.reportInterrupted(id: id, keys: keys) }
        return id
    }

    func applicationBecameActive() {
        checkNow()
        tickDreamMode()
        checkRollbackDeadline()
        Task { @MainActor in self.presentPendingIfNeeded() }
    }

    private func tickDreamMode() {
        guard SweetMirandaDreamMode.shared.isOn else { return }
        Task { @MainActor in await SweetMirandaDreamMode.shared.tick(apsManager: self.apsManager) }
    }

    // MARK: - Proposals in

    /// Always called on the main thread (loop subject is received on main, timer and lifecycle are main).
    func checkNow() {
        guard started, !checking else { return }
        let inBackground = UIApplication.shared.applicationState != .active
        if inBackground, Date().timeIntervalSince(lastCheckAt) < backgroundMinInterval { return }
        checking = true
        lastCheckAt = Date()
        // Ask iOS for time to finish the request; if it runs out, end quietly — the loop must never wait on us.
        let bgTask = SMBackgroundTask(name: "SweetMiranda.check")
        Task { [weak self] in
            guard let self else { bgTask.end()
                return }
            defer {
                DispatchQueue.main.async { self.checking = false }
                bgTask.end()
            }
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
            // Face ID on a registered approver's own phone counts as approval — never for approver changes.
            if !next.touchesApprovers, !self.approvers.isEmpty {
                for doc in await self.nightscoutManager.sweetMirandaFetchApprovals(proposalId: next.id) {
                    guard let approval = SMApproval(document: doc) else { continue }
                    if let who = SMApprovers.verify(approval, for: next, approvers: self.approvers) {
                        if let why = await MainActor.run(body: { self.notReadyToApply(next) }) {
                            debug(.remoteControl, "SweetMiranda: approved \(next.id) waits: \(why)")
                            return
                        }
                        await self.applyRemote(next, by: who)
                        return
                    }
                    debug(.remoteControl, "SweetMiranda: ignored an approval for \(next.id) that did not verify")
                }
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
                // 2 + 3. re-validate against what the phone runs NOW, apply pump first
                let (applied, _) = try await applyValidated(p)
                // 4. tell everyone
                await finishApplied(p, applied: applied, message: "Applied on the phone after Face ID")
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
                // not now: nothing changed, the proposal stays open to approve again in a few minutes
                if case SMError.notYet = error {
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
        if sheetShown { router.mainSecondaryModalView.send(nil) }
        sheetShown = false
        checkNow()
    }

    // MARK: - Approved elsewhere / approvers

    /// Re-validates against what the phone runs NOW (it may have changed since the proposal was
    /// written) and applies, pump first. Returns what was applied and the human lines.
    @MainActor private func applyValidated(_ p: SMProposal) async throws -> ([String: Any], [SMChangeLine]) {
        // one change at a time: the last one must first be seen working in a loop cycle (or be rolled back)
        if rollbackRecord != nil {
            throw SMError.notYet(
                "Trio's loop has not run yet with the last settings change. Nothing was changed; try again in a few minutes."
            )
        }
        // never write to the pump while a loop cycle is using it (waits at most 60 s)
        var waited = 0
        while apsManager.isLooping.value, waited < 60 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 2
        }
        let current = loopSources()
        // catalog + Trio's own loop preflight, on the same parsed values that get written
        let (lines, parsed) = try checkProposal(p, current: current)
        // before any write: what these changes replace, so they can be put back if the loop fails with them
        if SweetMirandaSettingsCatalog.touchesLoop(p.changes) {
            rollbackRecord = try SMRollbackRecord(capturing: p, from: current)
        }
        applyingKeys = p.changes.keys.sorted().joined(separator: ", ")
        applyingId = p.id
        UserDefaults.standard.synchronize()
        defer {
            applyingId = ""
            applyingKeys = ""
        }
        applyWrote = false
        do {
            let applied = try await apply(parsed, changes: p.changes)
            armRollbackWatch()
            lastApplyLoopDate = apsManager.lastLoopDate
            return (applied, lines)
        } catch {
            // the pump refused part of it: whatever did get written is watched like a full apply
            if applyWrote { armRollbackWatch() } else { rollbackRecord = nil }
            throw error
        }
    }

    /// Everything a proposal must pass before a single write, against the settings the phone has now:
    /// the catalog (allow-list, bounds, cross-field rules), then — if it touches anything the loop
    /// reads — Trio's own profile builder on the would-be settings. Returns the approval-sheet lines
    /// and the parsed values that `apply` writes.
    @MainActor private func checkProposal(
        _ p: SMProposal,
        current: SweetMirandaSettingsCatalog.Sources
    ) throws -> ([SMChangeLine], SweetMirandaSettingsCatalog.Parsed) {
        let lines = try SweetMirandaSettingsCatalog.validate(changes: p.changes, against: current)
        let parsed = try SweetMirandaSettingsCatalog.parse(changes: p.changes, current: current)
        if SweetMirandaSettingsCatalog.touchesLoop(p.changes) {
            try SweetMirandaSettingsCatalog.preflight(parsed, current: current)
        }
        return (lines, parsed)
    }

    /// Remote approvals apply only in a quiet moment, one per loop cycle. nil = ready, else the reason to wait.
    @MainActor private func notReadyToApply(_ p: SMProposal) -> String? {
        if apsManager.isLooping.value { return "a loop cycle is running" }
        if rollbackRecord != nil { return "Trio's loop has not run yet with the last change" }
        guard let pump = deviceManager.pumpManager else { return "no pump connected" }
        if case .noBolus = pump.status.bolusState {} else { return "a bolus is running" }
        if SweetMirandaDreamMode.shared.isOn { return "Dream Mode has the pod paused" }
        let last = apsManager.lastLoopDate
        if Date().timeIntervalSince(last) <= 6 * 60 {
            if last <= lastApplyLoopDate { return "waiting for a loop cycle after the last change" }
            return nil
        }
        // The loop is down. A change may still go ahead when Trio's loop would accept the settings it
        // leaves behind — that is how a fix for a broken loop gets in (2026-09-28: DIA 3 stopped every
        // loop, and waiting for a completed loop meant no fix could ever be applied remotely).
        let current = loopSources()
        do {
            let parsed = try SweetMirandaSettingsCatalog.parse(changes: p.changes, current: current)
            if let why = SweetMirandaSettingsCatalog.loopProblem(parsed, current: current) {
                return "no completed loop cycle in the last 6 min, and Trio's loop would still refuse the settings: \(why)"
            }
            return nil
        } catch {
            return "no completed loop cycle in the last 6 min, and the proposal does not parse: \(error.localizedDescription)"
        }
    }

    /// Fresh snapshot, the result for the dashboard, a note in Nightscout.
    @MainActor private func finishApplied(_ p: SMProposal, applied: [String: Any], message: String) async {
        uploadSnapshotIfChanged(force: true)
        let hash = (try? SweetMirandaSettingsCatalog.hash(of: SweetMirandaSettingsCatalog.snapshot(sources()))) ?? ""
        await report(p, status: .applied, message: message, applied: applied, hash: hash)
        markHandled(p.id)
        await nightscoutManager
            .uploadNoteTreatment(note: "Sweet Miranda settings applied: \(applied.keys.sorted().joined(separator: ", "))")
    }

    /// A registered approver signed exactly this proposal with Face ID on their own phone.
    @MainActor private func applyRemote(_ p: SMProposal, by approver: SMApprover) async {
        guard !busy, !handledIds.contains(p.id) else { return }
        busy = true
        defer { busy = false }
        do {
            let (applied, lines) = try await applyValidated(p)
            await finishApplied(p, applied: applied, message: "Applied after Face ID on \(approver.name)")
            notifyApplied(by: approver, lines: lines)
        } catch {
            let message = error.localizedDescription
            debug(.remoteControl, "SweetMiranda: approved on \(approver.name) but not applied — \(message)")
            if case SMError.notYet = error { return } // nothing changed; checked again after the next loop cycle
            await report(p, status: .failed, message: "Approved on \(approver.name) but not applied: \(message)", applied: nil)
            markHandled(p.id)
        }
        clearPending(p)
    }

    /// So the person holding this phone always knows her settings changed, and who approved it.
    private func notifyApplied(by approver: SMApprover, lines: [SMChangeLine]) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your settings were updated")
        content.body = "\(approver.name) approved with Face ID: " + lines.map(\.label).joined(separator: ", ")
        content.sound = .default
        let req = UNNotificationRequest(identifier: "SweetMiranda.applied.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            if let error { debug(.remoteControl, "SweetMiranda: notification failed \(error)") }
        }
    }

    /// Removes an approver from this phone right away (e.g. a lost phone). Needs this phone's owner.
    @MainActor func removeApprover(_ keyId: String) async -> Bool {
        do {
            guard try await unlockManager.unlock() else { return false }
        } catch { return false }
        guard let gone = approvers.first(where: { $0.keyId == keyId }) else { return false }
        approvers = approvers.filter { $0.keyId != keyId }
        objectWillChange.send()
        uploadSnapshotIfChanged(force: true)
        await nightscoutManager.uploadNoteTreatment(note: "Sweet Miranda approver removed on the phone: \(gone.name)")
        return true
    }

    private func markHandled(_ id: String) {
        var ids = handledIds
        ids.append(id)
        if ids.count > 60 { ids.removeFirst(ids.count - 60) }
        handledIds = ids
    }

    // MARK: - Applying

    /// Writes the parsed values in a fixed order: pump limits → basal (pump sync) → ISF/CR/targets →
    /// preferences → Trio settings. Anything the pump refuses throws before a file is touched, so a
    /// half-applied proposal cannot leave the phone in a state the pump disagrees with. `changes` only
    /// names what is reported as applied (and carries approver changes); the values come from `parsed`,
    /// the same ones the loop preflight checked. A rollback comes through here too.
    @MainActor private func apply(
        _ parsed: SweetMirandaSettingsCatalog.Parsed,
        changes: [String: Any]
    ) async throws -> [String: Any] {
        var applied: [String: Any] = [:]

        if let newPump = parsed.pump {
            let stored = try await syncDeliveryLimits(newPump)
            storage.save(stored, as: OpenAPS.Settings.settings)
            applyWrote = true
            broadcaster.notify(PumpSettingsObserver.self, on: .main) { $0.pumpSettingsDidChange(stored) }
            for (k, v) in changes where k.hasPrefix(SweetMiranda.Key.pumpPrefix) { applied[k] = v }
        }

        if let profile = parsed.basal {
            try await syncBasal(profile)
            storage.save(profile, as: OpenAPS.Settings.basalProfile)
            applyWrote = true
            broadcaster.notify(BasalProfileObserver.self, on: .main) { $0.basalProfileDidChange(profile) }
            applied[SweetMiranda.Key.basal] = changes[SweetMiranda.Key.basal] ?? "restored"
        }

        if let profile = parsed.isf {
            storage.save(profile, as: OpenAPS.Settings.insulinSensitivities)
            applyWrote = true
            broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) { $0.insulinSensitivitiesDidChange(profile) }
            applied[SweetMiranda.Key.isf] = changes[SweetMiranda.Key.isf] ?? "restored"
        }

        if let profile = parsed.cr {
            storage.save(profile, as: OpenAPS.Settings.carbRatios)
            applyWrote = true
            broadcaster.notify(CarbRatiosObserver.self, on: .main) { $0.carbRatiosDidChange(profile) }
            applied[SweetMiranda.Key.cr] = changes[SweetMiranda.Key.cr] ?? "restored"
        }

        if let profile = parsed.targets {
            storage.save(profile, as: OpenAPS.Settings.bgTargets)
            applyWrote = true
            broadcaster.notify(BGTargetsObserver.self, on: .main) { $0.bgTargetsDidChange(profile) }
            applied[SweetMiranda.Key.targets] = changes[SweetMiranda.Key.targets] ?? "restored"
        }

        if let new = parsed.preferences {
            settingsManager.preferences = new
            applyWrote = true
            for (k, v) in changes where k.hasPrefix(SweetMiranda.Key.prefPrefix) { applied[k] = v }
        }

        if let new = parsed.settings {
            settingsManager.settings = new
            applyWrote = true
            for (k, v) in changes where k.hasPrefix(SweetMiranda.Key.settingsPrefix) { applied[k] = v }
        }

        // Approvers last: only once every setting in the proposal went through.
        if let raw = changes[SweetMiranda.Key.approverAdd] {
            let a = try SMApprovers.parseAdd(raw)
            approvers = approvers.filter { $0.keyId != a.keyId } + [a]
            applied[SweetMiranda.Key.approverAdd] = ["keyId": a.keyId, "name": a.name]
        }
        if let keyId = changes[SweetMiranda.Key.approverRemove] as? String {
            approvers = approvers.filter { $0.keyId != keyId }
            applied[SweetMiranda.Key.approverRemove] = keyId
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

    @MainActor private func syncDeliveryLimits(_ settings: PumpSettings) async throws -> PumpSettings {
        guard let pump = deviceManager.pumpManager else { return settings }
        let limits = DeliveryLimits(
            maximumBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: Double(settings.maxBasal)),
            maximumBolus: HKQuantity(unit: .internationalUnit(), doubleValue: Double(settings.maxBolus))
        )
        return try await Self.pumpAnswer("delivery limits") { (cont: SMOnceContinuation<PumpSettings>) in
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

    @MainActor private func syncBasal(_ profile: [BasalProfileEntry]) async throws {
        guard let pump = deviceManager.pumpManager else {
            throw SMError.pumpUnavailable("No pump is connected, so the basal schedule cannot be changed")
        }
        let items = profile.map { RepeatingScheduleValue(startTime: TimeInterval($0.minutes * 60), value: Double($0.rate)) }
        try await Self.pumpAnswer("basal schedule") { (cont: SMOnceContinuation<Void>) in
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

    /// Bridges a pump callback into async code. A second answer from the pump is logged and ignored
    /// instead of crashing the app (a checked continuation resumed twice is a fatal error).
    private static func pumpAnswer<T>(
        _ what: String,
        _ body: (SMOnceContinuation<T>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            body(SMOnceContinuation(cont, what: what))
        }
    }

    // MARK: - Rollback when Trio's loop fails with new settings

    /// The persisted record of what the last loop-relevant apply replaced, or nil.
    private var rollbackRecord: SMRollbackRecord? {
        get {
            guard !rollbackJSON.isEmpty, let data = rollbackJSON.data(using: .utf8) else { return nil }
            do {
                return try JSONCoding.decoder.decode(SMRollbackRecord.self, from: data)
            } catch {
                debug(.remoteControl, "SweetMiranda: unreadable rollback record dropped — \(error)")
                rollbackJSON = ""
                return nil
            }
        }
        set {
            if let newValue {
                do {
                    let data = try JSONCoding.encoder.encode(newValue)
                    rollbackJSON = String(data: data, encoding: .utf8) ?? ""
                } catch {
                    debug(.remoteControl, "SweetMiranda: could not keep the rollback record — \(error)")
                    rollbackJSON = ""
                }
            } else {
                rollbackJSON = ""
            }
            UserDefaults.standard.synchronize()
        }
    }

    /// Starts watching the loop once every write of an apply is done. Main thread.
    private func armRollbackWatch() {
        guard var r = rollbackRecord else { return }
        let now = Date()
        let deadline = now.addingTimeInterval(Self.rollbackWindow)
        r.appliedAt = now
        r.deadline = deadline
        rollbackRecord = r
        loopStartedSinceApply = false
        scheduleRollbackCheck(at: deadline)
        debug(.remoteControl, "SweetMiranda: watching the loop with \(r.keys.joined(separator: ", ")) until \(deadline)")
    }

    private func scheduleRollbackCheck(at date: Date) {
        rollbackTimer?.invalidate()
        rollbackTimer = Timer
            .scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in
                self?.checkRollbackDeadline()
            }
    }

    /// Main thread. A loop cycle began after the apply finished, so it runs with the new settings.
    private func watchLoopStarted() {
        guard let r = rollbackRecord, let at = r.appliedAt, !r.rollbackStarted, Date() > at else { return }
        loopStartedSinceApply = true
    }

    /// Main thread. A loop cycle that started after the apply succeeded: the new settings work, keep them.
    private func watchLoopSucceeded(at date: Date) {
        guard let r = rollbackRecord, let at = r.appliedAt, !r.rollbackStarted, !rollingBack,
              loopStartedSinceApply, date > at else { return }
        rollbackRecord = nil
        rollbackTimer?.invalidate()
        debug(.remoteControl, "SweetMiranda: loop succeeded with \(r.keys.joined(separator: ", ")), change kept")
    }

    /// Main thread. Trio's algorithm refused to run in a loop cycle with the new settings: put the old
    /// ones back now. Other loop errors (pump out of reach, stale glucose, a manual temp basal) say
    /// nothing about the settings; if they last, the 12-minute deadline rolls back anyway.
    private func watchLoopFailed(_ error: Error) {
        guard let r = rollbackRecord, r.appliedAt != nil, !r.rollbackStarted, !rollingBack,
              loopStartedSinceApply, let why = Self.algorithmRefusal(error) else { return }
        Task { @MainActor in await self.rollBack(reason: why) }
    }

    /// The algorithm's words when a loop error came from determining basal (profile, IOB, autosens,
    /// determination), nil for pump, glucose and other loop errors.
    static func algorithmRefusal(_ error: Error) -> String? {
        if case let APSError.apsError(message) = error, message.hasPrefix("Error determining basal") { return message }
        return nil
    }

    /// Main thread. Rolls back when no loop cycle has succeeded by the deadline.
    private func checkRollbackDeadline() {
        guard started, var r = rollbackRecord, r.appliedAt != nil, !r.rollbackStarted, !rollingBack,
              let deadline = r.deadline else { return }
        // A paused pod (Dream Mode, a suspend) stops loop cycles on purpose: the 12 minutes restart after it resumes.
        if SweetMirandaDreamMode.shared.isOn || apsManager.isSuspended {
            let later = Date().addingTimeInterval(Self.rollbackWindow)
            if later > deadline {
                r.deadline = later
                rollbackRecord = r
                scheduleRollbackCheck(at: later)
            }
            return
        }
        guard Date() >= deadline else {
            if rollbackTimer?.isValid != true { scheduleRollbackCheck(at: deadline) }
            return
        }
        let last = apsManager.lastError.value.map { Self.algorithmRefusal($0) ?? $0.localizedDescription }
        let why = "no loop cycle succeeded within 12 minutes" + (last.map { "; last error: \($0)" } ?? "")
        Task { @MainActor in await self.rollBack(reason: why) }
    }

    /// Puts back what the proposal replaced, through the same apply path (pump first). Tried at most
    /// once per proposal: the record is marked before anything is written and dropped afterwards,
    /// whatever happens. Never puts back settings Trio's loop would refuse as well.
    @MainActor private func rollBack(reason: String) async {
        guard var r = rollbackRecord, r.appliedAt != nil, !r.rollbackStarted, !rollingBack else { return }
        rollingBack = true
        defer { rollingBack = false }
        r.rollbackStarted = true
        rollbackRecord = r
        rollbackTimer?.invalidate()
        let keys = r.keys.joined(separator: ", ")
        debug(.remoteControl, "SweetMiranda: rolling back \(r.proposalId) (\(keys)) — \(reason)")

        var waited = 0
        while apsManager.isLooping.value, waited < 60 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 2
        }
        let current = loopSources()
        let message: String
        do {
            let previous = try r.previousValues(current: current)
            if let why = SweetMirandaSettingsCatalog.loopProblem(previous, current: current) {
                // e.g. the change repaired a broken loop and something else keeps it down
                message = "Not rolled back: Trio's loop failed after these settings (\(reason)), but the settings " +
                    "from before would not run it either (\(why)). Check Trio on her phone."
            } else {
                applyingKeys = "rollback of " + keys
                applyingId = r.proposalId
                UserDefaults.standard.synchronize()
                defer {
                    applyingId = ""
                    applyingKeys = ""
                }
                _ = try await apply(previous, changes: r.restoredChanges)
                message = "Rolled back: Trio's loop failed after these settings (\(reason))"
            }
        } catch {
            message = "Trio's loop failed after these settings (\(reason)) and putting the previous ones back failed: " +
                "\(error.localizedDescription). The new settings are still in place — check Trio on her phone."
        }
        rollbackRecord = nil
        debug(.remoteControl, "SweetMiranda: \(message)")
        uploadSnapshotIfChanged(force: true)
        await reportResult(id: r.proposalId, nsId: r.proposalNsId, status: .failed, message: message, applied: nil)
        await nightscoutManager.uploadNoteTreatment(note: "Sweet Miranda (\(keys)): \(message)")
    }

    /// Main thread, at start: picks the watch up again after Trio stopped.
    private func resumeRollbackWatch(interruptedId: String?) {
        guard var r = rollbackRecord else { return }
        let keys = r.keys.joined(separator: ", ")
        if r.rollbackStarted {
            // Trio stopped during the rollback: never tried again
            rollbackRecord = nil
            debug(.remoteControl, "SweetMiranda: Trio stopped while rolling back \(r.proposalId), not tried again")
            if interruptedId != r.proposalId {
                Task {
                    await self.reportResult(
                        id: r.proposalId,
                        nsId: r.proposalNsId,
                        status: .failed,
                        message: "Trio stopped while rolling back these settings (\(keys)). It was not tried again; " +
                            "check Trio on her phone.",
                        applied: nil
                    )
                }
            }
            return
        }
        guard let appliedAt = r.appliedAt else {
            // Trio stopped while applying (reported by recoverInterruptedApply): watch whatever got written
            armRollbackWatch()
            return
        }
        if apsManager.lastLoopDate > appliedAt {
            rollbackRecord = nil
            debug(.remoteControl, "SweetMiranda: a loop succeeded with \(keys) before Trio stopped, change kept")
            return
        }
        // still pending: roll back at the deadline, or shortly after launch if it has passed
        let at = max(r.deadline ?? Date(), Date().addingTimeInterval(30))
        r.deadline = at
        rollbackRecord = r
        scheduleRollbackCheck(at: at)
    }

    // MARK: - Startup repair

    /// Trio's loop refuses a duration of insulin action under 5 h (`ProfileGenerator`), so with one stored
    /// no loop can run at all (2026-09-28: a proposal set 3 h). Sets it to 5 h, the lowest Trio accepts,
    /// the same way Trio's pump settings editor saves it. Only the DIA; nothing if it is 5 h or more. Main thread.
    private func repairInvalidDIA() {
        let pump = settingsManager.pumpSettings
        guard pump.insulinActionCurve < 5 else { return }
        let hours = SweetMirandaSettingsCatalog.show(NSNumber(value: SweetMirandaSettingsCatalog.dbl(pump.insulinActionCurve)))
        let fixed = PumpSettings(insulinActionCurve: 5, maxBolus: pump.maxBolus, maxBasal: pump.maxBasal)
        storage.save(fixed, as: OpenAPS.Settings.settings)
        broadcaster.notify(PumpSettingsObserver.self, on: .main) { $0.pumpSettingsDidChange(fixed) }
        let note =
            "Sweet Miranda: duration of insulin action was \(hours) h, below Trio's 5 h minimum — set to 5 h so the loop can run"
        debug(.remoteControl, note)
        uploadSnapshotIfChanged(force: true)
        Task { await self.nightscoutManager.uploadNoteTreatment(note: note) }
    }

    // MARK: - Reporting

    /// The result for a proposal whose apply was cut short by Trio stopping (found at the next start).
    private func reportInterrupted(id: String, keys: String) async {
        let doc: [String: Any] = [
            "eventType": SweetMiranda.eventType,
            "enteredBy": NightscoutTreatment.local,
            "created_at": SMDates.string(Date()),
            "smKind": SweetMiranda.Kind.result.rawValue,
            "smId": id,
            "smStatus": SweetMiranda.Status.failed.rawValue,
            "smMessage": "Trio stopped while applying these settings (\(keys)). It was not tried again. " +
                "Some of them may already be in place, so check Trio on her phone before sending them again.",
            "notes": "Sweet Miranda settings failed"
        ]
        let ok = await nightscoutManager.sweetMirandaUpload(document: doc)
        debug(.remoteControl, "SweetMiranda: interrupted-apply result for \(id) uploaded=\(ok)")
    }

    private func report(
        _ p: SMProposal,
        status: SweetMiranda.Status,
        message: String,
        applied: [String: Any]?,
        hash: String = ""
    ) async {
        await reportResult(id: p.id, nsId: p.nsId, status: status, message: message, applied: applied, hash: hash)
    }

    private func reportResult(
        id: String,
        nsId: String?,
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
            "smId": id,
            "smStatus": status.rawValue,
            "smMessage": message,
            "notes": "Sweet Miranda settings \(status.rawValue)"
        ]
        if let applied { doc["smApplied"] = applied }
        if !hash.isEmpty { doc["smSnapshotHash"] = hash }
        if let ns = nsId { doc["smProposalNsId"] = ns }
        let ok = await nightscoutManager.sweetMirandaUpload(document: doc)
        debug(.remoteControl, "SweetMiranda: result \(status.rawValue) for \(id) uploaded=\(ok) — \(message)")
    }

    // MARK: - Snapshots out

    func uploadSnapshotIfChanged(force: Bool) {
        guard started else { return }
        snapshotDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let bgTask = SMBackgroundTask(name: "SweetMiranda.snapshot")
            Task {
                defer { bgTask.end() }
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
            remoteControlEnabled: UserDefaults.standard.bool(forKey: "isTrioRemoteControlEnabled"),
            approvers: approvers,
            podKeepAlive: SweetMirandaPodKeepAlive.name(deviceManager.pumpManager)
        )
    }

    /// `sources()` the way the loop reads them (`OpenAPS.createProfiles`): a schedule with no file yet
    /// falls back to Trio's bundled default, so the preflight checks exactly what the loop would get.
    private func loopSources() -> SweetMirandaSettingsCatalog.Sources {
        let s = sources()
        func stored<T: JSON>(_ file: String, _: T.Type) -> T? {
            storage.retrieve(file, as: T.self) ?? T(from: OpenAPS.defaults(for: file))
        }
        return SweetMirandaSettingsCatalog.Sources(
            preferences: s.preferences,
            settings: s.settings,
            pump: s.pump,
            basal: stored(OpenAPS.Settings.basalProfile, [BasalProfileEntry].self) ?? s.basal,
            isf: stored(OpenAPS.Settings.insulinSensitivities, InsulinSensitivities.self) ?? s.isf,
            cr: stored(OpenAPS.Settings.carbRatios, CarbRatios.self) ?? s.cr,
            targets: stored(OpenAPS.Settings.bgTargets, BGTargets.self) ?? s.targets,
            pumpName: s.pumpName,
            supportedBasalRates: s.supportedBasalRates,
            remoteControlEnabled: s.remoteControlEnabled,
            approvers: s.approvers,
            podKeepAlive: s.podKeepAlive
        )
    }
}

// MARK: - Rollback record

/// What a loop-relevant proposal replaced, kept in UserDefaults until Trio's loop has run with the new
/// values. Scalars are the previous values in the proposal's own shape (`pref.` / `settings.` / `pump.`
/// keys, JSON); schedules are the previous schedules exactly as they were stored.
struct SMRollbackRecord: Codable {
    let proposalId: String
    let proposalNsId: String?
    let keys: [String]
    let scalarsJSON: String
    let basal: [BasalProfileEntry]?
    let isf: InsulinSensitivities?
    let cr: CarbRatios?
    let targets: BGTargets?
    /// nil while the apply is under way; set once every write is done
    var appliedAt: Date?
    var deadline: Date?
    /// set before a rollback writes anything: a proposal is rolled back at most once
    var rollbackStarted: Bool

    init(capturing p: SMProposal, from current: SweetMirandaSettingsCatalog.Sources) throws {
        let prefNow = try SweetMirandaSettingsCatalog.jsonObject(current.preferences)
        let setNow = try SweetMirandaSettingsCatalog.jsonObject(current.settings)
        let pumpNow = try SweetMirandaSettingsCatalog.jsonObject(current.pump)
        var scalars: [String: Any] = [:]
        for key in p.changes.keys {
            for (prefix, now) in [
                (SweetMiranda.Key.prefPrefix, prefNow),
                (SweetMiranda.Key.settingsPrefix, setNow),
                (SweetMiranda.Key.pumpPrefix, pumpNow)
            ] where key.hasPrefix(prefix) {
                guard let old = now[String(key.dropFirst(prefix.count))] else {
                    throw SMError.invalid("Could not read the current value of \(key)")
                }
                scalars[key] = old
            }
        }
        let data = try JSONSerialization.data(withJSONObject: scalars, options: [.sortedKeys])
        scalarsJSON = String(data: data, encoding: .utf8) ?? "{}"
        proposalId = p.id
        proposalNsId = p.nsId
        keys = p.changes.keys.filter { !$0.hasPrefix(SweetMiranda.Key.approverPrefix) }.sorted()
        basal = p.changes[SweetMiranda.Key.basal] != nil ? current.basal : nil
        isf = p.changes[SweetMiranda.Key.isf] != nil ? current.isf : nil
        cr = p.changes[SweetMiranda.Key.cr] != nil ? current.cr : nil
        targets = p.changes[SweetMiranda.Key.targets] != nil ? current.targets : nil
        appliedAt = nil
        deadline = nil
        rollbackStarted = false
    }

    var scalars: [String: Any] {
        guard let data = scalarsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// The previous values as a change set laid over what the phone has now: only the keys the
    /// proposal touched go back.
    func previousValues(current: SweetMirandaSettingsCatalog.Sources) throws -> SweetMirandaSettingsCatalog.Parsed {
        let s = scalars
        var p = SweetMirandaSettingsCatalog.Parsed()
        p.pump = SweetMirandaSettingsCatalog.newPumpSettings(current.pump, changes: s)
        p.basal = basal
        p.isf = isf
        p.cr = cr
        p.targets = targets
        if s.keys.contains(where: { $0.hasPrefix(SweetMiranda.Key.prefPrefix) }) {
            p.preferences = try SweetMirandaSettingsCatalog.newPreferences(current.preferences, changes: s)
        }
        if s.keys.contains(where: { $0.hasPrefix(SweetMiranda.Key.settingsPrefix) }) {
            p.settings = try SweetMirandaSettingsCatalog.newSettings(current.settings, changes: s)
        }
        return p
    }

    /// What the rollback reports as written (the previous scalars; schedules by name).
    var restoredChanges: [String: Any] {
        var c = scalars
        for k in [SweetMiranda.Key.basal, SweetMiranda.Key.isf, SweetMiranda.Key.cr, SweetMiranda.Key.targets]
            where keys.contains(k)
        {
            c[k] = "restored"
        }
        return c
    }
}

// MARK: - One-shot pump answers

/// Wraps a checked continuation so it resumes exactly once, whatever the pump driver does.
final class SMOnceContinuation<T> {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    private let what: String

    init(_ cont: CheckedContinuation<T, Error>, what: String) {
        self.cont = cont
        self.what = what
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = cont
        cont = nil
        return c
    }

    func resume(returning value: T) {
        guard let c = take() else {
            debug(.remoteControl, "SweetMiranda: \(what): the pump answered twice, ignored")
            return
        }
        c.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let c = take() else {
            debug(.remoteControl, "SweetMiranda: \(what): the pump answered twice, ignored")
            return
        }
        c.resume(throwing: error)
    }
}

extension SMOnceContinuation where T == Void {
    func resume() { resume(returning: ()) }
}

// MARK: - Background time

/// Wraps UIApplication background-task bookkeeping so a Sweet Miranda request can finish after the
/// app is backgrounded, and is ended exactly once (on completion or when iOS says time is up).
private final class SMBackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    init(name: String) {
        let start = { [self] in
            let newId = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
            lock.lock()
            id = newId
            lock.unlock()
        }
        if Thread.isMainThread { start() } else { DispatchQueue.main.sync(execute: start) }
    }

    func end() {
        lock.lock()
        let current = id
        id = .invalid
        lock.unlock()
        guard current != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(current) }
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
