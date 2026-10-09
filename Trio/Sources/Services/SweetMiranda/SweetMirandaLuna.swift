import SwiftUI
import UIKit

/// Luna, indoors.
///
/// Wilson, 2026-10-08: *"Let's bring luna inside, give her high fives and encouragement for her
/// sugar management… kind of like in your iwatch when doing exercise, but pop ups from luna in a
/// corner that she can move around."*
///
/// She is already the app icon. This puts her *in* the app: a small face that lives in a corner of
/// Miranda's home screen, can be dragged anywhere, and speaks up when there is something kind to
/// say. Tap her for a high five.
///
/// ## What she is not
/// ⚕️ Luna is **not** part of the loop and not a clinician. She never names a dose, never tells her
/// to eat or treat anything, never says a number is good or bad, and never nags. On a high or a low
/// she keeps her company and nothing else — the alarms that matter already go to her parents
/// (build 19), and the clinical screens are elsewhere in this app. She reads state; she changes
/// nothing.
///
/// ## How often she speaks
/// At most one popup every 20 minutes and 14 a day, with a per-moment cooldown on top, so she stays
/// a friend rather than a notification. High fives are hers to give freely — a tap is Miranda
/// asking, so it isn't rationed.
///
/// Lines live in `SweetMirandaCheers`, drawn from a no-repeat bag.

// MARK: - What Luna looks at

/// A plain snapshot of the things Luna is allowed to notice. Dates and glucose values only —
/// nothing from the dosing path, nothing she could turn into advice.
struct SweetMirandaLunaFacts {
    /// Ascending by date, the last day or so.
    var readings: [(date: Date, value: Int)] = []
    var low: Int = 70
    var high: Int = 180
    var lastBolus: Date?
    var lastCarbs: Date?
    /// Taken from the device countdowns the home screen already shows.
    var podChanged: Date?
    var sensorChanged: Date?

    var latest: (date: Date, value: Int)? { readings.last }

    func inRange(_ value: Int) -> Bool { value >= low && value <= high }

    /// Readings in the last `minutes`, newest last.
    func window(_ minutes: Int, now: Date = Date()) -> [(date: Date, value: Int)] {
        let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
        return readings.filter { $0.date >= cutoff }
    }
}

// MARK: - The engine

@MainActor final class SweetMirandaLuna: ObservableObject {
    static let shared = SweetMirandaLuna()

    struct Cheer: Equatable {
        let id = UUID()
        let moment: SweetMirandaCheers.Moment
        let text: String

        static func == (a: Cheer, b: Cheer) -> Bool { a.id == b.id }
    }

    /// What she is saying right now, if anything.
    @Published private(set) var cheer: Cheer?
    /// High fives she has handed out today — a small number she can watch grow.
    @Published private(set) var highFivesToday: Int = 0

    enum Key {
        static let enabled = "sweetMiranda.luna.enabled"
        static let shown = "sweetMiranda.luna.shown"
        static let lastAny = "sweetMiranda.luna.lastAny"
        static let dayStamp = "sweetMiranda.luna.day"
        static let dayCount = "sweetMiranda.luna.dayCount"
        static let helloCount = "sweetMiranda.luna.helloCount"
        static let fives = "sweetMiranda.luna.fives"
        static let podCheered = "sweetMiranda.luna.podCheered"
        static let sensorCheered = "sweetMiranda.luna.sensorCheered"
    }

    /// At most one unprompted popup this often…
    private let minGapSeconds: TimeInterval = 20 * 60
    /// …and this many a day.
    private let dailyCap = 14
    /// Plain hellos are the most forgettable, so they get the tightest leash.
    private let helloCapPerDay = 3

