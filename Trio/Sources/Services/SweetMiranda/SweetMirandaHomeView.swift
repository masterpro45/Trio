import Charts
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
                    Spacer(minLength: 8)
                    bottomBar
                }
            }
            .onAppear(perform: configureView)
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
            .environment(settingsSearchHighlight)
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
                Text("miranda")
                    .font(.custom(SweetMirandaPalette.display, size: 19).weight(.heavy))
                    .foregroundStyle(SweetMirandaPalette.text)

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
                SweetMirandaOrb(
                    value: reservoirOrbValue,
                    maximum: Self.podCapacity,
                    label: reservoirLabel,
                    caption: String(localized: "UNITS LEFT")
                )
                SweetMirandaOrb(
                    value: podHoursLeft ?? 0,
                    maximum: 80,
                    label: podHoursLeft.map { "\(Int($0.rounded()))h" } ?? "—",
                    caption: String(localized: "POD HOURS")
                )
                SweetMirandaOrb(
                    value: Double(sensor.daysRemaining ?? 0),
                    maximum: sensor.lifetimeDays,
                    label: sensor.daysRemaining.map { "\($0)d" } ?? "—",
                    caption: String(localized: "SENSOR DAYS"),
                    state: sensor.progressState()
                )
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
        private var nudge: String? {
            if let hours = podHoursLeft, hours <= 8 {
                return String(
                    format: String(localized: "Pod runs out in %d hours — grab a new one"),
                    Int(hours.rounded())
                )
            }
            if let days = sensor.daysRemaining, days <= 1 {
                return String(localized: "Sensor ends tomorrow — pack a new one")
            }
            if let units = reservoirUnits, units <= 20 {
                return String(
                    format: String(localized: "Only %d units left in the pod"),
                    Int(units.rounded())
                )
            }
            if sensor.startedAt == nil {
                return String(localized: "Tell Trio when you put your sensor on — tap the gear, then CGM")
            }
            return nil
        }

        private func nudgeBar(_ text: String) -> some View {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SweetMirandaPalette.amber)
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SweetMirandaPalette.amber.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
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

        private var targetText: String {
            "\(Int(truncating: state.currentGlucoseTarget as NSNumber))"
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

/// One of her favourite foods with its carbs per serving.
struct SweetMirandaFood: Identifiable, Hashable {
    let id: String
    let emoji: String
    let name: String
    let serving: String
    let carbs: Int
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
        @FocusState private var typing: Bool

        private static let maxTyped = 250

        private var favoritesCarbs: Int {
            SweetMirandaFoods.favorites.reduce(0) { $0 + $1.carbs * (counts[$1.id] ?? 0) }
        }

        private var total: Int { typedCarbs + favoritesCarbs }

        /// Saved with the carbs so the data says what she ate, not just how much.
        private var note: String {
            var parts = SweetMirandaFoods.favorites.compactMap { food -> String? in
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
                ForEach(SweetMirandaFoods.favorites) { food in
                    foodRow(food)
                    if food.id != SweetMirandaFoods.favorites.last?.id {
                        Divider().overlay(Color.white.opacity(0.06))
                    }
                }
                Text("Carbs per serving from USDA. Check the label when it's packaged.")
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
