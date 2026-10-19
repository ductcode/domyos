//
//  DiagsView.swift
//  domyos
//
//  Plain FTMS diagnostics view showing every Indoor Bike Data field we currently parse.
//

import SwiftUI

struct DiagsView: View {
    private enum DiagnosticsMode: String, CaseIterable, Identifiable {
        case liveData = "Live Data"
        case capabilities = "Capabilities"
        case events = "Events"

        var id: String { rawValue }
    }

    /// Timestamps for the connection event log, e.g. "14:32:07.418".
    private static let eventTimeFormat: Date.FormatStyle = .dateTime
        .hour().minute().second().secondFraction(.fractional(3))

    @Environment(BikeManager.self) private var bikeManager
    @AppStorage("diagsShowEmptyFields") private var showEmptyFields = false
    @State private var mode: DiagnosticsMode = .liveData

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Diagnostics Mode", selection: $mode) {
                        ForEach(DiagnosticsMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                if mode == .events {
                    eventLogSection
                } else {
                    Section {
                        ForEach(entriesForSelectedMode) { entry in
                            diagnosticRow(entry)
                        }
                    }

                    if mode == .capabilities {
                        rawFTMSPacketSection
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Diagnostics")
            .toolbar {
                if mode == .events {
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        bikeManager.clearEventLog()
                    }
                    .disabled(bikeManager.eventLog.isEmpty)
                } else {
                    Toggle("Show Empty Fields", systemImage: "eye.slash", isOn: $showEmptyFields)
                }
            }
        }
    }

    private var entriesForSelectedMode: [DiagnosticEntry] {
        switch mode {
        case .capabilities:
            bikeManager.capabilities.diagnosticEntries()
        case .liveData:
            bikeManager.metrics.diagnosticEntries(includeEmpty: showEmptyFields)
        case .events:
            []
        }
    }

    private var rawFTMSPacketSection: some View {
        Section {
            Text(bikeManager.metrics.rawPayload ?? "No FTMS packet received yet.")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("Last Raw FTMS Packet")
        }
    }

    /// The connection event log, newest first, with a header noting how to export
    /// the same events off-device via the unified log.
    @ViewBuilder
    private var eventLogSection: some View {
        if bikeManager.eventLog.isEmpty {
            Section {
                Text("No connection events yet. Scan for a bike to start recording Bluetooth activity here.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(bikeManager.eventLog.reversed()) { entry in
                    eventRow(entry)
                }
            } footer: {
                Text("Also written to the unified log (subsystem de.howen.domyos, category bluetooth). Export with: log collect --device --last 30m")
            }
        }
    }

    private func eventRow(_ entry: ConnectionLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.date, format: Self.eventTimeFormat)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.message)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func diagnosticRow(_ entry: DiagnosticEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(entry.key)
                .font(.body.weight(.medium))
            Spacer(minLength: 12)
            Text(entry.value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DiagsView()
        .environment(BikeManager())
}
