import Combine
import LoopKit
import SwiftUI

/// Where Miranda tells Trio when she put her sensor on.
///
/// One tap covers the normal case ("I changed it just now"); the date picker covers
/// "I forgot to say so yesterday". Everything else on the screen is read-only feedback
/// so she can see immediately that the countdown believes her.
struct SweetMirandaSensorSessionView: View {
    @ObservedObject private var session = SweetMirandaSensorSession.shared

    /// Drives the picker independently of the stored value so an in-progress edit
    /// never writes a half-finished date.
    @State private var draft = Date()
    @State private var showConfirmChange = false

    /// Re-renders the countdown on the minute so "6 days left" doesn't go stale
    /// while she's looking at it.
    @State private var now = Date()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section(header: Text("Current sensor")) {
                if session.startedAt != nil {
                    statusRows
                } else {
                    Text("No sensor start date yet, so the countdown ring on the home screen stays empty.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Text("I put a new sensor on")) {
                Button {
                    showConfirmChange = true
                } label: {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        Text("I changed it just now")
                        Spacer()
                    }
                    .frame(minHeight: 44)
                    .font(.title3)
                }

                DatePicker(
                    "Or pick the day",
                    selection: $draft,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .frame(minHeight: 44)

                Button {
                    session.startedAt = draft
                } label: {
                    Text("Save that date")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!session.isPlausible(draft, now: now))
            }

            Section(header: Text("How long a sensor lasts")) {
                Stepper(
                    value: $session.lifetimeDays,
                    in: 1 ... 30,
                    step: 1
                ) {
                    Text("\(Int(session.lifetimeDays)) days")
                }
                .frame(minHeight: 44)
                Text("A Dexcom G6 sensor runs for 10 days.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if session.startedAt != nil {
                Section {
                    Button(role: .destructive) {
                        session.clear()
                    } label: {
                        Text("Clear the sensor date")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } footer: {
                    Text("Clearing it only empties the countdown. It never changes glucose, insulin or the pod.")
                }
            }
        }
        .navigationTitle("Sensor change")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear { draft = session.startedAt ?? Date() }
        .onReceive(tick) { now = $0 }
        .confirmationDialog(
            "Start a new 10-day sensor session from right now?",
            isPresented: $showConfirmChange,
            titleVisibility: .visible
        ) {
            Button("Yes, I just changed it") { session.markChangedNow() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusRows: some View {
        if let started = session.startedAt {
            LabeledContent("Put on") {
                Text(started.formatted(date: .abbreviated, time: .shortened))
            }
        }
        if let expires = session.expiresAt {
            LabeledContent("Ends") {
                Text(expires.formatted(date: .abbreviated, time: .shortened))
            }
        }
        if let remaining = session.timeRemaining {
            LabeledContent("Time left") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                    Text(
                        remaining > 0
                            ? SensorRemainingTimeFormatter.format(until: session.expiresAt ?? now, now: now)
                            : String(localized: "Expired", comment: "Sensor session has run out")
                    )
                    .foregroundStyle(statusColor)
                }
            }
        }
        if let percent = session.percentComplete(now: now) {
            ProgressView(value: percent)
                .tint(statusColor)
                .padding(.vertical, 4)
        }
    }

    /// Mirrors `SensorLifecycleArcView.arcColor` so this screen and the home arc can
    /// never disagree about what colour "nearly done" is.
    private var statusColor: Color {
        switch session.progressState(now: now) {
        case .some(.critical):
            return Color.loopRed
        case .some(.warning):
            return Color.orange
        default:
            return Color.loopGreen
        }
    }
}
