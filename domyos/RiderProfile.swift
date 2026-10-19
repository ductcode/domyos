//
//  RiderProfile.swift
//  domyos
//
//  Supplies the rider's body mass — read from Apple Health when available,
//  with a manual Settings entry as a fallback — for weight-aware FTMS math.
//

import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class RiderProfile {
    /// UserDefaults key backing the manual body-mass entry (kilograms).
    static let manualWeightDefaultsKey = "manualBodyMassKilograms"
    /// Used only when Apple Health has no sample and the rider hasn't entered one.
    static let defaultWeightKilograms = 75.0

    enum WeightSource {
        case health, manual, `default`
    }

    /// Most recent body mass read from Apple Health, in kilograms (nil until fetched).
    private(set) var healthKilograms: Double?
    private(set) var statusMessage: String?

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private let bodyMassType = HKQuantityType(.bodyMass)

    /// Manual fallback weight the rider typed in Settings, in kilograms (nil if unset).
    var manualKilograms: Double? {
        get {
            let value = UserDefaults.standard.double(forKey: Self.manualWeightDefaultsKey)
            return value > 0 ? value : nil
        }
        set {
            if let newValue, newValue > 0 {
                UserDefaults.standard.set(newValue, forKey: Self.manualWeightDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.manualWeightDefaultsKey)
            }
        }
    }

    /// The weight FTMS calculations should use. Apple Health takes precedence,
    /// then the manual Settings entry, then a sensible default.
    var weightKilograms: Double {
        healthKilograms ?? manualKilograms ?? Self.defaultWeightKilograms
    }

    /// Where `weightKilograms` currently comes from, for display in Settings.
    var weightSource: WeightSource {
        if healthKilograms != nil { return .health }
        if manualKilograms != nil { return .manual }
        return .default
    }

    /// Requests read access and loads the most recent body-mass sample from Apple Health.
    /// A denied or empty result simply leaves `healthKilograms` nil so the fallback applies.
    func refresh() async {
        guard isAvailable else {
            statusMessage = "Apple Health is not available on this device."
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: [bodyMassType])
        } catch {
            statusMessage = "Health permission failed: \(error.localizedDescription)"
            return
        }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: bodyMassType)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )

        do {
            let sample = try await descriptor.result(for: healthStore).first
            healthKilograms = sample?.quantity.doubleValue(for: .gramUnit(with: .kilo))
            statusMessage = nil
        } catch {
            // Reading may be denied without throwing; a nil result just falls back.
            statusMessage = "Could not read weight from Apple Health: \(error.localizedDescription)"
        }
    }
}
