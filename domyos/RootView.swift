//
//  RootView.swift
//  domyos
//
//  Top-level tab navigation.
//

import SwiftUI

struct RootView: View {
    enum AppTab: Hashable {
        case ride, history, stats, diags, settings
    }

    @Environment(BikeManager.self) private var bikeManager
    @Environment(WorkoutRecorder.self) private var workoutRecorder

#if targetEnvironment(simulator)
    // No Bluetooth in the Simulator — start on the Ride screen for layout work.
    @State private var selectedTab: AppTab = .ride
#else
    // Open on Settings at launch (nothing is connected yet).
    @State private var selectedTab: AppTab = .settings
#endif
    @State private var isShowingInactivityAlert = false
    @State private var isRideTabBarHidden = false

    private var isConnected: Bool {
#if targetEnvironment(simulator)
        true
#else
        bikeManager.connectionState == .connected
#endif
    }

    /// Wraps the tab selection so that re-tapping the Ride tab while it is already
    /// showing toggles recording: stop an in-progress ride, or start a new one.
    private var selection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .ride && selectedTab == .ride {
                    toggleRecording()
                }
                selectedTab = newValue
            }
        )
    }

    private func toggleRecording() {
        if workoutRecorder.isRecording {
            Task { await workoutRecorder.stopRecording(reason: .manual) }
        } else {
            Task { await workoutRecorder.startRecording() }
        }
    }

    private func hidesTabBarForRide(isLandscape: Bool) -> Bool {
        selectedTab == .ride && isLandscape && isRideTabBarHidden
    }

    private func toggleRideTabBarVisibility(isLandscape: Bool) {
        guard selectedTab == .ride, isLandscape else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isRideTabBarHidden.toggle()
        }
    }

    private var stopAndSaveButtonTitle: String {
        if let seconds = workoutRecorder.inactivityAlertRemainingSeconds {
            return "Stop and Save Workout (\(seconds)s)"
        }
        return "Stop and Save Workout"
    }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            TabView(selection: selection) {
                Tab("Ride", systemImage: "figure.indoor.cycle", value: .ride) {
                    RideView(onBackgroundTap: { toggleRideTabBarVisibility(isLandscape: isLandscape) })
                        .toolbar(hidesTabBarForRide(isLandscape: isLandscape) ? .hidden : .visible, for: .tabBar)
                }

                Tab("History", systemImage: "list.bullet.rectangle", value: .history) {
                    HistoryView()
                }

                Tab("Stats", systemImage: "chart.bar.xaxis", value: .stats) {
                    StatsView()
                }

                Tab("Diags", systemImage: "list.bullet.clipboard", value: .diags) {
                    DiagsView()
                }

                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    SettingsView()
                }
            }
            .tint(workoutRecorder.isRecording ? .red : Color.accentColor)
            .onChange(of: isLandscape, initial: true) { _, isLandscape in
                if !isLandscape {
                    isRideTabBarHidden = false
                }
            }
        }
        .onChange(of: workoutRecorder.isPresentingInactivityAlert, initial: true) { _, isPresenting in
            isShowingInactivityAlert = isPresenting
        }
        .onChange(of: isConnected) { _, connected in
            // Jump to the ride when a bike connects; leave it when it disconnects.
            if connected {
                selectedTab = .ride
            } else if selectedTab == .ride {
                selectedTab = .settings
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab != .ride {
                isRideTabBarHidden = false
            }
        }
        .alert("No Activity Detected", isPresented: $isShowingInactivityAlert) {
            Button("Keep Recording") {
                workoutRecorder.continueAfterInactivityAlert()
            }
            Button("Pause Workout") {
                workoutRecorder.pauseAfterInactivityAlert()
            }
            Button(stopAndSaveButtonTitle) {
                workoutRecorder.stopAfterInactivityAlert()
            }
        } message: {
            Text("No pedaling was detected for \(Int(workoutRecorder.inactivityTimeoutDuration)) seconds. You can keep recording, pause until pedaling resumes, or stop and save the workout.")
        }
    }
}

#Preview {
    RootView()
        .environment(BikeManager())
        .environment(WorkoutRecorder())
        .environment(WorkoutStore())
        .environment(RiderProfile())
}
