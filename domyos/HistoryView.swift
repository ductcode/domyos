//
//  HistoryView.swift
//  domyos
//
//  Lists the cycling workouts this app saved to Apple Health, with delete.
//

import HealthKit
import SwiftUI

struct HistoryView: View {
    @Environment(WorkoutStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.workouts.isEmpty {
                    ContentUnavailableView {
                        Label("No Rides Yet", systemImage: "bicycle")
                    } description: {
                        Text(store.statusMessage ?? "Record a ride to see it here.")
                    }
                } else {
                    List {
                        ForEach(store.workouts, id: \.uuid) { workout in
                            WorkoutRow(workout: workout)
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                }
            }
            .monospacedDigit()
            .navigationTitle("History")
            .overlay {
                if store.isLoading {
                    ProgressView()
                }
            }
            .task { await store.loadIfNeeded() }
            .refreshable { await store.refresh() }
        }
    }

    private func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { store.workouts[$0] }
        Task {
            for workout in toDelete {
                await store.delete(workout)
            }
        }
    }
}

private struct WorkoutRow: View {
    @Environment(WorkoutStore.self) private var store
    let workout: HKWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workout.startDate, format: .dateTime.weekday().day().month().hour().minute())
                .font(.headline)

            HStack(spacing: 12) {
                metric("timer", MetricFormatter.duration(workout.duration))
                if let distance = store.distanceMeters(for: workout) {
                    metric("point.topleft.down.curvedto.point.bottomright.up", MetricFormatter.distance(distance))
                }
                if let energy = store.energyKcal(for: workout) {
                    metric("flame.fill", MetricFormatter.energy(energy))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func metric(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
    }
}

#Preview {
    HistoryView()
        .environment(WorkoutStore())
}
