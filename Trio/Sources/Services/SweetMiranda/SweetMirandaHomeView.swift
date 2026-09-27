import Charts
import LoopKit
import LoopKitUI
import SwiftUI
import Swinject

/// Sweet Miranda's home screen: the one she asked for.
///
/// It is a *skin*, not a second Trio. Every number on it is read from `Home.StateModel` —
/// the same state stock `HomeRootView` reads. The big button asks what she is eating first
/// (`SweetMiranda.EatView`), then opens Trio's own treatment screen with those carbs filled
/// in, the same way stock Home opens it (`showModal(for: .treatmentView)`), so carbs and
/// insulin go through Trio's real calculator and its real pump path. Nothing here computes a dose.
///
/// Stock `HomeRootView` is untouched; `SweetMirandaSkin.isEnabled` chooses between them in
/// `Screen.home`, so she can flip back to ordinary Trio at any time.
extension SweetMiranda {
    struct HomeView: BaseView {
        let resolver: Resolver

        @Environment(\.colorScheme) var colorScheme

        @State var state = Home.StateModel()
        @State private var showEat = false
        @State private var doseAfterEat = false
        @State private var showSettings = false
        @State private var showAlerts = false
        @State private var showSensor = false
        /// Activity Mode: Trio's own override preset, found by name.
        @State private var modePresets: [SweetMirandaMode: SMModePreset] = [:]
        @State private var confirmMode: SweetMirandaMode?
        @State private var modeMessage: String?
        @State private var modeBusy = false
        /// The mode button she is holding down (2 s starts it), and how far the fill has got.
        @State private var holdingMode: SweetMirandaMode?
        @State private var holdProgress: CGFloat = 0
        @ObservedObject private var dream = SweetMirandaDreamMode.shared
        private let dreamClock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
        /// Pod Keep Alive, re-read when she comes back to the screen (reading pump state each frame is wasteful).
        @State private var keepAliveLoopsWhenLocked: Bool?
        /// Alerts she closed with ✕. One comes back only after its problem went away and returned
        /// (next pod, next sensor…), so ✕ means "done, got it" for this time.
        @AppStorage("sweetMiranda.dismissedNudges") private var dismissedNudgesRaw = ""
        @ObservedObject private var foods = SweetMirandaFoodStore.shared
        /// Stock HomeRootView provides this to everything under it; Settings and Glucose Alarms
        /// read it from the environment and crash without it, so the skin provides its own.
        @State private var settingsSearchHighlight = SettingsSearchHighlight()

        @ObservedObject private var sensor = SweetMirandaSensorSession.shared

