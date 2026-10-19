//
//  RideView.swift
//  domyos
//
//  Live FTMS metrics dashboard. A fixed, non-scrolling 8-panel grid (2 columns ×
//  4 rows) that fills the screen. Recording is fully automatic; connection is
//  managed in Settings.
//

import SwiftUI
import UIKit

/// The eight metrics shown on the Ride dashboard. The raw values are the stable
/// keys used to persist a custom tile order.
enum RideTile: String, CaseIterable, Identifiable {
    case power, cadence, speed, heartRate, distance, calories, time, resistance

    var id: String { rawValue }

    /// Classic 6-color Pride flag followed by the 4 non-binary flag colors.
    static let pridePaletteColors: [Color] = [
        Color(red: 0.89, green: 0.01, blue: 0.01),
        Color(red: 1.0, green: 0.55, blue: 0.0),
        Color(red: 1.0, green: 0.93, blue: 0.0),
        Color(red: 0.0, green: 0.5, blue: 0.15),
        Color(red: 0.0, green: 0.3, blue: 1.0),
        Color(red: 0.46, green: 0.03, blue: 0.53),
        Color(red: 0.99, green: 0.96, blue: 0.2),
        Color.white,
        Color(red: 0.61, green: 0.35, blue: 0.82),
        Color.black
    ]

    /// Uses the combined palette while skipping white, which lacks contrast on the panels.
    static let panelIconColors: [Color] = [
        pridePaletteColors[0],
        pridePaletteColors[1],
        pridePaletteColors[2],
        pridePaletteColors[3],
        pridePaletteColors[4],
        pridePaletteColors[5],
        pridePaletteColors[8],
        pridePaletteColors[9]
    ]

    var iconColor: Color {
        switch self {
        case .power:      return Self.panelIconColors[0]
        case .cadence:    return Self.panelIconColors[1]
        case .speed:      return Self.panelIconColors[2]
        case .heartRate:  return Self.panelIconColors[3]
        case .distance:   return Self.panelIconColors[4]
        case .calories:   return Self.panelIconColors[5]
        case .time:       return Self.panelIconColors[6]
        case .resistance: return Self.panelIconColors[7]
        }
    }
}

struct RideView: View {
    @Environment(BikeManager.self) private var bikeManager
    @Environment(WorkoutRecorder.self) private var workoutRecorder
    @Environment(WorkoutStore.self) private var store
    var onBackgroundTap: () -> Void = {}

    /// The current tile order, loaded from and saved to UserDefaults.
    @State private var order: [RideTile] = RideView.loadOrder()
    /// The tile currently lifted for reordering, if any.
    @State private var dragging: RideTile?
    /// Live translation of the lifted tile from its home position.
    @State private var dragTranslation: CGSize = .zero
    /// Measured frames of every tile, in the grid's coordinate space.
    @State private var tileFrames: [RideTile: CGRect] = [:]
    /// High/low phase of the "breathing" background, flipped once per beat.
    @State private var beatHigh = false

    // Every panel reads these snapshots, refreshed together once per beat, so the
    // whole dashboard updates in lockstep instead of jittering on each BLE packet.
    @State private var shownMetrics = BikeMetrics()
    @State private var shownLive = LiveRideStats()
    /// The phone's battery charge in percent (0–100), refreshed each beat. Nil while
    /// the level is unknown (e.g. in the Simulator).
    @State private var shownBattery: Int?
    @State private var beatDate = Date()
    /// Phase anchor for the shared beat clock.
    @State private var beatAnchor = Date()
    /// Visual state for the time tile's inactivity countdown bar.
    @State private var timeCountdownProgress: Double?
    @State private var hideTimeCountdownTask: Task<Void, Never>?

    /// The shared cadence for data refresh and the breathing background. One beat
    /// per second keeps the elapsed clock honest; a full breath spans two beats.
    private let beat: TimeInterval = 1
    /// Wait a little longer than a single packet interval before showing the
    /// inactivity bar, so minor FTMS packet jitter doesn't make it flash.
    private let countdownDisplayDelay: TimeInterval = 2

    private static let gridSpace = "rideGrid"

    private var metrics: BikeMetrics { shownMetrics }
    private var live: LiveRideStats { shownLive }

    /// Lay the tiles out wide in landscape and tall in portrait, keeping the same
    /// eight tiles and their order.
    private func columns(isLandscape: Bool) -> Int { isLandscape ? 4 : 2 }
    private func rows(isLandscape: Bool) -> Int { isLandscape ? 2 : 4 }

