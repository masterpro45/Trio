import Charts
import SwiftUI
import Swinject

/// Sweet Miranda's home screen: the one she asked for.
///
/// It is a *skin*, not a second Trio. Every number on it is read from `Home.StateModel` —
/// the same state stock `HomeRootView` reads — and the big button opens Trio's own
/// `Treatments.RootView`, so carbs and insulin go through Trio's real calculator and its
/// real pump path. Nothing here computes a dose.
///
/// Stock `HomeRootView` is untouched; `SweetMirandaSkin.isEnabled` chooses between them in
/// `Screen.home`, so she can flip back to ordinary Trio at any time.
extension SweetMiranda {
    struct HomeView: BaseView {
        let resolver: Resolver

        @Environment(\.colorScheme) var colorScheme

        @State var state = Home.StateModel()
        @State private var showTreatments = false
        @State private var showSettings = false
        @State private var showHistory = false
        @State private var showAlerts = false

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
            .sheet(isPresented: $showTreatments) {
                // Trio's own carb + bolus screen. The skin is the door; the maths is Trio's.
                Treatments.RootView(resolver: resolver)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { Settings.RootView(resolver: resolver) }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack { Stat.RootView(resolver: resolver) }
            }
            .sheet(isPresented: $showAlerts) {
                NavigationStack { GlucoseAlerts.RootView(resolver: resolver) }
            }
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
                    value: reservoirUnits ?? 0,
                    maximum: 200,
                    label: reservoirUnits.map { String(Int($0.rounded())) } ?? "—",
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

        private var reservoirUnits: Double? {
            state.reservoir.map { Double(truncating: $0 as NSNumber) }
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
                    showTreatments = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 19, weight: .bold))
                        Text("EAT + DOSE")
                            .font(.custom(SweetMirandaPalette.display, size: 21).weight(.heavy))
                    }
                    .foregroundStyle(SweetMirandaPalette.ink)
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background(SweetMirandaPalette.pink, in: RoundedRectangle(cornerRadius: 26))
                    .shadow(color: SweetMirandaPalette.pinkDeep, radius: 0, y: 6)
                    .shadow(color: SweetMirandaPalette.pink.opacity(0.32), radius: 14, y: 12)
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
                ) { showHistory = true }
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