        var body: some View {
            ZStack {
                SweetMirandaPalette.ground.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    orbRow
                    if let nudge { nudgeBar(nudge) }
                    glucoseBlock
                    graphCard
                    statsRow
                    modesRow
                    Spacer(minLength: 8)
                    bottomBar
                }
            }
            .onAppear {
                configureView()
                refreshDeviceFacts()
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showEat, onDismiss: openTreatmentsIfChosen) {
                SweetMiranda.EatView(
                    glucose: latest.map { Int($0.glucose) },
                    highLine: Int(truncating: state.highGlucose as NSNumber),
                    onDose: { meal in
                        SweetMirandaMealHandoff.put(meal)
                        doseAfterEat = true
                        showEat = false
                    },
                    onHome: { showEat = false }
                )
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { Settings.RootView(resolver: resolver) }
            }
            .sheet(isPresented: $showAlerts) {
                NavigationStack { GlucoseAlerts.RootView(resolver: resolver) }
            }
            .sheet(isPresented: $showSensor) {
                NavigationStack { SweetMirandaSensorSessionView() }
            }
            // Trio's own pump screen (change pod, pod keep alive…), exactly as stock Home opens it.
            .sheet(isPresented: $state.shouldDisplayPumpSetupSheet, onDismiss: refreshDeviceFacts) {
                if let pumpManager = state.provider.apsManager.pumpManager {
                    PumpConfig.PumpSettingsView(
                        pumpManager: pumpManager,
                        bluetoothManager: state.provider.apsManager.bluetoothManager!,
                        completionDelegate: state,
                        setupDelegate: state
                    )
                } else if let pumpEntry = state.setupPumpEntry {
                    PumpConfig.PumpSetupView(
                        pumpEntry: pumpEntry,
                        pumpInitialSettings: state.pumpInitialSettings,
                        bluetoothManager: state.provider.apsManager.bluetoothManager!,
                        completionDelegate: state,
                        setupDelegate: state
                    )
                }
            }
            // Her Dexcom's own screen (change sensor / transmitter), exactly as stock Home opens it.
            .sheet(isPresented: $state.shouldDisplayCGMSetupSheet, onDismiss: refreshDeviceFacts) {
                switch state.cgmCurrent.type {
                case .nightscout,
                     .none,
                     .simulator,
                     .xdrip:
                    CGMSettings.CustomCGMOptionsView(
                        resolver: resolver,
                        state: state.cgmStateModel,
                        cgmCurrent: state.cgmCurrent,
                        deleteCGM: state.deleteCGM
                    )
                    .environment(settingsSearchHighlight)
                case .plugin:
                    if let fetchGlucoseManager = state.fetchGlucoseManager,
                       let cgmManager = fetchGlucoseManager.cgmManager,
                       state.cgmCurrent.type == fetchGlucoseManager.cgmGlucoseSourceType,
                       state.cgmCurrent.id == fetchGlucoseManager.cgmGlucosePluginId
                    {
                        CGMSettings.CGMSettingsView(
                            cgmManager: cgmManager,
                            bluetoothManager: state.provider.apsManager.bluetoothManager!,
                            unit: state.settingsManager.settings.units,
                            completionDelegate: state
                        )
                    } else {
                        CGMSettings.CGMSetupView(
                            CGMType: state.cgmCurrent,
                            bluetoothManager: state.provider.apsManager.bluetoothManager!,
                            unit: state.settingsManager.settings.units,
                            completionDelegate: state,
                            setupDelegate: state,
                            pluginCGMManager: state.pluginCGMManager
                        )
                    }
                }
            }
            // After the 2-second hold: how long?
            .confirmationDialog(
                confirmMode.map { "Start \($0.presetName) — for how long?" } ?? "",
                isPresented: Binding(get: { confirmMode != nil }, set: { if !$0 { confirmMode = nil } }),
                titleVisibility: .visible,
                presenting: confirmMode
            ) { mode in
                ForEach(mode.choices, id: \.self) { minutes in
                    Button(SweetMirandaMode.choiceLabel(minutes)) { startMode(mode, minutes: minutes) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { mode in
                Text(modeSummary(mode))
            }
            .onReceive(dreamClock) { _ in
                tickDream()
                forgetSolvedNudges()
            }
            .alert(
                "Mode",
                isPresented: Binding(get: { modeMessage != nil }, set: { if !$0 { modeMessage = nil } }),
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(modeMessage ?? "") }
            )
            .environment(settingsSearchHighlight)
        }

        // MARK: - Activity Mode + Dream Mode

        /// Her two mode buttons (Wilson 2026-09-27). Hold 2 seconds to start, then she picks how long;
        /// tap to stop. Activity Mode = Trio's own override preset (target 150, insulin unchanged, like
        /// Omnipod 5 Activity). Dream Mode = no insulin: Trio's own pod pause, resumed on time by
        /// `SweetMirandaDreamMode`. Nothing here computes a dose.
        private var modesRow: some View {
            HStack(spacing: 10) {
                ForEach(SweetMirandaMode.allCases) { modeButton($0) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }

        private func isActive(_ mode: SweetMirandaMode) -> Bool {
            switch mode {
            case .activity: return state.overrides.contains { $0.enabled && mode.matches($0.name ?? "") }
            case .dream: return dream.isOn
            }
        }

        private func modeCaption(_ mode: SweetMirandaMode, active: Bool) -> String {
            if active {
                if mode == .dream, let back = dream.resumeAt {
                    return "No insulin · back \(back.formatted(date: .omitted, time: .shortened)) · tap to resume"
                }
                return "ON · tap to stop"
            }
            return holdingMode == mode ? "Keep holding…" : "hold 2 sec to start"
        }

        @ViewBuilder private func modeButton(_ mode: SweetMirandaMode) -> some View {
            let active = isActive(mode)
            let face = HStack(spacing: 9) {
                Image(systemName: mode.icon)
                    .font(.system(size: 18, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.presetName)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(modeCaption(mode, active: active))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? SweetMirandaPalette.ink : mode.tint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(active ? mode.tint : mode.tint.opacity(0.14))
                        .shadow(color: active ? mode.tint.opacity(0.6) : .clear, radius: 10)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 18)
                            .fill(mode.tint.opacity(0.35))
                            .frame(width: geo.size.width * (holdingMode == mode ? holdProgress : 0))
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .opacity(modeBusy ? 0.6 : 1)
            .allowsHitTesting(!modeBusy)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(mode.presetName + (active ? ", on" : "")))

            if active {
                face
                    .onTapGesture { endMode(mode) }
                    .accessibilityAction { endMode(mode) }
            } else {
                face
                    .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
                        holdingMode = nil
                        holdProgress = 0
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        confirmMode = mode
                    } onPressingChanged: { pressing in
                        holdingMode = pressing ? mode : nil
                        withAnimation(pressing ? .linear(duration: 2) : .easeOut(duration: 0.2)) {
                            holdProgress = pressing ? 1 : 0
                        }
                    }
                    .accessibilityAction { confirmMode = mode }
            }
        }

        private func modeSummary(_ mode: SweetMirandaMode) -> String {
            switch mode {
            case .activity:
                guard let p = modePresets[.activity] else {
                    return "Target \(SweetMirandaActivity.defaultTarget) mg/dL · insulin unchanged. Tap it again any time to stop."
                }
                var parts = ["Insulin \(Int(p.percentage.rounded()))%"]
                if let t = p.target, t > 0 { parts.append("target \(t) mg/dL") }
                return parts.joined(separator: " · ") + ". Tap it again any time to stop."
            case .dream:
                return "Your pod gives NO insulin until the time is up — then insulin turns back on by itself. Tap Dream Mode any time to turn insulin back on sooner."
            }
        }

        private func startMode(_ mode: SweetMirandaMode, minutes: Int) {
            modeBusy = true
            Task { @MainActor in
                defer { modeBusy = false }
                do {
                    switch mode {
                    case .activity:
                        guard let manager = resolver.resolve(AdjustmentManager.self) else { return }
                        let id = try await SweetMirandaActivity.prepare(resolver: resolver, minutes: minutes)
                        try await manager.activateOverride(.presetID(id), source: .app, waitForUpload: false)
                        await loadModePresets()
                    case .dream:
                        guard let aps = resolver.resolve(APSManager.self) else { return }
                        try await dream.start(minutes: minutes, apsManager: aps)
                    }
                } catch {
                    modeMessage = "Couldn't start \(mode.presetName): \(error.localizedDescription)"
                }
            }
        }

        private func endMode(_ mode: SweetMirandaMode) {
            modeBusy = true
            Task { @MainActor in
                defer { modeBusy = false }
                do {
                    switch mode {
                    case .activity:
                        guard let manager = resolver.resolve(AdjustmentManager.self) else { return }
                        try await manager.cancelOverride(source: .app, waitForUpload: false)
                    case .dream:
                        guard let aps = resolver.resolve(APSManager.self) else { return }
                        try await dream.stop(apsManager: aps)
                    }
                } catch AdjustmentError.nothingActive {
                } catch {
                    modeMessage = mode == .dream
                        ?
                        "Insulin is still paused — couldn't reach your pod: \(error.localizedDescription). Try again, or resume from the pod screen."
                        : "Couldn't stop \(mode.presetName): \(error.localizedDescription)"
                }
            }
        }

        /// Foreground check every 30 s; in the background every new G6 reading does the same
        /// (`BaseSweetMirandaSyncManager`).
        private func tickDream() {
            guard dream.isOn, let aps = resolver.resolve(APSManager.self) else { return }
            Task { @MainActor in await dream.tick(apsManager: aps) }
        }

        @MainActor private func loadModePresets() async {
            guard let storage = resolver.resolve(OverrideStorage.self),
                  let ids = try? await storage.fetchForOverridePresets() else { return }
            let context = CoreDataStack.shared.persistentContainer.viewContext
            var found: [SweetMirandaMode: SMModePreset] = [:]
            for objectID in ids {
                guard let o = try? context.existingObject(with: objectID) as? OverrideStored,
                      let name = o.name, let id = o.id else { continue }
                for mode in SweetMirandaMode.allCases
                    where found[mode] == nil && mode.matches(name)
                {
                    found[mode] = SMModePreset(
                        id: id,
                        name: name,
                        percentage: o.percentage,
                        target: o.target as Decimal?,
                        minutes: o.duration as Decimal?,
                        indefinite: o.indefinite
                    )
                }
            }
            modePresets = found
        }

        /// Pod Keep Alive and her food list: things that live outside Home.StateModel.
        private func refreshDeviceFacts() {
            keepAliveLoopsWhenLocked = SweetMirandaPodKeepAlive
                .loopsWhenLocked(resolver.resolve(DeviceDataManager.self)?.pumpManager)
            forgetSolvedNudges()
            let nightscout = resolver.resolve(NightscoutManager.self)
            Task { await SweetMirandaFoodStore.shared.refresh(nightscout: nightscout) }
            Task { await loadModePresets() }
        }

        /// A CGM Trio talks to itself (her G6 since 2026-09-27) reports its own sensor age; the
        /// hand-entered date is only for a CGM that can't (Nightscout as the source).
        private var cgmKnowsSensorAge: Bool {
            resolver.resolve(FetchGlucoseManager.self)?.cgmManager != nil
        }

        /// Days left on the sensor: from the CGM when it knows, else from the date she entered.
        /// `cgmSensorExpiresAt` already prefers the CGM and falls back to her date.
        private var sensorDaysLeft: Int? {
            if let expires = state.cgmSensorExpiresAt {
                return max(0, Int((expires.timeIntervalSinceNow / 86400).rounded(.up)))
            }
            return sensor.daysRemaining
        }

        /// The sensor circle: her Dexcom's own screen (the one stock Home opens from the glucose
        /// circle — start / stop / change sensor, transmitter) when Trio talks to the CGM itself,
        /// else her date screen.
        private func openSensor() {
            if cgmKnowsSensorAge {
                state.shouldDisplayCGMSetupSheet = true
            } else {
                showSensor = true
            }
        }

        /// The pod circles open Trio's pump screen, the same tap as the pump on stock Home.
        private func openPump() {
            if state.pumpDisplayState == nil {
                state.showModal(for: .pumpConfigDirect)
            } else {
                state.shouldDisplayPumpSetupSheet = true
            }
        }

        /// Trio's own carb + bolus screen, opened exactly as stock Home opens it, so it closes
        /// itself after a bolus and carries the app's environment. The skin is the door; the
        /// maths is Trio's.
        private func openTreatmentsIfChosen() {
            guard doseAfterEat else { return }
            doseAfterEat = false
            state.showModal(for: .treatmentView)
        }

        // MARK: - Header

        private var header: some View {
            HStack(spacing: 8) {
                SweetMirandaBubbleName(text: "Miranda")
                SweetMirandaPaw()

                Spacer()

                if state.isLooping {
                    Text("looping")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(0.8)
                        .foregroundStyle(SweetMirandaPalette.mint)
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SweetMirandaPalette.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }

        // MARK: - Orbs

        private var orbRow: some View {
            HStack(spacing: 10) {
                Button(action: openPump) {
                    SweetMirandaOrb(
                        value: reservoirOrbValue,
                        maximum: Self.podCapacity,
                        label: reservoirLabel,
                        caption: String(localized: "UNITS LEFT")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the pump settings"))
                Button(action: openPump) {
                    SweetMirandaOrb(
                        value: podHoursLeft ?? 0,
                        maximum: 80,
                        label: podHoursLeft.map { "\(Int($0.rounded()))h" } ?? "—",
                        caption: String(localized: "POD HOURS")
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the pump settings to change the pod"))
                Button(action: openSensor) {
                    SweetMirandaOrb(
                        value: Double(sensorDaysLeft ?? 0),
                        maximum: sensor.lifetimeDays,
                        label: sensorDaysLeft.map { "\($0)d" } ?? "—",
                        caption: String(localized: "SENSOR DAYS"),
                        state: cgmKnowsSensorAge ? nil : sensor.progressState()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(
                    cgmKnowsSensorAge ? "Opens your Dexcom to change the sensor" :
                        "Set the day you put your sensor on"
                ))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }

        /// Omnipod pods hold at most 200 U.
        private static let podCapacity: Double = 200

        /// Omnipod only measures the reservoir once it is at or below 50 U; above that the pump
        /// manager reports the 0xDEADBEEF sentinel, which stock Trio shows as "50+ U".
        private var reservoirIsAboveFifty: Bool { state.reservoir == 0xDEAD_BEEF }

        /// A real, measured amount (0…200 U), or nil when the pod has not reported one.
        private var reservoirUnits: Double? {
            guard let r = state.reservoir, !reservoirIsAboveFifty else { return nil }
            let units = Double(truncating: r as NSNumber)
            return (0 ... Self.podCapacity).contains(units) ? units : nil
        }

        private var reservoirLabel: String {
            if reservoirIsAboveFifty { return "50+" }
            return reservoirUnits.map { String(Int($0.rounded())) } ?? "—"
        }

        private var reservoirOrbValue: Double {
            if reservoirIsAboveFifty { return Self.podCapacity }
            return reservoirUnits ?? 0
        }

        private var podHoursLeft: Double? {
            guard let expires = state.pumpExpiresAtDate else { return nil }
            let remaining = expires.timeIntervalSince(Date())
            return remaining > 0 ? remaining / 3600 : 0
        }

        // MARK: - Nudge

        /// One line, only when something genuinely needs her to do something today.
        private enum NudgeKind: String, CaseIterable {
            case podEnding
            case keepAlive
            case sensorEnding
            case podLow
            case sensorDate
        }

        /// Every alert that applies right now, most important first.
        private var nudges: [(kind: NudgeKind, text: String)] {
            var out: [(kind: NudgeKind, text: String)] = []
            if let hours = podHoursLeft, hours <= 8 {
                out.append((.podEnding, String(
                    format: String(localized: "Pod runs out in %d hours — grab a new one"),
                    Int(hours.rounded())
                )))
            }
            // Only matters without a CGM heartbeat: her G6 wakes Trio with the phone locked (2026-09-27).
            if keepAliveLoopsWhenLocked == false, !cgmKnowsSensorAge {
                out
                    .append((
                        .keepAlive,
                        String(localized: "Trio only loops while it's open. Ask Dad to set Pod Keep Alive to Silent Tune")
                    ))
            }
            if let days = sensorDaysLeft, days <= 1 {
                out.append((.sensorEnding, String(localized: "Sensor ends tomorrow — pack a new one")))
            }
            if let units = reservoirUnits, units <= 20 {
                out.append((.podLow, String(
                    format: String(localized: "Only %d units left in the pod"),
                    Int(units.rounded())
                )))
            }
            if sensor.startedAt == nil, !cgmKnowsSensorAge {
                out.append((.sensorDate, String(localized: "Tell Trio when you put your sensor on: tap the sensor circle")))
            }
            return out
        }

        private var dismissedNudges: Set<String> {
            Set(dismissedNudgesRaw.split(separator: ",").map(String.init))
        }

        /// The first alert she hasn't closed.
        private var nudge: (kind: NudgeKind, text: String)? {
            nudges.first { !dismissedNudges.contains($0.kind.rawValue) }
        }

        /// A closed alert whose problem has gone away is forgotten, so it shows again next time.
        private func forgetSolvedNudges() {
            let live = Set(nudges.map(\.kind.rawValue))
            let kept = dismissedNudges.intersection(live)
            if kept != dismissedNudges { dismissedNudgesRaw = kept.sorted().joined(separator: ",") }
        }

        private func dismissNudge(_ kind: NudgeKind) {
            withAnimation(.easeOut(duration: 0.2)) {
                dismissedNudgesRaw = dismissedNudges.union([kind.rawValue]).sorted().joined(separator: ",")
            }
        }

        private func nudgeBar(_ item: (kind: NudgeKind, text: String)) -> some View {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SweetMirandaPalette.amber)
                Text(item.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SweetMirandaPalette.amber.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { dismissNudge(item.kind) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SweetMirandaPalette.amber.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close this alert")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 10)
            .background(SweetMirandaPalette.amber.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.top, 10)
        }

        // MARK: - The number

        private var latest: GlucoseStored? { state.glucoseFromPersistence.last }

        private var glucoseTint: Color {
            guard let value = latest?.glucose else { return SweetMirandaPalette.muted }
            return SweetMirandaPalette.glucoseColor(Int(value), low: state.lowGlucose, high: state.highGlucose)
        }

        private var glucoseBlock: some View {
            HStack(alignment: .bottom, spacing: 12) {
                Text(latest.map { String(Int($0.glucose)) } ?? "—")
                    .font(.custom(SweetMirandaPalette.display, size: 88).weight(.heavy))
                    .foregroundStyle(glucoseTint)
                    .contentTransition(.numericText())
                    .animation(.easeInOut, value: latest?.glucose)

                VStack(alignment: .leading, spacing: 2) {
                    if let symbol = latest?.directionEnum?.symbol {
                        Text(symbol)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(glucoseTint)
                    }
                    Text(state.units.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SweetMirandaPalette.muted)
                }
                .padding(.bottom, 10)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(rangeWord)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(glucoseTint)
                    Text(ageText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SweetMirandaPalette.muted)
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }

        private var rangeWord: String {
            guard let value = latest?.glucose else { return "" }
            let v = Decimal(Int(value))
            if v < state.lowGlucose { return String(localized: "Low") }
            if v > state.highGlucose { return String(localized: "High") }
            return String(localized: "In range")
        }

        private var ageText: String {
            guard let date = latest?.date else { return "" }
            let minutes = Int(Date().timeIntervalSince(date) / 60)
            if minutes < 2 { return String(localized: "just now") }
            return String(format: String(localized: "%d min ago"), minutes)
        }

        // MARK: - Graph

        /// Her last three hours, drawn with a shadowed line under the real one so it reads with
        /// depth rather than as a flat sparkline.
        private var graphCard: some View {
            let cutoff = Date().addingTimeInterval(-3 * 3600)
            let points = state.glucoseFromPersistence
                .compactMap { g -> (Date, Int)? in
                    guard let d = g.date, d >= cutoff, g.glucose > 0 else { return nil }
                    return (d, Int(g.glucose))
                }

            return VStack(spacing: 0) {
                if points.count >= 2 {
                    Chart {
                        RectangleMark(
                            yStart: .value("low", Int(truncating: state.lowGlucose as NSNumber)),
                            yEnd: .value("high", Int(truncating: state.highGlucose as NSNumber))
                        )
                        .foregroundStyle(SweetMirandaPalette.mint.opacity(0.11))

                        // depth pass: the same curve, offset and dark
                        ForEach(points, id: \.0) { point in
                            LineMark(
                                x: .value("time", point.0),
                                y: .value("depth", point.1 - 6),
                                series: .value("s", "depth")
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 9, lineCap: .round))
                            .foregroundStyle(SweetMirandaPalette.pinkDeep.opacity(0.45))
                        }

                        ForEach(points, id: \.0) { point in
                            LineMark(
                                x: .value("time", point.0),
                                y: .value("glucose", point.1),
                                series: .value("s", "glucose")
                            )
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [SweetMirandaPalette.lilac, SweetMirandaPalette.pink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                        }

                        if let last = points.last {
                            PointMark(x: .value("time", last.0), y: .value("glucose", last.1))
                                .symbolSize(150)
                                .foregroundStyle(SweetMirandaPalette.pink)
                        }
                    }
                    .chartYScale(domain: yDomain(points.map(\.1)))
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [
                            Int(truncating: state.lowGlucose as NSNumber),
                            Int(truncating: state.highGlucose as NSNumber)
                        ]) {
                            AxisValueLabel()
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SweetMirandaPalette.muted)
                        }
                    }
                    .frame(height: 150)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 12)
                } else {
                    Text("Waiting for readings…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SweetMirandaPalette.muted)
                        .frame(height: 150)
                }
            }
            .background(SweetMirandaPalette.card, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }

        private func yDomain(_ values: [Int]) -> ClosedRange<Int> {
            let low = min(values.min() ?? 70, 70) - 15
            let high = max(values.max() ?? 180, 180) + 20
            return max(0, low) ... high
        }

        // MARK: - Stats

        private var statsRow: some View {
            HStack(spacing: 10) {
                statTile(
                    value: iobText,
                    caption: String(localized: "INSULIN ON BOARD"),
                    tint: SweetMirandaPalette.text,
                    background: SweetMirandaPalette.card
                )
                statTile(
                    value: cobText,
                    caption: String(localized: "CARBS LEFT"),
                    tint: SweetMirandaPalette.text,
                    background: SweetMirandaPalette.card
                )
                statTile(
                    value: targetText,
                    caption: String(localized: "TARGET"),
                    tint: SweetMirandaPalette.mint,
                    background: SweetMirandaPalette.mint.opacity(0.13)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }

        private var iobText: String {
            String(format: "%.1f U", Double(truncating: state.currentIOB as NSNumber))
        }

        private var cobText: String {
            let cob = state.enactedAndNonEnactedDeterminations.first?.cob ?? 0
            return "\(Int(cob)) g"
        }

        /// The running override's target (Activity Mode's 150) when one is on, else her profile target.
        private var targetText: String {
            if let t = state.overrides.first(where: { $0.enabled })?.target, t.intValue > 0 {
                return "\(t.intValue)"
            }
            return "\(Int(truncating: state.currentGlucoseTarget as NSNumber))"
        }

        private func statTile(value: String, caption: String, tint: Color, background: Color) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.custom(SweetMirandaPalette.display, size: 21).weight(.heavy))
                    .foregroundStyle(tint)
                Text(caption)
                    .font(.system(size: 9, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(SweetMirandaPalette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(background, in: RoundedRectangle(cornerRadius: 18))
        }

        // MARK: - Bottom bar

        private var bottomBar: some View {
            HStack(spacing: 10) {
                Button {
                    refreshDeviceFacts()
                    showEat = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 18, weight: .bold))
                        Text("EAT + DOSE")
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(SweetMirandaPalette.ink)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background {
                        RoundedRectangle(cornerRadius: 26)
                            .fill(SweetMirandaPalette.pink)
                            .shadow(color: SweetMirandaPalette.pinkDeep, radius: 0, y: 6)
                            .shadow(color: SweetMirandaPalette.pink.opacity(0.32), radius: 14, y: 12)
                    }
                }
                .accessibilityLabel("Add carbs and dose insulin")

                squareButton(
                    icon: "bell.fill",
                    caption: String(localized: "ALERTS"),
                    tint: SweetMirandaPalette.pinkSoft,
                    badge: state.alarm != nil
                ) { showAlerts = true }

                squareButton(
                    icon: "chart.bar.fill",
                    caption: String(localized: "HISTORY"),
                    tint: SweetMirandaPalette.lilac,
                    badge: false
                ) { state.showModal(for: .statistics) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .padding(.top, 12)
        }

        private func squareButton(
            icon: String,
            caption: String,
            tint: Color,
            badge: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(caption)
                        .font(.system(size: 9, weight: .bold))
                        .kerning(0.4)
                        .foregroundStyle(SweetMirandaPalette.muted)
                }
                .frame(width: 68, height: 68)
                .background(SweetMirandaPalette.cardStrong, in: RoundedRectangle(cornerRadius: 24))
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(SweetMirandaPalette.amber)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(SweetMirandaPalette.ground, lineWidth: 2))
                            .offset(x: -12, y: 12)
                    }
                }
            }
            .accessibilityLabel(caption)
        }
    }
}

// MARK: - Eat first

/// Carbs from her Eat screen, handed to Trio's treatment screen and taken exactly once.
/// A handoff older than two minutes is dropped, so a stale meal can never pre-fill a
/// treatment screen opened later from somewhere else.
enum SweetMirandaMealHandoff {
    struct Meal {
        let carbs: Decimal
        let note: String
        let at: Date
    }

    private static var pending: Meal?
    private static let lock = NSLock()

    static func put(_ meal: Meal) {
        lock.lock()
        pending = meal
        lock.unlock()
    }

    static func take(now: Date = Date()) -> Meal? {
        lock.lock()
        defer { lock.unlock() }
        guard let meal = pending else { return nil }
        pending = nil
        return now.timeIntervalSince(meal.at) <= 120 ? meal : nil
    }
}

/// One food on her list, with its carbs for ONE serving as written.
struct SweetMirandaFood: Identifiable, Hashable, Codable {
    let id: String
    let emoji: String
    let name: String
    let serving: String
    let carbs: Int
    var favorite: Bool = true
    var sort: Int = 100
}

/// Her food list. Edited in WilHQ (Sweet Miranda ▸ Foods, table `sm_foods`), copied by the Odysseus
/// bridge into Nightscout's food collection (category "Sweet Miranda"), read here. The last good
/// list is kept on the phone for when she is offline; the built-in ten are the fallback before the
/// first download. Only carbs travel on to Trio's calculator.
final class SweetMirandaFoodStore: ObservableObject {
    static let shared = SweetMirandaFoodStore()

    @Published private(set) var foods: [SweetMirandaFood]
    private let cacheKey = "sweetMiranda.foods.cache"

    init() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([SweetMirandaFood].self, from: data), !cached.isEmpty
        {
            foods = cached
        } else {
            foods = SweetMirandaFoods.favorites
        }
    }

    func refresh(nightscout: NightscoutManager?) async {
        guard let nightscout else { return }
        let docs = await nightscout.sweetMirandaFetchFoods()
        let list = docs.compactMap(Self.food(from:)).sorted {
            ($0.favorite ? 0 : 1, $0.sort, $0.name) < ($1.favorite ? 0 : 1, $1.sort, $1.name)
        }
        guard !list.isEmpty else { return }
        await MainActor.run {
            guard list != self.foods else { return }
            self.foods = list
            if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: self.cacheKey) }
        }
    }

    /// One Nightscout food document written by the bridge; anything malformed is skipped.
    static func food(from d: [String: Any]) -> SweetMirandaFood? {
        guard (d["category"] as? String) == "Sweet Miranda",
              let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let carbs = (d["carbs"] as? NSNumber)?.doubleValue, carbs >= 0, carbs <= 250
        else { return nil }
        return SweetMirandaFood(
            id: (d["smFoodId"] as? String) ?? (d["_id"] as? String) ?? name,
            emoji: (d["smEmoji"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "🍽️",
            name: name,
            serving: (d["smServing"] as? String) ?? "1 serving",
            carbs: Int(carbs.rounded()),
            favorite: (d["smFavorite"] as? Bool) ?? true,
            sort: (d["smSort"] as? NSNumber)?.intValue ?? 100
        )
    }
}

enum SweetMirandaFoods {
    /// Carbs per serving from USDA FoodData Central, rounded to the gram. A stand-in until the
    /// WilHQ food list feeds this; change values only from a nutrition source.
    static let favorites: [SweetMirandaFood] = [
        .init(id: "green-grapes", emoji: "🍇", name: "Green grapes", serving: "1 cup (151 g)", carbs: 27),
        .init(id: "banana", emoji: "🍌", name: "Banana", serving: "1 medium (118 g)", carbs: 27),
        .init(id: "apple", emoji: "🍎", name: "Apple", serving: "1 medium (182 g)", carbs: 25),
        .init(id: "strawberries", emoji: "🍓", name: "Strawberries", serving: "1 cup halves (152 g)", carbs: 12),
        .init(id: "blueberries", emoji: "🫐", name: "Blueberries", serving: "1 cup (148 g)", carbs: 21),
        .init(id: "orange", emoji: "🍊", name: "Orange", serving: "1 medium (131 g)", carbs: 15),
        .init(id: "clementine", emoji: "🍊", name: "Clementine", serving: "1 fruit (74 g)", carbs: 9),
        .init(id: "watermelon", emoji: "🍉", name: "Watermelon", serving: "1 cup diced (152 g)", carbs: 12),
        .init(id: "pineapple", emoji: "🍍", name: "Pineapple", serving: "1 cup chunks (165 g)", carbs: 22),
        .init(id: "mango", emoji: "🥭", name: "Mango", serving: "1 cup pieces (165 g)", carbs: 25)
    ]
}

extension SweetMiranda {
    /// "How many carbs are you eating?" — typed by hand, picked from her favourites, or both.
    /// It only collects grams; the dose is worked out by Trio's treatment screen afterwards.
    /// Dosing with no food is still possible, but deliberately a few steps away.
    struct EatView: View {
        let glucose: Int?
        let highLine: Int
        let onDose: (SweetMirandaMealHandoff.Meal) -> Void
        let onHome: () -> Void

        @State private var typedCarbs = 0
        @State private var counts: [String: Int] = [:]
        @State private var showCorrection = false
        @State private var search = ""
        @ObservedObject private var store = SweetMirandaFoodStore.shared

        private var shownFoods: [SweetMirandaFood] {
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? store.foods : store.foods.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }

        @FocusState private var typing: Bool

        private static let maxTyped = 250

        private var favoritesCarbs: Int {
            store.foods.reduce(0) { $0 + $1.carbs * (counts[$1.id] ?? 0) }
        }

        private var total: Int { typedCarbs + favoritesCarbs }

        /// Saved with the carbs so the data says what she ate, not just how much.
        private var note: String {
            var parts = store.foods.compactMap { food -> String? in
                guard let n = counts[food.id], n > 0 else { return nil }
                return n == 1 ? food.name : "\(n)× \(food.name)"
            }
            if typedCarbs > 0 { parts.append("\(typedCarbs) g typed") }
            return parts.joined(separator: ", ")
        }

        var body: some View {
            NavigationStack {
                ZStack(alignment: .bottom) {
                    SweetMirandaPalette.ground.ignoresSafeArea()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("How many carbs are you eating?")
                                .font(.system(size: 26, weight: .heavy, design: .rounded))
                                .foregroundStyle(SweetMirandaPalette.text)
                                .fixedSize(horizontal: false, vertical: true)

                            typedCard
                            favoritesCard
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 190)
                    }
                    .scrollDismissesKeyboard(.interactively)

                    bottomActions
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onHome) {
                            Label("Home", systemImage: "house.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(SweetMirandaPalette.pinkSoft)
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { typing = false }
                    }
                }
                .toolbarBackground(SweetMirandaPalette.ground, for: .navigationBar)
                .navigationDestination(isPresented: $showCorrection) {
                    SweetMiranda.CorrectionGateView(
                        glucose: glucose,
                        highLine: highLine,
                        onContinue: {
                            onDose(.init(carbs: 0, note: "Correction, no food", at: Date()))
                        },
                        onBackToFood: { showCorrection = false }
                    )
                }
            }
            .preferredColorScheme(.dark)
        }

        // MARK: typed

        private var typedCard: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("TYPE IT")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(SweetMirandaPalette.muted)
                HStack(spacing: 12) {
                    stepButton("minus") { typedCarbs = max(0, typedCarbs - 5) }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        TextField("0", value: $typedCarbs, format: .number)
                            .keyboardType(.numberPad)
                            .focused($typing)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 44, weight: .heavy, design: .rounded))
                            .foregroundStyle(SweetMirandaPalette.text)
                            .onChange(of: typedCarbs) { _, new in
                                typedCarbs = min(max(0, new), Self.maxTyped)
                            }
                        Text("g")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(SweetMirandaPalette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    stepButton("plus") { typedCarbs = min(Self.maxTyped, typedCarbs + 5) }
                }
            }
            .padding(16)
            .background(SweetMirandaPalette.card, in: RoundedRectangle(cornerRadius: 24))
        }

        private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(SweetMirandaPalette.ink)
                    .frame(width: 52, height: 52)
                    .background(SweetMirandaPalette.pinkSoft, in: Circle())
            }
            .buttonStyle(.plain)
        }

