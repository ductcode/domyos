//
//  DomyosWidgetLiveActivity.swift
//  DomyosWidget
//
//  Recording indicator for the Dynamic Island and Lock Screen.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct DomyosWidgetLiveActivity: Widget {
    /// Opacity applied to metric values once the Live Activity content is stale.
    private let staleOpacity: Double = 0.4

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            // Lock Screen / banner presentation: elapsed time and calories.
            HStack(spacing: 16) {
                Image(systemName: "figure.indoor.cycle")
                    .font(.title2)
                    .foregroundStyle(.pink)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording Ride")
                        .font(.headline)
                    Text(context.state.startDate, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(caloriesText(context.state), systemImage: "flame.fill")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.orange)
                    // Dim when the metrics have gone stale (no fresh data arriving).
                    .opacity(context.isStale ? staleOpacity : 1)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.5))
            .activitySystemActionForegroundColor(Color.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    metric("bolt.fill", powerText(context.state))
                        .opacity(context.isStale ? staleOpacity : 1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    metric("heart.fill", heartRateText(context.state))
                        .opacity(context.isStale ? staleOpacity : 1)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.startDate, style: .timer)
                        .font(.title3.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.pink)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        metric("gauge.with.dots.needle.50percent", cadenceText(context.state))
                        Spacer()
                        metric("speedometer", speedText(context.state))
                    }
                    .opacity(context.isStale ? staleOpacity : 1)
                }
            } compactLeading: {
                Label(compactCadence(context.state), systemImage: "gauge.with.dots.needle.50percent")
                    .font(.caption2.monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .opacity(context.isStale ? staleOpacity : 1)
            } compactTrailing: {
                Label(compactHeartRate(context.state), systemImage: "heart.fill")
                    .font(.caption2.monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.pink)
                    .opacity(context.isStale ? staleOpacity : 1)
            } minimal: {
                Image(systemName: "figure.indoor.cycle")
                    .foregroundStyle(.pink)
            }
            .keylineTint(.pink)
        }
    }

    private func metric(_ systemImage: String, _ value: String) -> some View {
        Label(value, systemImage: systemImage)
            .font(.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
    }

    private func powerText(_ state: RideActivityAttributes.ContentState) -> String {
        MetricFormatter.powerWithPlaceholderUnit(state.powerWatts)
    }

    private func heartRateText(_ state: RideActivityAttributes.ContentState) -> String {
        MetricFormatter.heartRateWithPlaceholderUnit(state.heartRate)
    }

    private func cadenceText(_ state: RideActivityAttributes.ContentState) -> String {
        MetricFormatter.cadenceWholeWithUnit(state.cadenceRPM)
    }

    private func speedText(_ state: RideActivityAttributes.ContentState) -> String {
        MetricFormatter.speedWithPlaceholderUnit(state.speedKPH)
    }

    private func caloriesText(_ state: RideActivityAttributes.ContentState) -> String {
        MetricFormatter.energyWithPlaceholderUnit(state.energyKcal)
    }

    // Unit-less variants for the narrow Dynamic Island pill.
    private func compactCadence(_ state: RideActivityAttributes.ContentState) -> String {
        MetricFormatter.cadenceWhole(state.cadenceRPM)
    }

    private func compactHeartRate(_ state: RideActivityAttributes.ContentState) -> String {
        state.heartRate.map { "\($0)" } ?? "--"
    }
}

extension RideActivityAttributes {
    fileprivate static var preview: RideActivityAttributes {
        RideActivityAttributes()
    }
}

extension RideActivityAttributes.ContentState {
    fileprivate static var sample: RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            startDate: .now,
            powerWatts: 165,
            cadenceRPM: 88,
            speedKPH: 30.4,
            heartRate: 138,
            energyKcal: 142
        )
    }
}

#Preview("Notification", as: .content, using: RideActivityAttributes.preview) {
    DomyosWidgetLiveActivity()
} contentStates: {
    RideActivityAttributes.ContentState.sample
}