    var body: some View {
        GeometryReader { proxy in
            let isLandscape = proxy.size.width > proxy.size.height

            // A single beat clock drives the whole screen: on each tick we snapshot the
            // live metrics and flip the breathing phase, so data and background share a rhythm.
            TimelineView(.periodic(from: beatAnchor, by: beat)) { context in
                grid(isLandscape: isLandscape)
                    .onChange(of: context.date, initial: true) { _, date in
                        advanceBeat(at: date)
                    }
            }
        }
        // Load saved rides so the distance/calories/time tiles can show history averages.
        .task { await store.loadIfNeeded() }
        // Battery monitoring must be enabled before `batteryLevel` reports a value.
        .onAppear { UIDevice.current.isBatteryMonitoringEnabled = true }
    }

    private func grid(isLandscape: Bool) -> some View {
        let rows = rows(isLandscape: isLandscape)
        let columns = columns(isLandscape: isLandscape)

        return ZStack {
            rideBackground

            VStack(spacing: 10) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<columns, id: \.self) { column in
                            tile(order[row * columns + column])
                        }
                    }
                }
            }
            .padding(16)
        }
        .coordinateSpace(name: Self.gridSpace)
        .onPreferenceChange(TileFramePreference.self) { tileFrames = $0 }
        // The lifted tile floats above the whole grid so it can cross rows.
        .overlay(alignment: .topLeading) { draggedTileOverlay }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rideBackground: some View {
        // The colour bleeds edge-to-edge, and this same layer handles taps in the
        // unsafe area. Tiles above it keep their own gestures.
        Color(.systemGroupedBackground)
            .overlay {
                LinearGradient(
                    colors: RideTile.pridePaletteColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(recordingWashOpacity)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onBackgroundTap)
            .ignoresSafeArea()
    }

    /// Called once per beat: refresh the displayed snapshots together and advance
    /// the breathing phase so the wash inhales/exhales in step with the data.
    private func advanceBeat(at date: Date) {
        shownMetrics = bikeManager.metrics
        shownLive = workoutRecorder.live
        shownBattery = phoneBatteryPercent()
        beatDate = date
        updateTimeCountdown(at: date)
        if workoutRecorder.isRecording {
            withAnimation(.easeInOut(duration: beat)) { beatHigh.toggle() }
        } else if beatHigh {
            withAnimation(.easeInOut(duration: 0.4)) { beatHigh = false }
        }
    }

    /// The phone's current charge as a whole percentage, or nil when the system
    /// reports an unknown level (`batteryLevel` is -1 until monitoring settles or
    /// on the Simulator).
    private func phoneBatteryPercent() -> Int? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    /// Rainbow wash behind the grid: nothing when idle, a gentle pulse while recording.
    private var recordingWashOpacity: Double {
        guard workoutRecorder.isRecording else { return 0 }
        return beatHigh ? 0.22 : 0.05
    }

    // MARK: - Tiles

    /// A reorderable tile: press-and-hold to lift, drag over another tile to swap.
    private func tile(_ kind: RideTile) -> some View {
        tileBody(for: kind)
            .gesture(reorderGesture(for: kind))
    }

    @ViewBuilder
    private func tileBody(for kind: RideTile) -> some View {
        let tilePanel = panel(for: kind)
            .opacity(dragging == kind ? 0 : 1) // hidden while its floating copy is shown
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TileFramePreference.self,
                        value: [kind: geo.frame(in: .named(Self.gridSpace))]
                    )
                }
            )

#if targetEnvironment(simulator)
        if kind == .time {
            Button {
                bikeManager.toggleSimulationPause()
            } label: {
                tilePanel
            }
            .buttonStyle(.plain)
        } else {
            tilePanel
        }
#else
        tilePanel