        // MARK: favourites

        private var favoritesCard: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("OR PICK YOUR FAVORITES")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(SweetMirandaPalette.muted)
                    .padding(.bottom, 6)
                if store.foods.count > 10 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(SweetMirandaPalette.muted)
                        TextField("Find a food", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(SweetMirandaPalette.text)
                    }
                    .padding(10)
                    .background(SweetMirandaPalette.cardStrong, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 6)
                }
                ForEach(shownFoods) { food in
                    foodRow(food)
                    if food.id != shownFoods.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
                Text("Carbs per serving from her WilHQ food list. Check the label when it's packaged.")
                    .font(.system(size: 11))
                    .foregroundStyle(SweetMirandaPalette.muted)
                    .padding(.top, 8)
            }
            .padding(16)
            .background(SweetMirandaPalette.card, in: RoundedRectangle(cornerRadius: 24))
        }

        private func foodRow(_ food: SweetMirandaFood) -> some View {
            let n = counts[food.id] ?? 0
            return HStack(spacing: 12) {
                Text(food.emoji)
                    .font(.system(size: 28))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(food.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(SweetMirandaPalette.text)
                    Text("\(food.serving) · \(food.carbs) g")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SweetMirandaPalette.muted)
                }
                Spacer(minLength: 4)
                if n > 0 {
                    Button { counts[food.id] = n - 1 } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(SweetMirandaPalette.muted)
                    }
                    .buttonStyle(.plain)
                    Text("\(n)")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(SweetMirandaPalette.pink)
                        .frame(minWidth: 18)
                }
                Button { counts[food.id] = min(9, n + 1) } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(SweetMirandaPalette.pink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(food.name)")
            }
            .padding(.vertical, 6)
        }

        // MARK: bottom

        private var bottomActions: some View {
            VStack(spacing: 12) {
                Button {
                    typing = false
                    onDose(.init(carbs: Decimal(total), note: note, at: Date()))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "drop.fill")
                        Text(total > 0 ? "DOSE FOR \(total) g" : "ADD CARBS TO DOSE")
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(total > 0 ? SweetMirandaPalette.ink : SweetMirandaPalette.pinkSoft)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(total > 0 ? SweetMirandaPalette.pink : SweetMirandaPalette.pinkDeep)
                            .shadow(color: SweetMirandaPalette.pinkDeep, radius: 0, y: total > 0 ? 5 : 0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(total == 0)

                Button {
                    typing = false
                    showCorrection = true
                } label: {
                    Text("I'm high, no food. Just a correction")
                        .font(.system(size: 14, weight: .semibold))
                        .underline()
                        .foregroundStyle(SweetMirandaPalette.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .background {
                SweetMirandaPalette.ground
                    .ignoresSafeArea(edges: .bottom)
                    .shadow(color: .black.opacity(0.6), radius: 12, y: -6)
            }
        }
    }

    /// Dosing with no carbs, on purpose a little harder: it says why food data matters, shows
    /// her glucose next to her high line, and needs a two-second hold.
    struct CorrectionGateView: View {
        let glucose: Int?
        let highLine: Int
        let onContinue: () -> Void
        let onBackToFood: () -> Void

        @State private var holding = false
        @State private var progress: CGFloat = 0

        private var isHigh: Bool { (glucose ?? 0) > highLine }

        private var message: String {
            guard glucose != nil else {
                return "There's no glucose reading right now. Check your sensor, or do a fingerstick, before any correction."
            }
            return isHigh
                ?
                "Only for when you're NOT eating. If any food is coming, go back and add it. Carbs help Trio and your doctor learn what works."
                : "You're not above your high line right now. If you're eating, go back and add your carbs instead."
        }

        var body: some View {
            ZStack {
                SweetMirandaPalette.ground.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Text("Correction only?")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(SweetMirandaPalette.text)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let glucose {
                            Text(String(glucose))
                                .font(.system(size: 56, weight: .heavy, design: .rounded))
                                .foregroundStyle(isHigh ? SweetMirandaPalette.amber : SweetMirandaPalette.mint)
                            Text("mg/dL · your high line is \(highLine)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SweetMirandaPalette.muted)
                        } else {
                            Text("No reading")
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                                .foregroundStyle(SweetMirandaPalette.amber)
                        }
                    }

                    Text(message)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(SweetMirandaPalette.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)

                    Button(action: onBackToFood) {
                        Text("I'm eating, add carbs")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(SweetMirandaPalette.ink)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(SweetMirandaPalette.pink, in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    holdButton
                }
                .padding(20)
            }
            .navigationBarBackButtonHidden(false)
            .preferredColorScheme(.dark)
        }

        /// Two seconds of holding, then Trio's treatment screen opens with no carbs.
        private var holdButton: some View {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(SweetMirandaPalette.cardStrong)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 20)
                        .fill(SweetMirandaPalette.amber.opacity(0.35))
                        .frame(width: geo.size.width * progress)
                }
                Text(holding ? "Keep holding…" : "Hold 2 seconds for a correction")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(SweetMirandaPalette.text)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 58)
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .onLongPressGesture(minimumDuration: 2, maximumDistance: 40) {
                progress = 1
                onContinue()
            } onPressingChanged: { pressing in
                holding = pressing
                withAnimation(pressing ? .linear(duration: 2) : .easeOut(duration: 0.2)) {
                    progress = pressing ? 1 : 0
                }
            }
            .accessibilityLabel("Hold for two seconds to open a correction with no carbs")
        }
    }
}

