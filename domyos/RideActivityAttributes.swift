//
//  RideActivityAttributes.swift
//  domyos
//
//  Shared Live Activity model. Must belong to BOTH the app and the widget
//  extension targets so ActivityKit matches the same type across them.
//

import ActivityKit
import Foundation

// ActivityKit transfers these value types across concurrency boundaries.
nonisolated struct RideActivityAttributes: ActivityAttributes, Sendable {
    public nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// Workout start, used to drive a live-updating elapsed timer.
        var startDate: Date
        var powerWatts: Int?
        var cadenceRPM: Double?
        var speedKPH: Double?
        var heartRate: Int?
        var energyKcal: Double?
    }
}