    private let defaults: UserDefaults
    private var dismiss: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rollDayIfNeeded()
        highFivesToday = defaults.integer(forKey: Key.fives)
    }

    /// Off only if she turns it off — she asked for this.
    var isEnabled: Bool {
        defaults.object(forKey: Key.enabled) == nil || defaults.bool(forKey: Key.enabled)
    }

    // MARK: Speaking

    /// Called when her screen appears and on a slow timer. Picks at most one thing to say.
    func tick(_ facts: SweetMirandaLunaFacts, opened: Bool = false, now: Date = Date()) {
        guard isEnabled, cheer == nil else { return }
        rollDayIfNeeded(now: now)

        guard defaults.integer(forKey: Key.dayCount) < dailyCap else { return }
        let lastAny = defaults.double(forKey: Key.lastAny)
        guard now.timeIntervalSince1970 - lastAny >= minGapSeconds else { return }

        guard let moment = pick(facts, opened: opened, now: now) else { return }

        defaults.set(now.timeIntervalSince1970, forKey: Key.lastAny)
        defaults.set(defaults.integer(forKey: Key.dayCount) + 1, forKey: Key.dayCount)
        stamp(moment, now: now)
        if moment == .hello { defaults.set(defaults.integer(forKey: Key.helloCount) + 1, forKey: Key.helloCount) }
        remember(moment, facts: facts)

        say(moment.moment, linger: moment.linger)
    }

    /// She tapped Luna. Always answered — this one is Miranda asking, not Luna interrupting.
    func highFive() {
        guard isEnabled else { return }
        rollDayIfNeeded()
        highFivesToday = defaults.integer(forKey: Key.fives) + 1
        defaults.set(highFivesToday, forKey: Key.fives)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        say(.highFive, linger: 5)
    }

    func hush() {
        dismiss?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { cheer = nil }
    }

    private func say(_ moment: SweetMirandaCheers.Moment, linger: TimeInterval) {
        let text = SweetMirandaCheers.next(moment, defaults: defaults)
        guard !text.isEmpty else { return }
        dismiss?.cancel()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.68)) {
            cheer = Cheer(moment: moment, text: text)
        }
        let work = DispatchWorkItem { [weak self] in self?.hush() }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    // MARK: Choosing the moment

    /// The moments, in the order Luna would say them. Lows and highs first, because that is when a
    /// friend matters; small wins next; a plain hello last.
    fileprivate enum Pick: String {
        case lowNow
        case lowOver
        case highNow
        case backInRange
        case podFresh
        case sensorFresh
        case dosed
        case carbs
        case morningWin
        case nightSteady
        case longHaul
        case steady
        case hello
        case justBecause

        /// The matching line bank. The two enums share their names on purpose.
        var moment: SweetMirandaCheers.Moment { SweetMirandaCheers.Moment(rawValue: rawValue) ?? .justBecause }

        /// How long this one stays on screen. Company lingers; congratulations don't.
        var linger: TimeInterval {
            switch self {
            case .highNow,
                 .lowNow: return 14
            case .lowOver: return 12
            default: return 9
            }
        }

        /// Shortest time before Luna may use this moment again.
        var cooldown: TimeInterval {
            switch self {
            case .lowNow: return 30 * 60
            case .backInRange,
                 .lowOver: return 60 * 60
            case .highNow: return 90 * 60
            case .podFresh,
                 .sensorFresh: return 0 // re-armed by the device itself, below
            case .carbs,
                 .dosed: return 20 * 60
            case .morningWin,
                 .nightSteady: return 10 * 3600
            case .longHaul: return 4 * 3600
            case .steady: return 90 * 60
            case .hello: return 4 * 3600
            case .justBecause: return 3 * 3600
            }
        }
    }

    private func pick(_ f: SweetMirandaLunaFacts, opened: Bool, now: Date) -> Pick? {
        let hour = Calendar.current.component(.hour, from: now)
        // A reading older than 20 min says nothing about right now.
        let fresh = f.latest.flatMap { now.timeIntervalSince($0.date) < 20 * 60 ? $0 : nil }
        let recent = f.window(60, now: now)

        if let fresh, fresh.value < f.low, ready(.lowNow, now) { return .lowNow }

        if let fresh, f.inRange(fresh.value),
           f.window(45, now: now).contains(where: { $0.value < f.low }),
           ready(.lowOver, now) { return .lowOver }

        if let fresh, fresh.value > f.high,
           f.window(45, now: now).allSatisfy({ $0.value > f.high }),
           f.window(45, now: now).count >= 6,
           ready(.highNow, now) { return .highNow }

        if let fresh, f.inRange(fresh.value),
           recent.contains(where: { $0.value > f.high }),
           ready(.backInRange, now) { return .backInRange }

        if let changed = f.podChanged, now.timeIntervalSince(changed) < 90 * 60,
           !alreadyCheered(Key.podCheered, changed) { return .podFresh }

        if let changed = f.sensorChanged, now.timeIntervalSince(changed) < 90 * 60,
           !alreadyCheered(Key.sensorCheered, changed) { return .sensorFresh }

        if let at = f.lastBolus, now.timeIntervalSince(at) < 5 * 60, ready(.dosed, now) { return .dosed }
        if let at = f.lastCarbs, now.timeIntervalSince(at) < 5 * 60, ready(.carbs, now) { return .carbs }

        if (6 ..< 10).contains(hour), let fresh, f.inRange(fresh.value),
           share(inRange: f, since: startOfNight(now)) >= 0.8, ready(.morningWin, now) { return .morningWin }

        if (21 ..< 24).contains(hour),
           f.window(360, now: now).count >= 50,
           share(inRange: f, minutes: 360, now: now) >= 0.85,
           ready(.nightSteady, now) { return .nightSteady }

        let sixHours = f.window(360, now: now)
        if sixHours.count >= 55, sixHours.allSatisfy({ f.inRange($0.value) }), ready(.longHaul, now) { return .longHaul }

        let twoHours = f.window(120, now: now)
        if twoHours.count >= 18, twoHours.allSatisfy({ f.inRange($0.value) }), ready(.steady, now) { return .steady }

        if opened, defaults.integer(forKey: Key.helloCount) < helloCapPerDay, ready(.hello, now) { return .hello }
        if ready(.justBecause, now) { return .justBecause }
        return nil
    }

    // MARK: Small sums

    private func share(inRange f: SweetMirandaLunaFacts, minutes: Int, now: Date) -> Double {
        let w = f.window(minutes, now: now)
        guard !w.isEmpty else { return 0 }
        return Double(w.filter { f.inRange($0.value) }.count) / Double(w.count)
    }

    private func share(inRange f: SweetMirandaLunaFacts, since: Date) -> Double {
        let w = f.readings.filter { $0.date >= since }
        guard w.count >= 12 else { return 0 }
        return Double(w.filter { f.inRange($0.value) }.count) / Double(w.count)
    }

    /// Midnight-ish: the overnight stretch a morning verdict should be about.
    private func startOfNight(_ now: Date) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    // MARK: Memory

    private func ready(_ pick: Pick, _ now: Date) -> Bool {
        let map = defaults.dictionary(forKey: Key.shown) as? [String: Double] ?? [:]
        guard let last = map[pick.rawValue] else { return true }
        return now.timeIntervalSince1970 - last >= pick.cooldown
    }

    private func stamp(_ pick: Pick, now: Date) {
        var map = defaults.dictionary(forKey: Key.shown) as? [String: Double] ?? [:]
        map[pick.rawValue] = now.timeIntervalSince1970
        defaults.set(map, forKey: Key.shown)
    }

    /// A pod or sensor cheer is keyed to that device's own change time, so the next one re-arms it
    /// by itself and no cooldown has to guess.
    private func alreadyCheered(_ key: String, _ changed: Date) -> Bool {
        abs(defaults.double(forKey: key) - changed.timeIntervalSince1970) < 600
    }

    private func remember(_ pick: Pick, facts: SweetMirandaLunaFacts) {
        switch pick {
        case .podFresh:
            if let d = facts.podChanged { defaults.set(d.timeIntervalSince1970, forKey: Key.podCheered) }
        case .sensorFresh:
            if let d = facts.sensorChanged { defaults.set(d.timeIntervalSince1970, forKey: Key.sensorCheered) }
        default: break
        }
    }

    private func rollDayIfNeeded(now: Date = Date()) {
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        guard defaults.double(forKey: Key.dayStamp) != today else { return }
        defaults.set(today, forKey: Key.dayStamp)
        defaults.set(0, forKey: Key.dayCount)
        defaults.set(0, forKey: Key.helloCount)
        defaults.set(0, forKey: Key.fives)
        highFivesToday = 0
    }
}