// MARK: - Activity Mode + Dream Mode

/// Her two mode buttons. Wilson 2026-09-27 (build 15): Activity Mode = target 150, insulin unchanged
/// (Omnipod 5 Activity); Dream Mode = no insulin, for swimming, hard exercise or a low on the way.
/// Both start with a 2-second hold, then she picks how long.
enum SweetMirandaMode: String, CaseIterable, Identifiable, Hashable {
    case activity
    case dream

    var id: String { rawValue }
    var presetName: String { self == .activity ? "Activity Mode" : "Dream Mode" }
    /// Activity: any Trio override preset whose name contains one of these (case-insensitive) is hers.
    var keywords: [String] { self == .activity ? ["activity", "sport", "exercise"] : [] }
    var icon: String { self == .activity ? "figure.run" : "moon.zzz.fill" }
    var tint: Color { self == .activity ? SweetMirandaPalette.mint : SweetMirandaPalette.lilac }
    /// Minutes she can pick after the hold; 0 = until she stops it. Dream never runs past 2 h.
    var choices: [Int] { self == .activity ? [60, 120, 240, 0] : SweetMirandaDreamMode.choices }

    func matches(_ name: String) -> Bool { keywords.contains { name.localizedCaseInsensitiveContains($0) } }

    static func choiceLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Until I stop it"
        case ..<60: return "\(minutes) minutes"
        case 60: return "1 hour"
        default: return "\(minutes / 60) hours"
        }
    }
}

