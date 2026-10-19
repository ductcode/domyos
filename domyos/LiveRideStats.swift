//
//  LiveRideStats.swift
//  domyos
//
//  Snapshot of running aggregates for the live Ride dashboard.
//

import Foundation

struct LiveRideStats: Sendable {
    var elapsed: TimeInterval = 0
    var energyKcal: Double = 0
    var estimatedEnergyKcal: Double = 0
    var avgPower: Int?
    var maxPower: Int?
    var avgCadence: Double?
    var maxCadence: Double?
    var avgSpeed: Double?
    var maxSpeed: Double?
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var avgResistance: Double?
    var maxResistance: Double?
}
