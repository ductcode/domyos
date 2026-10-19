//
//  StatsView.swift
//  domyos
//
//  Aggregate totals across the cycling workouts this app saved.
//

import HealthKit
import SwiftUI

struct StatsView: View {
    @Environment(WorkoutStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.workouts.isEmpty {
                    ContentUnavailableView {
                        Label("No Stats Yet", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text(store.statusMessage ?? "Record a ride to build up your totals.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ], spacing: 12) {
                            MetricCard(title: "Rides", value: "\(store.workouts.count)", systemImage: "number")
                            MetricCard(title: "Total Time", value: totalTimeText, systemImage: "timer")
                            MetricCard(title: "Total Distance", value: totalDistanceText, systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            MetricCard(title: "Total Energy", value: MetricFormatter.energy(totalEnergyKcal), systemImage: "flame.fill")
                        }
                        .padding(20)
                    }
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("Stats")
            .task { await store.loadIfNeeded() }
        }
    }

    private var totalDurationSeconds: Double {
        store.workouts.reduce(0) { $0 + $1.duration }
    }

    private var totalDistanceMeters: Double {
        store.workouts.reduce(0) { $0 + (store.distanceMeters(for: $1) ?? 0) }
    }

    private var totalEnergyKcal: Double {
        store.workouts.reduce(0) { $0 + (store.energyKcal(for: $1) ?? 0) }
    }

    private var totalTimeText: String {
        MetricFormatter.compactDuration(totalDurationSeconds)
    }

    private var totalDistanceText: String {
        let meters = totalDistanceMeters
        return MetricFormatter.distance(meters, kilometerDecimals: 1)
    }
}

#Preview {
    StatsView()
        .environment(WorkoutStore())
}