/// Activity Mode runs Trio's own override preset, so it shows in Trio ▸ Adjustments, on the chart
/// and in Nightscout like any override. A preset her parents made (name has activity / sport /
/// exercise) keeps their numbers; if the phone has none, it is created once with Wilson's numbers.
enum SweetMirandaActivity {
    /// Wilson 2026-09-27: target 150 mg/dL, insulin unchanged — like Omnipod 5 Activity.
    static let defaultTarget: Decimal = 150

    /// Returns the preset id after writing the length she picked onto it (0 = until she stops it).
    @MainActor static func prepare(resolver: Resolver, minutes: Int) async throws -> String {
        guard let storage = resolver.resolve(OverrideStorage.self) else { throw SMModeError.unavailable }
        if try await preset(storage) == nil {
            try await storage.storeOverride(override: Override(
                name: SweetMirandaMode.activity.presetName,
                enabled: false,
                date: Date(),
                duration: Decimal(minutes > 0 ? minutes : 60),
                indefinite: minutes == 0,
                percentage: 100,
                smbIsOff: false,
                isPreset: true,
                id: UUID().uuidString,
                overrideTarget: true,
                target: defaultTarget,
                advancedSettings: false,
                isfAndCr: true,
                isf: true,
                cr: true,
                smbIsScheduledOff: false,
                start: 0,
                end: 0,
                smbMinutes: 0,
                uamMinutes: 0
            ))
        }
        guard let row = try await preset(storage), let id = row.id else { throw SMModeError.unavailable }
        row.indefinite = minutes == 0
        if minutes > 0 { row.duration = NSDecimalNumber(value: minutes) }
        let context = CoreDataStack.shared.persistentContainer.viewContext
        if context.hasChanges { try context.save() }
        return id
    }