#endif
    }

    /// The floating copy of the lifted tile, following the finger across the grid.
    @ViewBuilder
    private var draggedTileOverlay: some View {
        if let dragging, let frame = tileFrames[dragging] {
            panel(for: dragging)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(1.04)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                .offset(
                    x: frame.minX + dragTranslation.width,
                    y: frame.minY + dragTranslation.height
                )
                .allowsHitTesting(false)
        }
    }

    /// Press-and-hold to lift a tile, drag it over another, release to swap the two.
    private func reorderGesture(for kind: RideTile) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(coordinateSpace: .named(Self.gridSpace)))
            .onChanged { value in
                switch value {
                case .first(true):
                    if dragging != kind { dragging = kind }
                case .second(true, let drag):
                    dragging = kind
                    dragTranslation = drag?.translation ?? .zero
                default:
                    break
                }
            }
            .onEnded { value in
                // onEnded always fires, so the lifted tile is never left hidden.
                defer {
                    withAnimation(.easeOut(duration: 0.2)) {
                        dragging = nil
                        dragTranslation = .zero
                    }
                }
                guard case .second(_, let drag?) = value,
                      let target = tile(at: drag.location),
                      let from = order.firstIndex(of: kind),
                      let to = order.firstIndex(of: target),
                      from != to else { return }
                order.swapAt(from, to)
                RideView.saveOrder(order)
            }
    }

    /// The tile whose measured frame contains the given point in grid space.
    private func tile(at point: CGPoint) -> RideTile? {
        tileFrames.first { $0.value.contains(point) }?.key
    }

    @ViewBuilder
    private func panel(for kind: RideTile) -> some View {
        switch kind {
        case .power:
            RidePanel(
                title: "Power",
                systemImage: "bolt.fill",
                iconColor: kind.iconColor,
                value: metrics.powerText,
                avg: live.avgPower.map { "\($0)" },
                max: live.maxPower.map { "\($0)" },
                battery: shownBattery
            )
        case .cadence:
            RidePanel(
                title: "Cadence",
                systemImage: "gauge.with.dots.needle.50percent",
                iconColor: kind.iconColor,
                value: metrics.cadenceText,
                avg: MetricFormatter.wholeNumber(live.avgCadence),
                max: MetricFormatter.wholeNumber(live.maxCadence)
            )
        case .speed:
            RidePanel(
                title: "Speed",
                systemImage: "speedometer",
                iconColor: kind.iconColor,
                value: metrics.speedText,
                avg: MetricFormatter.oneDecimal(live.avgSpeed),
                max: MetricFormatter.oneDecimal(live.maxSpeed)
            )
        case .heartRate:
            RidePanel(
                title: "Heart Rate",
                systemImage: "heart.fill",
                iconColor: kind.iconColor,
                value: metrics.heartRateText,
                avg: live.avgHeartRate.map { "\($0)" },
                max: live.maxHeartRate.map { "\($0)" }
            )
        case .distance:
            RidePanel(
                title: "Distance",
                systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                iconColor: kind.iconColor,
                value: metrics.distanceText,
                avg: store.averageDistanceMeters.map(MetricFormatter.distance),
                max: store.maxDistanceMeters.map(MetricFormatter.distance)
            )
        case .calories:
            RidePanel(
                title: "Calories",
                systemImage: "flame.fill",
                iconColor: kind.iconColor,
                value: MetricFormatter.energy(live.energyKcal),
                detail: "Est. \(Int(live.estimatedEnergyKcal.rounded()))",
                avg: store.averageEnergyKcal.map { "\(Int($0.rounded()))" },
                max: store.maxEnergyKcal.map { "\(Int($0.rounded()))" }
            )
        case .time:
            // Advances on the shared beat, so it ticks in step with the other panels.
            RidePanel(
                title: "Time",
                systemImage: "timer",
                iconColor: kind.iconColor,
                value: MetricFormatter.duration(elapsed(at: beatDate)),
                avg: store.averageDurationSeconds.map(MetricFormatter.duration),
                max: store.maxDurationSeconds.map(MetricFormatter.duration),
                headerCenterText: MetricFormatter.clockTime(beatDate),
                footerProgress: timeCountdownProgress
            )
        case .resistance:
            RidePanel(
                title: "Resistance",
                systemImage: "dial.medium.fill",
                iconColor: kind.iconColor,
                value: metrics.resistanceText,
                avg: MetricFormatter.oneDecimal(live.avgResistance),
                max: MetricFormatter.oneDecimal(live.maxResistance)
            )
        }
    }

    // MARK: - Helpers

    private func elapsed(at date: Date) -> TimeInterval {
        if let bikeElapsed = metrics.elapsedTimeSeconds {
            return bikeElapsed
        }
        if workoutRecorder.isRecording, let start = workoutRecorder.workoutStartDate {
            return max(0, date.timeIntervalSince(start))
        }
        return live.elapsed
    }

    private func updateTimeCountdown(at date: Date) {
        if let progress = inactivityCountdownProgress(at: date) {
            hideTimeCountdownTask?.cancel()
            hideTimeCountdownTask = nil
            withAnimation(.linear(duration: beat)) {
                timeCountdownProgress = progress
            }
            return
        }

        guard timeCountdownProgress != nil else { return }

        hideTimeCountdownTask?.cancel()
        hideTimeCountdownTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                timeCountdownProgress = nil
            }
            hideTimeCountdownTask = nil
        }
    }

    private func inactivityCountdownProgress(at date: Date) -> Double? {
        guard workoutRecorder.isRecording,
              let lastActivityDate = workoutRecorder.lastRecordedActivityDate
        else { return nil }

        let elapsed = max(0, date.timeIntervalSince(lastActivityDate))
        guard elapsed >= countdownDisplayDelay else { return nil }
        guard elapsed < workoutRecorder.inactivityTimeoutDuration else { return 0 }
        return max(0, 1 - (elapsed / workoutRecorder.inactivityTimeoutDuration))
    }

    // MARK: - Order persistence

    private static let orderKey = "rideTileOrder"

    /// Loads the saved order, appending any tiles missing from it (e.g. added in a
    /// newer build) so the grid always has all eight, in a stable arrangement.
    static func loadOrder() -> [RideTile] {
        let all = RideTile.allCases
        guard let saved = UserDefaults.standard.array(forKey: orderKey) as? [String] else {
            return all
        }
        var restored: [RideTile] = []
        for raw in saved {
            if let tile = RideTile(rawValue: raw), !restored.contains(tile) {
                restored.append(tile)
            }
        }
        for tile in all where !restored.contains(tile) {
            restored.append(tile)
        }
        return restored
    }

    static func saveOrder(_ order: [RideTile]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: orderKey)
    }
}

