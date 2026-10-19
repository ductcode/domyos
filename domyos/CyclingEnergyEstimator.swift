//
//  CyclingEnergyEstimator.swift
//  domyos
//
//  Converts cycling power into a gross metabolic energy estimate.
//

import Foundation

enum CyclingEnergyEstimator {
    static let mechanicalEfficiency = 0.24
    static let joulesPerKilocalorie = 4_184.0
    /// Approximate resting metabolic rate: about 1 kcal per kg of body mass per hour.
    static let restingKcalPerKilogramPerHour = 1.0

    static func kilocalories(
        powerWatts: Double,
        duration: TimeInterval,
        bodyMassKilograms: Double
    ) -> Double {
        guard duration > 0 else { return 0 }
        let mechanical = powerWatts > 0
            ? (powerWatts * duration) / (joulesPerKilocalorie * mechanicalEfficiency)
            : 0
        let resting = bodyMassKilograms * restingKcalPerKilogramPerHour * (duration / 3_600)
        return mechanical + resting
    }
}