    @MainActor private static func preset(_ storage: OverrideStorage) async throws -> OverrideStored? {
        let context = CoreDataStack.shared.persistentContainer.viewContext
        for objectID in try await storage.fetchForOverridePresets() {
            if let o = try? context.existingObject(with: objectID) as? OverrideStored,
               SweetMirandaMode.activity.matches(o.name ?? "")
            {
                return o
            }
        }
        return nil
    }
}

enum SMModeError: LocalizedError {
    case unavailable
    case alreadyPaused
    case noPod

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Trio isn't ready yet — try again in a moment."
        case .alreadyPaused: return "Your pod is already paused. Resume it from the pod screen first."
        case .noPod: return "No pod is connected."
        }
    }
}

/// Dream Mode: no insulin for a time she picks (30 min / 1 h / 2 h — never longer), then insulin
/// comes back by itself. It is Trio's own pod pause (`APSManager.suspendDelivery`), because an
/// override can't go below 40 %. The end time is kept on the phone; every new G6 reading (every
/// 5 min, phone locked or not) and the open home screen check it and resume the pod on time,
/// retrying on the next reading if the pod can't be reached. The Odysseus watchdog WhatsApps Wilson
/// if the pod stays paused past the longest choice. It never sends anything to her.
final class SweetMirandaDreamMode: ObservableObject {
    static let shared = SweetMirandaDreamMode()
    static let choices = [30, 60, 120]
    static let maxMinutes = 120