/// Collects each tile's frame (in the grid's coordinate space) so a drop location
/// can be matched to the tile beneath it.
private struct TileFramePreference: PreferenceKey {
    static let defaultValue: [RideTile: CGRect] = [:]
    static func reduce(value: inout [RideTile: CGRect], nextValue: () -> [RideTile: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A single metric tile that stretches to fill its slot in the fixed Ride grid.
/// The primary value is vertically centered; average and maximum sit in the
/// bottom corners with their own glyphs.
struct RidePanel: View {
    @Environment(\.displayScale) private var displayScale

    let title: String
    let systemImage: String
    var iconColor: Color = .accentColor
    let value: String
    var detail: String? = nil
    var avg: String? = nil
    var max: String? = nil
    /// Optional text placed between the header icon and title with equal spacing
    /// on either side.
    var headerCenterText: String? = nil
    var footerProgress: Double? = nil
    /// Bike battery charge in percent (0–100). When set, it is placed between
    /// the header icon and title with equal spacing on either side.
    var battery: Int? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(iconColor)
                Spacer(minLength: 0)
                if let battery {
                    batteryIndicator(percent: battery)
                    Spacer(minLength: 0)
                } else if let headerCenterText {
                    Text(headerCenterText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(value)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            Text(detail ?? " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(detail == nil ? .clear : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)

            Spacer(minLength: 0)

            if let footerProgress {
                countdownBar(progress: footerProgress)
                    .padding(.vertical, 10)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1 / displayScale)
        }
    }

    /// Bottom row: average glyph on the left, maximum glyph on the right.
    /// Always rendered (empty when absent) so values stay vertically aligned across tiles.
    private var footer: some View {
        HStack(spacing: 0) {
            Group {
                if let avg {
                    HStack(spacing: 2) {
                        Text("Ø")
                        Text(avg)
                    }
                }
            }
            Spacer(minLength: 0)
            Group {
                if let max {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                        Text(max)
                    }
                }
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(height: 15)
    }

    /// Battery glyph plus its charge in percent, kept together as one unit.
    private func batteryIndicator(percent: Int) -> some View {
        let clamped = Swift.min(Swift.max(percent, 0), 100)
        return HStack(spacing: 3) {
            Image(systemName: "battery.100", variableValue: Double(clamped) / 100)
            Text("\(clamped)%")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(clamped <= 20 ? Color.red : .secondary)
    }

    private func countdownBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary)
                Capsule()
                    .fill(iconColor.gradient)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 6)
    }
}

/// A metric tile with a fixed minimum height, used by the scrolling Stats grid.
struct MetricCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(16)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    RideView()
        .environment(BikeManager())
        .environment(WorkoutRecorder())
        .environment(WorkoutStore())
}
