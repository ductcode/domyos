//
//  WorkoutStore.swift
//  domyos
//
//  Reads and deletes the cycling workouts this app saved to Apple Health.
//

import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class WorkoutStore {
    private(set) var workouts: [HKWorkout] = []
    private(set) var statusMessage: String?
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private let distanceType = HKQuantityType(.distanceCycling)
    @ObservationIgnored private let energyType = HKQuantityType(.activeEnergyBurned)

    /// Loads saved workouts only once for passive view appearances.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    /// Requests read access and loads this app's cycling workouts, newest first.
    func refresh() async {
        guard isAvailable else {
            statusMessage = "Apple Health is not available on this device."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            // Share (write) access is required to delete workouts this app saved.
            try await healthStore.requestAuthorization(
                toShare: [HKWorkoutType.workoutType()],
                read: [HKWorkoutType.workoutType()]
            )

            // Limit to cycling workouts written by this app so deletes always succeed.
            let predicate = HKSamplePredicate.workout(
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    HKQuery.predicateForObjects(from: .default()),
                    HKQuery.predicateForWorkouts(with: .cycling)
                ])
            )

            let descriptor = HKSampleQueryDescriptor(
                predicates: [predicate],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
            )

            workouts = try await descriptor.result(for: healthStore)
            hasLoaded = true
            statusMessage = workouts.isEmpty ? "No rides saved yet." : nil
        } catch {
            statusMessage = "Could not load workouts: \(error.localizedDescription)"
        }
    }

    /// Deletes a workout from the HealthKit store and updates the local list.
    /// Only removes it locally once HealthKit confirms the delete succeeded, so a
    /// silently-rejected delete doesn't make the row vanish and then reappear.
    func delete(_ workout: HKWorkout) async {
        do {
            let deleted: Bool = try await withCheckedThrowingContinuation { continuation in
                healthStore.delete(workout) { success, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }

            if deleted {
                workouts.removeAll { $0.uuid == workout.uuid }
                if workouts.isEmpty { statusMessage = "No rides saved yet." }
            } else {
                statusMessage = "Apple Health didn't allow deleting this workout."
            }
        } catch {
            statusMessage = "Could not delete the workout: \(error.localizedDescription)"
        }
    }

    // MARK: - Per-workout metrics

    func distanceMeters(for workout: HKWorkout) -> Double? {
        workout.statistics(for: distanceType)?
            .sumQuantity()?
            .doubleValue(for: .meter())
    }

    func energyKcal(for workout: HKWorkout) -> Double? {
        workout.statistics(for: energyType)?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())
    }

    // MARK: - Aggregate history metrics

    /// Recorded distances (metres) across saved rides.
    private var distances: [Double] { workouts.compactMap { distanceMeters(for: $0) } }
    /// Recorded energies (kcal) across saved rides.
    private var energies: [Double] { workouts.compactMap { energyKcal(for: $0) } }
    /// Durations (seconds) across saved rides.
    private var durations: [Double] { workouts.map(\.duration) }

    var averageDistanceMeters: Double? { distances.average }
    var maxDistanceMeters: Double? { distances.max() }
    var averageEnergyKcal: Double? { energies.average }
    var maxEnergyKcal: Double? { energies.max() }
    var averageDurationSeconds: Double? { durations.average }
    var maxDurationSeconds: Double? { durations.max() }
}

private extension Array where Element == Double {
    /// Arithmetic mean, or nil when empty.
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}