    @Published private(set) var resumeAt: Date?
    private var startedAt: Date?
    private var resuming = false

    private enum Key {
        static let resumeAt = "sweetMiranda.dream.resumeAt"
        static let startedAt = "sweetMiranda.dream.startedAt"
    }

    private init() {
        let d = UserDefaults.standard
        resumeAt = d.object(forKey: Key.resumeAt) as? Date
        startedAt = d.object(forKey: Key.startedAt) as? Date
    }

    var isOn: Bool { resumeAt != nil }

    @MainActor func start(minutes: Int, apsManager: APSManager) async throws {
        guard !apsManager.isSuspended else { throw SMModeError.alreadyPaused }
        let m = min(max(minutes, 1), Self.maxMinutes)
        try await Self.pump(apsManager) { $0.suspendDelivery(completion: $1) }
        let now = Date()
        remember(started: now, resume: now.addingTimeInterval(TimeInterval(m * 60)))
        debug(.apsManager, "SweetMiranda: Dream Mode on — pod paused for \(m) min")
    }

    @MainActor func stop(apsManager: APSManager) async throws {
        try await Self.pump(apsManager) { $0.resumeDelivery(completion: $1) }
        remember(started: nil, resume: nil)
        debug(.apsManager, "SweetMiranda: Dream Mode off — insulin resumed by her")
    }

