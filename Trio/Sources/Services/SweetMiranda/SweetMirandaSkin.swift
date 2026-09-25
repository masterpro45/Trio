import LoopKit
import SwiftUI
import Swinject

/// Namespace for Miranda's own screens, mirroring Trio's `enum Home { }` module pattern.
enum SweetMiranda {}

/// Sweet Miranda's own look, and the switch that turns it on.
///
/// Miranda asked for a home screen she actually wants to open: pink, one big button to eat
/// and dose, alerts and history beside it, little depth-shaded status orbs on top that fade
/// as the pod and sensor run out.
///
/// The switch matters as much as the skin. Stock `HomeRootView` is left completely untouched,
/// so this is additive: if anything ever looks wrong on her phone she can flip back to the
/// Trio everyone else runs, without waiting for a new build.
final class SweetMirandaSkin: ObservableObject {
    static let shared = SweetMirandaSkin()

    private enum Key {
        static let enabled = "sweetMiranda.skin.enabled"
    }

    private let defaults: UserDefaults

    /// Off unless she turns it on, so a fresh install always starts on stock Trio.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
    }
}

// MARK: - Palette

/// A near-black plum ground with hot pink on top. Deliberately dark: it reads the way she
/// wanted, and it keeps text contrast easy at the sizes a phone actually shows.
///
/// 🚨 Pink is a FILL colour, never a background for white text — white on `#FF4D9D` is about
/// 2.6:1 and fails. Anything sitting on pink uses `Ink`.
enum SweetMirandaPalette {
    static let ground = Color(red: 0.078, green: 0.039, blue: 0.071) // #140A12
    static let card = Color.white.opacity(0.055)
    static let cardStrong = Color.white.opacity(0.075)

    static let pink = Color(red: 1.0, green: 0.302, blue: 0.616) // #FF4D9D
    static let pinkDeep = Color(red: 0.714, green: 0.173, blue: 0.431) // #B62C6E
    static let pinkSoft = Color(red: 1.0, green: 0.639, blue: 0.808) // #FFA3CE
    static let lilac = Color(red: 0.780, green: 0.490, blue: 1.0) // #C77DFF
    static let mint = Color(red: 0.239, green: 0.863, blue: 0.592) // #3DDC97
    static let amber = Color(red: 1.0, green: 0.761, blue: 0.278) // #FFC247
    static let red = Color(red: 1.0, green: 0.420, blue: 0.420) // #FF6B6B

    /// Ink for anything drawn on a pink or mint fill.
    static let ink = Color(red: 0.165, green: 0.039, blue: 0.094) // #2A0A18
    static let text = Color(red: 1.0, green: 0.961, blue: 0.980) // #FFF5FA
    static let muted = Color(red: 0.725, green: 0.639, blue: 0.706) // #B9A3B4

    static let display = "Bricolage Grotesque"

    /// Glucose colour, using the thresholds Trio already knows rather than new ones.
    static func glucoseColor(_ value: Int, low: Decimal, high: Decimal) -> Color {
        let v = Decimal(value)
        if v < low { return red }
        if v > high { return amber }
        return mint
    }
}

// MARK: - Status orb

/// One depth-shaded status orb: a draining ring, a lit sphere, a specular highlight.
///
/// The colour is the point. It fades mint → amber → red as whatever it is counting gets
/// closer to needing a change, which is the thing Miranda asked for by name.
struct SweetMirandaOrb: View {
    let value: Double
    let maximum: Double
    let label: String
    let caption: String
    /// Supplied when the countdown carries its own state (the sensor session, the pod clock)
    /// so the orb never invents a colour the rest of the app disagrees with.
    var state: DeviceLifecycleProgressState?

    private var fraction: Double {
        guard maximum > 0 else { return 0 }
        return max(0, min(1, value / maximum))
    }

    private var tint: (ring: Color, lit: Color, dark: Color) {
        switch state ?? fallbackState {
        case .critical:
            return (SweetMirandaPalette.red,
                    Color(red: 1.0, green: 0.62, blue: 0.62),
                    Color(red: 0.557, green: 0.122, blue: 0.122))
        case .warning:
            return (SweetMirandaPalette.amber,
                    Color(red: 1.0, green: 0.851, blue: 0.541),
                    Color(red: 0.541, green: 0.369, blue: 0.0))
        default:
            return (SweetMirandaPalette.mint,
                    Color(red: 0.553, green: 0.941, blue: 0.769),
                    Color(red: 0.071, green: 0.447, blue: 0.298))
        }
    }

    /// Used only when no lifecycle state was handed in: thirds of whatever is being counted.
    private var fallbackState: DeviceLifecycleProgressState {
        if fraction <= 0.10 { return .critical }
        if fraction <= 0.30 { return .warning }
        return .normalCGM
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 6)
                    .frame(width: 50, height: 50)

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint.ring, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.dark.opacity(0.85), radius: 4, y: 3)
                    .animation(.easeInOut(duration: 0.3), value: fraction)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.lit, tint.dark],
                            center: UnitPoint(x: 0.36, y: 0.28),
                            startRadius: 1,
                            endRadius: 30
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay(alignment: .topLeading) {
                        Ellipse()
                            .fill(Color.white.opacity(0.4))
                            .frame(width: 14, height: 9)
                            .rotationEffect(.degrees(-28))
                            .offset(x: 4, y: 3)
                    }

                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(SweetMirandaPalette.ink)
            }
            .frame(height: 52)

            Text(caption)
                .font(.system(size: 10, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(SweetMirandaPalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(SweetMirandaPalette.card, in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(caption): \(label)")
    }
}

// MARK: - Home switch

/// Chooses between Miranda's home screen and stock Trio's, and observes the toggle so the
/// swap happens the moment she flips it rather than on the next launch.
struct SweetMirandaHomeSwitch: View {
    let resolver: Resolver

    @ObservedObject private var skin = SweetMirandaSkin.shared

    var body: some View {
        if skin.isEnabled {
            SweetMiranda.HomeView(resolver: resolver)
        } else {
            Home.RootView(resolver: resolver)
        }
    }
}