// MARK: - Luna on screen

/// The corner Luna. Drag her anywhere; she remembers where she was put and tucks into the nearest
/// side so she never sits on top of the number Miranda is trying to read.
struct SweetMirandaLunaLayer: View {
    let facts: SweetMirandaLunaFacts

    @ObservedObject private var luna = SweetMirandaLuna.shared
    @AppStorage("sweetMiranda.luna.posX") private var posX: Double = 0.92
    @AppStorage("sweetMiranda.luna.posY") private var posY: Double = 0.22
    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var pawUp = false

    private let size: CGFloat = 54
    private let margin: CGFloat = 10
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let box = geo.size
            let home = CGPoint(
                x: min(max(posX * box.width, size / 2 + margin), box.width - size / 2 - margin),
                y: min(max(posY * box.height, size / 2 + margin), box.height - size / 2 - margin)
            )
            let at = CGPoint(x: home.x + drag.width, y: home.y + drag.height)
            // Speak toward the middle of the screen, so the bubble never runs off an edge.
            let speakLeft = at.x > box.width / 2
            let room = speakLeft
                ? at.x - size / 2 - 10 - margin
                : box.width - margin - (at.x + size / 2 + 10)
            let bubbleWidth = min(max(room, 132), 230)

            // The bubble is an OVERLAY on her face: overlays take no part in layout, so Luna
            // stays exactly where she was put whether she is talking or not.
            face
                .overlay(alignment: speakLeft ? .trailing : .leading) {
                    if let cheer = luna.cheer, !dragging {
                        bubble(cheer.text)
                            .frame(width: bubbleWidth, alignment: .leading)
                            .offset(x: speakLeft ? -(size + 10) : size + 10)
                            .transition(
                                .scale(scale: 0.6, anchor: speakLeft ? .trailing : .leading)
                                    .combined(with: .opacity)
                            )
                            .onTapGesture { luna.hush() }
                            .accessibilityLabel(cheer.text)
                    }
                }
                .position(at)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { v in
                            dragging = true
                            drag = v.translation
                        }
                        .onEnded { v in
                            let end = CGPoint(x: home.x + v.translation.width, y: home.y + v.translation.height)
                            // Tuck into whichever side she is nearer, like a picture-in-picture.
                            posX = end.x > box.width / 2 ? 0.92 : 0.08
                            posY = min(max(end.y / max(box.height, 1), 0.05), 0.95)
                            drag = .zero
                            dragging = false
                        }
                )
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: dragging)
        }
        .onAppear { luna.tick(facts, opened: true) }
        .onReceive(tick) { _ in luna.tick(facts) }
        .onChange(of: facts.latest?.date) { _, _ in luna.tick(facts) }
    }

    private var face: some View {
        Image("luna")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(SweetMirandaPalette.pinkSoft.opacity(0.9), lineWidth: 2))
            .overlay(alignment: .bottomTrailing) {
                if pawUp {
                    Text("🐾")
                        .font(.system(size: 20))
                        .offset(x: 4, y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
            .scaleEffect(dragging ? 1.12 : 1)
            .contentShape(Circle())
            .onTapGesture {
                luna.highFive()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { pawUp = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    withAnimation(.easeOut(duration: 0.25)) { pawUp = false }
                }
            }
            .accessibilityLabel(Text("Luna. Tap for a high five."))
            .accessibilityAddTraits(.isButton)
    }

    private func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(SweetMirandaPalette.ink)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(SweetMirandaPalette.pinkSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SweetMirandaPalette.pink.opacity(0.6), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }
}
