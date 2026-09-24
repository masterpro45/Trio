import SwiftUI

/// The approval sheet: what Sweet Miranda proposes, line by line, and two buttons.
/// Approve asks for Face ID / passcode through `UnlockManager` before anything changes.
struct SweetMirandaProposalView: View {
    @ObservedObject var manager: BaseSweetMirandaSyncManager
    let proposal: SMProposal
    let lines: [SMChangeLine]

    @Environment(\.dismiss) private var dismiss

    private var grouped: [(String, [SMChangeLine])] {
        let order = ["Therapy", "Limits", "Algorithm", "Trio"]
        let dict = Dictionary(grouping: lines, by: \.group)
        return order.compactMap { g in dict[g].map { (g, $0) } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("From \(proposal.from)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if !proposal.note.isEmpty {
                            Text(proposal.note)
                                .font(.body)
                        }
                        if let created = proposal.createdAt {
                            Text("Sent \(created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                ForEach(grouped, id: \.0) { group, items in
                    Section(group) {
                        ForEach(items) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.label).font(.headline)
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line.from)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .strikethrough()
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 3)
                                    Text(line.to)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let error = manager.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        manager.approve(proposal)
                    } label: {
                        HStack {
                            Spacer()
                            if manager.busy {
                                ProgressView().padding(.trailing, 6)
                            }
                            Label("Approve with Face ID", systemImage: "faceid")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(manager.busy)

                    Button(role: .destructive) {
                        manager.decline(proposal)
                    } label: {
                        HStack { Spacer()
                            Text("Decline")
                            Spacer() }
                    }
                    .disabled(manager.busy)
                } footer: {
                    Text(
                        "Nothing changes until you approve. Basal and pump limits are sent to the pod first; if the pod refuses, nothing is applied. Sweet Miranda is told either way."
                    )
                }
            }
            .navigationTitle("New settings from Sweet Miranda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                        .disabled(manager.busy)
                }
            }
        }
        .interactiveDismissDisabled(manager.busy)
        .onDisappear { manager.sheetDismissed() }
    }
}
