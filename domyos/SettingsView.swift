//
//  SettingsView.swift
//  domyos
//
//  Device connection management, recording preferences, and app info.
//

import SwiftUI

struct SettingsView: View {
    @Environment(BikeManager.self) private var bikeManager
    @Environment(RiderProfile.self) private var riderProfile
    @AppStorage(WorkoutRecorder.autoStartDefaultsKey) private var autoStartEnabled = true
    @AppStorage(WorkoutRecorder.inactivityTimeoutDefaultsKey) private var inactivityTimeout = 30
    @AppStorage(RiderProfile.manualWeightDefaultsKey) private var manualWeight = 0.0
    @FocusState private var isWeightFieldFocused: Bool

    private let timeoutOptions = [15, 30, 45, 60, 120]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let healthKilograms = riderProfile.healthKilograms {
                        LabeledContent("From Apple Health", value: weightText(healthKilograms))
                    } else {
                        TextField(
                            "Weight (kg)",
                            value: $manualWeight,
                            format: .number.precision(.fractionLength(0...1))
                        )
                        .keyboardType(.decimalPad)
                        .focused($isWeightFieldFocused)
                    }
                } header: {
                    Text("Body Weight")
                } footer: {
                    Text(weightFooter)
                }

                Section {
                    LabeledContent("Status", value: bikeManager.connectionState.title)
                    if let deviceName = bikeManager.deviceName, bikeManager.connectionState == .connected {
                        LabeledContent("Connected To", value: deviceName)
                    }

                    deviceButton
                } header: {
                    Text("Device")
                } footer: {
                    Text(bikeManager.statusMessage)
                }

                Section {
                    Toggle("Auto-Start Recording", isOn: $autoStartEnabled)
                    Picker("Auto-Stop After", selection: $inactivityTimeout) {
                        ForEach(timeoutOptions, id: \.self) { seconds in
                            Text(timeoutLabel(seconds)).tag(seconds)
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Auto-start begins a workout once you start pedaling after the bike connects. The workout auto-stops after the selected time with no activity (or when the bike disconnects), and idle time is excluded from the saved workout.")
                }

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Active energy is saved from the bike's FTMS total energy reading. The Ride screen also shows a secondary app estimate based on power, time, and your body weight for comparison.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isWeightFieldFocused = false }
                }
            }
            .task {
                bikeManager.startAutomaticDiscoveryIfPossible()
                await riderProfile.refresh()
            }
        }
    }

    /// A single button that reflects the connection state: connect/scan when idle,
    /// a cancel/disconnect action while connecting or connected.
    @ViewBuilder
    private var deviceButton: some View {
        switch bikeManager.connectionState {
        case .connected:
            Button {
                bikeManager.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .connecting:
            Button {
                bikeManager.disconnect()
            } label: {
                Label("Cancel Connecting", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .scanning:
            Button {
                bikeManager.stopScan()
            } label: {
                Label("Stop Scanning", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        default:
            Button {
                bikeManager.startScan()
            } label: {
                Label("Scan for Bike", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!bikeManager.canStartScan)
        }
    }

    private func timeoutLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) sec" : "\(seconds / 60) min"
    }

    private func weightText(_ kilograms: Double) -> String {
        MetricFormatter.weight(kilograms)
    }

    private var weightFooter: String {
        switch riderProfile.weightSource {
        case .health:
            "Using your weight from Apple Health with power and time to estimate calories burned. Update it in the Health app if it's out of date."
        case .manual:
            "Using the weight entered here. It's used with power and time to estimate calories burned."
        case .default:
            "No weight found in Apple Health — enter yours to improve calorie estimates. Until then \(weightText(RiderProfile.defaultWeightKilograms)) is assumed."
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(BikeManager())
        .environment(RiderProfile())
}
