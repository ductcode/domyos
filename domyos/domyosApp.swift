//
//  domyosApp.swift
//  domyos
//
//  Created by Georg von der Howen on 24.07.26.
//

import SwiftUI
import UIKit

@main
struct domyosApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var bikeManager = BikeManager()
    @State private var workoutRecorder = WorkoutRecorder()
    @State private var workoutStore = WorkoutStore()
    @State private var riderProfile = RiderProfile()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(bikeManager)
                .environment(workoutRecorder)
                .environment(workoutStore)
                .environment(riderProfile)
                .task {
                    // Load the rider's weight from Apple Health so energy estimates
                    // reflect their body mass; falls back to a manual entry if absent.
                    async let riderProfileLoad: Void = riderProfile.refresh()
                    async let workoutHistoryLoad: Void = workoutStore.loadIfNeeded()
                    _ = await (riderProfileLoad, workoutHistoryLoad)
                }
                .onAppear {
                    // Feed every parsed FTMS packet into the recorder, which records
                    // it or auto-starts a workout once the rider gets going.
                    bikeManager.metricsHandler = { metrics in
                        workoutRecorder.receive(metrics)
                    }
                    // Arm auto-start each time a bike connects.
                    bikeManager.onConnect = {
                        workoutRecorder.armAutoStart()
                    }
                    // Auto-stop and save if the bike disconnects for good.
                    bikeManager.onDisconnect = {
                        workoutRecorder.handleDisconnect()
                    }
                    // On an unexpected drop, keep the ride open while Bluetooth
                    // silently reconnects instead of ending it immediately.
                    bikeManager.onConnectionInterrupted = {
                        workoutRecorder.handleConnectionInterrupted()
                    }
                    // Let the recorder read the latest body mass for energy estimates.
                    workoutRecorder.currentBodyMassKilograms = { riderProfile.weightKilograms }
                    // Keep history-backed Ride tiles current without requiring a
                    // manual visit to the History screen.
                    workoutRecorder.onWorkoutSaved = {
                        await workoutStore.refresh()
                    }

                    #if targetEnvironment(simulator)
                    // No Bluetooth in the Simulator — drive the UI with mock data.
                    bikeManager.startSimulatedRide()
                    #endif

                    UIApplication.shared.isIdleTimerDisabled = workoutRecorder.isRecording
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        // Back on screen: inactivity should prompt, not silently stop.
                        workoutRecorder.handleAppForeground()
                        // Re-arm auto-reconnect if we released the bike while pocketed.
                        bikeManager.handleAppForeground()
                    case .background:
                        // Keep an active ride recording when the screen locks — the
                        // Live Activity keeps it on the Lock Screen. Flush buffered
                        // samples, and from now an inactivity timeout auto-stops the
                        // ride (no prompt can show while backgrounded).
                        workoutRecorder.handleAppBackground()
                        // With no ride in progress, release the bike so this phone
                        // stops holding/stealing the single-connection machine while
                        // it's idle in a pocket. A ride in progress keeps its link.
                        bikeManager.handleAppBackground(isRecording: workoutRecorder.isRecording)
                    case .inactive:
                        // Ignore transient interruptions (Control Center, the app
                        // switcher, call banners) so they don't disturb the ride.
                        break
                    @unknown default:
                        break
                    }
                }
                .onChange(of: workoutRecorder.isRecording, initial: true) { _, isRecording in
                    UIApplication.shared.isIdleTimerDisabled = isRecording
                }
        }
    }
}