    /// Resume the pod once the time is up. Safe to call as often as you like.
    @MainActor func tick(apsManager: APSManager) async {
        guard let resumeAt, !resuming else { return }
        // Resumed some other way (pod screen, new pod): forget Dream Mode. The grace keeps a
        // just-started pause from being cleared before the pump reports "suspended".
        if !apsManager.isSuspended, let startedAt, Date().timeIntervalSince(startedAt) > 180 {
            remember(started: nil, resume: nil)
            return
        }
        guard Date() >= resumeAt else { return }
        resuming = true
        defer { resuming = false }
        do {
            try await Self.pump(apsManager) { $0.resumeDelivery(completion: $1) }
            remember(started: nil, resume: nil)
            debug(.apsManager, "SweetMiranda: Dream Mode time up — insulin resumed")
        } catch {
            // Keep the end time: the next glucose reading tries again.
            debug(.apsManager, "SweetMiranda: Dream Mode resume failed, will retry: \(error)")
        }
    }

    /// The pod's own suspend / resume (LoopKit `PumpManager`), the same calls Trio's pump screen makes.
    private static func pump(
        _ apsManager: APSManager,
        _ command: @escaping (PumpManagerUI, @escaping (Error?) -> Void) -> Void
    ) async throws {
        guard let pumpManager = apsManager.pumpManager else { throw SMModeError.noPod }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command(pumpManager) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @MainActor private func remember(started: Date?, resume: Date?) {
        startedAt = started
        resumeAt = resume
        let d = UserDefaults.standard
        d.set(started, forKey: Key.startedAt)
        d.set(resume, forKey: Key.resumeAt)
    }
}

/// What a Trio override preset does, for the "Start …?" question.
struct SMModePreset {
    let id: String
    let name: String
    let percentage: Double
    let target: Decimal?
    let minutes: Decimal?
    let indefinite: Bool
}

// MARK: - Her name

/// Luna's paw print after her name, in the same glossy pink as the letters.
struct SweetMirandaPaw: View {
    var body: some View {
        ZStack {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(SweetMirandaPalette.pinkDeep)
                .offset(x: 1.2, y: 2.4)
            Image(systemName: "pawprint.fill")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.80, blue: 0.91), SweetMirandaPalette.pink],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .rotationEffect(.degrees(-18))
        .shadow(color: SweetMirandaPalette.pink.opacity(0.55), radius: 8, y: 2)
        .padding(.leading, -2)
        .accessibilityHidden(true)
    }
}

/// Her name in bubbly pink 3-D letters: a darker extruded side, a glossy pink face, a white
/// shine on the upper half and a soft glow.
struct SweetMirandaBubbleName: View {
    let text: String

    private var font: Font { .system(size: 30, weight: .black, design: .rounded) }

    var body: some View {
        ZStack {
            ForEach(Array((1 ... 4).reversed()), id: \.self) { i in
                Text(text)
                    .font(font)
                    .foregroundStyle(SweetMirandaPalette.pinkDeep)
                    .offset(x: CGFloat(i) * 0.6, y: CGFloat(i) * 1.2)
            }
            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.80, blue: 0.91), SweetMirandaPalette.pink],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text(text)
                .font(font)
                .foregroundStyle(
                    LinearGradient(colors: [.white.opacity(0.8), .white.opacity(0)], startPoint: .top, endPoint: .center)
                )
        }
        .shadow(color: SweetMirandaPalette.pink.opacity(0.55), radius: 10, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}
