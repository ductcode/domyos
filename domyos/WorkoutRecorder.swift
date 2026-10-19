//
//  WorkoutRecorder.swift
//  domyos
//
//  Records live FTMS bike metrics into Apple Health as a cycling workout.
//

import ActivityKit
import Foundation
import HealthKit
import Observation

@MainActor
@Observable
final class WorkoutRecorder {
    enum RecordingState: Equatable {
        case unavailable
        case idle
        case authorizing
        case recording
        case saving
    }

    private(set) var state: RecordingState
    private(set) var statusMessage: String
    private(set) var lastSavedSummary: String?
    private(set) var isPresentingInactivityAlert = false
    private(set) var inactivityAlertRemainingSeconds: Int?
    private(set) var isPausedForInactivity = false

    /// Live aggregates for the current (or most recent) session, driving the Ride dashboard.
    private(set) var live = LiveRideStats()

    var isRecording: Bool { state == .recording }

    /// Start of the in-progress workout, exposed so the Ride screen can drive a live timer.
    var workoutStartDate: Date? { startDate }

    /// Timestamp of the most recent packet that showed real pedaling activity.
    var lastRecordedActivityDate: Date? { lastActivityDate }

    /// Current inactivity auto-stop timeout in seconds.
    var inactivityTimeoutDuration: TimeInterval { inactivityTimeout }

    var canStartRecording: Bool {
        HKHealthStore.isHealthDataAvailable() && (state == .idle)
    }

    /// UserDefaults key backing the auto-start preference (mirrored by the Settings toggle).
    static let autoStartDefaultsKey = "autoStartRecording"
    /// UserDefaults key backing the inactivity auto-stop timeout, in seconds.
    static let inactivityTimeoutDefaultsKey = "inactivityTimeoutSeconds"

    private var autoStartEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoStartDefaultsKey) as? Bool ?? true
    }

    /// Seconds without activity before the workout auto-stops (default 30).
    private var inactivityTimeout: TimeInterval {
        let seconds = UserDefaults.standard.object(forKey: Self.inactivityTimeoutDefaultsKey) as? Int ?? 30
        return TimeInterval(seconds)
    }

    /// An idle gap longer than this (seconds) is bracketed with pause/resume events.
    private let pauseThreshold: TimeInterval = 5
    /// How often the inactivity monitor checks for a stale ride.
    private let inactivityCheckInterval: Duration = .seconds(2)
    /// How long the foreground inactivity alert waits before saving automatically.
    private let inactivityAlertGraceDuration: TimeInterval = 30

    /// Whether the app is currently in the foreground. When it isn't, an inactivity
    /// timeout auto-stops the ride instead of prompting (no alert can be shown).
    @ObservationIgnored private var isInForeground = true
    /// True after a bike connects and until an auto-start fires, so it triggers once per connection.
    @ObservationIgnored private var autoStartArmed = false
    /// Timestamp of the most recent packet that showed real activity.
    @ObservationIgnored private var lastActivityDate: Date?
    /// Background loop that auto-stops the workout after prolonged inactivity.
    @ObservationIgnored private var inactivityTask: Task<Void, Never>?
    /// Foreground alert countdown that auto-selects Stop and Save if ignored.
    @ObservationIgnored private var inactivityAlertTask: Task<Void, Never>?
    /// Keeps an interrupted ride open while Bluetooth reconnects; saves it if the
    /// grace period elapses without the bike coming back.
    @ObservationIgnored private var reconnectGraceTask: Task<Void, Never>?
    /// How long to keep a ride open across an unexpected Bluetooth dropout before
    /// giving up and saving what was recorded. Brief FTMS drops relink well within this.
    private let reconnectGrace: TimeInterval = 90
    /// The Live Activity showing recording status in the Dynamic Island / Lock Screen.
    @ObservationIgnored private var activity: Activity<RideActivityAttributes>?

    /// Supplies the rider's current body mass (kilograms) for weight-aware energy
    /// estimation. Wired to `RiderProfile` at launch; the default keeps it self-contained.
    @ObservationIgnored var currentBodyMassKilograms: () -> Double = { RiderProfile.defaultWeightKilograms }
    /// Lets the app refresh any history-backed UI once a workout has been saved.
    @ObservationIgnored var onWorkoutSaved: @MainActor () async -> Void = {}

    @ObservationIgnored private let healthStore = HKHealthStore()

    // Sample types this app writes to Health.
    @ObservationIgnored private let heartRateType = HKQuantityType(.heartRate)
    @ObservationIgnored private let activeEnergyType = HKQuantityType(.activeEnergyBurned)
    @ObservationIgnored private let distanceType = HKQuantityType(.distanceCycling)
    @ObservationIgnored private let cadenceType = HKQuantityType(.cyclingCadence)
    @ObservationIgnored private let powerType = HKQuantityType(.cyclingPower)
    @ObservationIgnored private let speedType = HKQuantityType(.cyclingSpeed)

    @ObservationIgnored private var builder: HKWorkoutBuilder?
    @ObservationIgnored private var startDate: Date?
    @ObservationIgnored private var previousSampleDate: Date?

    // To save battery in the background, samples are buffered and flushed to the
    // workout builder in batches, and the Live Activity is updated at most this often.
    @ObservationIgnored private var pendingSamples: [HKQuantitySample] = []
    @ObservationIgnored private var lastFlushDate: Date?
    @ObservationIgnored private var lastLiveActivityDate: Date?
    private let sampleFlushInterval: TimeInterval = 5
    private let liveActivityUpdateInterval: TimeInterval = 2
    /// If no fresh metrics arrive within this window, the Live Activity marks itself
    /// stale so the Dynamic Island can show that the data is no longer live.
    private let liveActivityStaleAfter: TimeInterval = 10

    // Running totals used to build the post-workout summary.
    @ObservationIgnored private var firstDistanceMeters: Double?
    @ObservationIgnored private var latestDistanceMeters: Double?
    @ObservationIgnored private var firstBikeEnergyKcal: Double?
    @ObservationIgnored private var latestBikeEnergyKcal: Double?
    @ObservationIgnored private var estimatedEnergyKcal: Double = 0
    @ObservationIgnored private var sampleCount = 0

    // Cumulative energy/distance are bucketed into ~1-minute samples instead of one
    // sample per packet, so Health gets a handful of rows per ride (matching Apple
    // Watch granularity) rather than hundreds. A bucket carries the amount accrued
    // since its start; it's emitted once its minute elapses, and at pauses/finish.
    private let cumulativeBucketInterval: TimeInterval = 60
    @ObservationIgnored private var energyBucketStart: Date?
    @ObservationIgnored private var energyBucketKcal: Double = 0
    @ObservationIgnored private var distanceBucketStart: Date?
    @ObservationIgnored private var distanceBucketMeters: Double = 0

    // Running sums/counts backing the live averages for metrics FTMS doesn't provide.
    @ObservationIgnored private var heartRateSum = 0.0
    @ObservationIgnored private var heartRateCount = 0
    @ObservationIgnored private var heartRateWarmupFilter = HeartRateWarmupFilter()
    @ObservationIgnored private var resistanceSum = 0.0
    @ObservationIgnored private var resistanceCount = 0
    @ObservationIgnored private var powerSum = 0.0
    @ObservationIgnored private var powerCount = 0
    @ObservationIgnored private var cadenceSum = 0.0
    @ObservationIgnored private var cadenceCount = 0

    init() {
        if HKHealthStore.isHealthDataAvailable() {
            state = .idle
            statusMessage = "Ready to save your ride to Apple Health."
        } else {
            state = .unavailable
            statusMessage = "Apple Health is not available on this device."
        }
    }

    /// Requests authorization (if needed) and begins collecting a cycling workout.
    func startRecording() async {
        guard canStartRecording else { return }

        state = .authorizing
        statusMessage = "Requesting Apple Health permission..."

        let typesToShare: Set<HKSampleType> = [
            HKWorkoutType.workoutType(),
            heartRateType,
            activeEnergyType,
            distanceType,
            cadenceType,
            powerType,
            speedType
        ]

        do {
            try await healthStore.requestAuthorization(toShare: typesToShare, read: [])
        } catch {
            state = .idle
            statusMessage = "Health permission failed: \(error.localizedDescription)"
            return
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .indoor

        let builder = HKWorkoutBuilder(
            healthStore: healthStore,
            configuration: configuration,
            device: .local()
        )

        let start = Date()
        do {
            try await builder.beginCollection(at: start)
        } catch {
            state = .idle
            statusMessage = "Could not start the workout: \(error.localizedDescription)"
            return
        }

        self.builder = builder
        startDate = start
        previousSampleDate = start
        lastActivityDate = start
        pendingSamples.removeAll(keepingCapacity: true)
        lastFlushDate = start
        lastLiveActivityDate = nil
        firstDistanceMeters = nil
        latestDistanceMeters = nil
        firstBikeEnergyKcal = nil
        latestBikeEnergyKcal = nil
        estimatedEnergyKcal = 0
        energyBucketStart = nil
        energyBucketKcal = 0
        distanceBucketStart = nil
        distanceBucketMeters = 0
        sampleCount = 0
        resetLiveStats()
        lastSavedSummary = nil
        state = .recording
        statusMessage = "Recording a cycling workout to Apple Health."
        startInactivityMonitor()
        startLiveActivity(start: start)
    }

    /// Arms auto-start for a freshly connected bike. Call this on each connection.
    /// A reconnect that lands while a ride is still open cancels the grace timer, so
    /// the same workout simply continues rather than being saved and restarted.
    func armAutoStart() {
        reconnectGraceTask?.cancel()
        reconnectGraceTask = nil
        autoStartArmed = true
    }

    /// The bike dropped unexpectedly and Bluetooth is reconnecting. Persist buffered
    /// samples and keep the workout open for a grace period; if the link doesn't come
    /// back in time, save the ride so nothing accrued so far is lost.
    func handleConnectionInterrupted() {
        guard state == .recording else { return }
        flushPendingSamples()
        reconnectGraceTask?.cancel()
        reconnectGraceTask = Task { [weak self] in
            let grace = self?.reconnectGrace ?? 90
            try? await Task.sleep(for: .seconds(grace))
            guard let self, !Task.isCancelled, self.state == .recording else { return }
            // Keep the app alive long enough to finish saving from a background wake-up.
            let assertion = BackgroundAssertion(name: "ReconnectGraceStop")
            await self.stopRecording(endingAt: self.lastActivityDate, reason: .disconnect)
            assertion.end()
        }
    }

    /// Entry point for every parsed FTMS packet: records active packets, or
    /// auto-starts a workout the first time the rider gets going after connecting.
    /// Idle packets are ignored so no-activity time stays out of the workout.
    func receive(_ metrics: BikeMetrics) {
        if state == .recording {
            if isPausedForInactivity {
                guard metrics.indicatesActivity else { return }
                let now = Date()
                resumeAfterInactivityPause(at: now)
                lastActivityDate = now
                ingest(metrics, at: now)
                return
            }
            guard metrics.indicatesActivity else {
                // An idle packet waking us in the background is our reliable chance to
                // enforce the auto-stop: the monitor task can't run while suspended.
                if !isInForeground, let last = lastActivityDate,
                   Date().timeIntervalSince(last) >= inactivityTimeout {
                    handleInactivityTimeout()
                }
                return
            }
            let now = Date()
            // If the rider resumed after a gap, exclude that gap from the workout.
            if let last = lastActivityDate, now.timeIntervalSince(last) > pauseThreshold {
                insertPause(from: last, to: now)
                // Don't credit energy/distance across the paused gap.
                previousSampleDate = now
            }
            lastActivityDate = now
            ingest(metrics, at: now)
            return
        }

        guard autoStartEnabled, autoStartArmed, state == .idle, metrics.indicatesActivity else {
            return
        }

        // Consume the arm so packets arriving during the async start don't retrigger,
        // and so a manual stop won't auto-restart until the next connection.
        autoStartArmed = false
        Task {
            await startRecording()
            guard state == .recording else { return }
            let now = Date()
            lastActivityDate = now
            ingest(metrics, at: now)
        }
    }

    /// Ends and saves the in-progress workout when the bike disconnects.
    func handleDisconnect() {
        guard state == .recording else { return }
        Task { await stopRecording(endingAt: lastActivityDate, reason: .disconnect) }
    }

    /// Handles the app being backgrounded (e.g. the screen locking). An active
    /// workout keeps recording — the Live Activity keeps it on the Lock Screen and
    /// background BLE updates keep feeding it until the bike disconnects or the
    /// inactivity auto-stop fires — so we only persist any buffered samples here so
    /// nothing is lost if iOS later terminates us.
    func handleAppBackground() {
        isInForeground = false
        guard state == .recording else { return }
        flushPendingSamples()
    }

    /// Marks the app as foregrounded again so inactivity prompts (rather than a
    /// silent auto-stop) resume while the rider can see and answer them.
    func handleAppForeground() {
        isInForeground = true
    }

    func continueAfterInactivityAlert() {
        guard isPresentingInactivityAlert, let lastActivityDate else { return }

        let now = Date()
        insertPause(from: lastActivityDate, to: now)
        previousSampleDate = now
        self.lastActivityDate = now
        dismissInactivityAlert()
        statusMessage = "Recording a cycling workout to Apple Health."
        startInactivityMonitor()
    }

    func pauseAfterInactivityAlert() {
        guard isPresentingInactivityAlert, let lastActivityDate else { return }

        insertPause(at: lastActivityDate)
        dismissInactivityAlert()
        isPausedForInactivity = true
        inactivityTask?.cancel()
        inactivityTask = nil
        statusMessage = "Workout paused. It will resume when pedaling starts again."
    }

    func stopAfterInactivityAlert() {
        guard isPresentingInactivityAlert else { return }
        dismissInactivityAlert()
        Task { await stopRecording(endingAt: lastActivityDate, reason: .inactivity) }
    }

    private func insertPause(from pauseStart: Date, to resumeDate: Date) {
        guard let builder else { return }
        // Close out any open energy/distance bucket so it doesn't span the gap.
        flushCumulativeBuckets(at: pauseStart)
        let events = [
            HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pauseStart, duration: 0), metadata: nil),
            HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: resumeDate, duration: 0), metadata: nil)
        ]
        builder.addWorkoutEvents(events) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.statusMessage = "Failed to record a pause: \(error.localizedDescription)"
            }
        }
    }

    private func insertPause(at pauseStart: Date) {
        guard let builder else { return }
        // Close out any open energy/distance bucket so it doesn't span the gap.
        flushCumulativeBuckets(at: pauseStart)
        let event = HKWorkoutEvent(type: .pause, dateInterval: DateInterval(start: pauseStart, duration: 0), metadata: nil)
        builder.addWorkoutEvents([event]) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.statusMessage = "Failed to record a pause: \(error.localizedDescription)"
            }
        }
    }

    private func insertResume(at resumeDate: Date) {
        guard let builder else { return }
        let event = HKWorkoutEvent(type: .resume, dateInterval: DateInterval(start: resumeDate, duration: 0), metadata: nil)
        builder.addWorkoutEvents([event]) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.statusMessage = "Failed to record a resume: \(error.localizedDescription)"
            }
        }
    }

    private func resumeAfterInactivityPause(at now: Date) {
        guard isPausedForInactivity else { return }
        insertResume(at: now)
        previousSampleDate = now
        isPausedForInactivity = false
        statusMessage = "Recording a cycling workout to Apple Health."
        startInactivityMonitor()
    }

    // MARK: - Inactivity auto-stop

    /// Reached the inactivity timeout. On screen, prompt the rider (keep/pause/stop);
    /// backgrounded, silently auto-stop and save the ride, trimming the trailing idle
    /// time, since no prompt can be shown. Resumed pedaling then auto-starts a new ride.
    private func handleInactivityTimeout() {
        guard state == .recording, let last = lastActivityDate else { return }
        if isInForeground {
            presentInactivityAlert()
        } else {
            // Keep the app alive long enough to finish saving from a background wake-up.
            let assertion = BackgroundAssertion(name: "InactivityAutoStop")
            Task {
                await stopRecording(endingAt: last, reason: .inactivity)
                assertion.end()
            }
        }
    }

    private func presentInactivityAlert() {
        guard !isPresentingInactivityAlert else { return }

        inactivityTask?.cancel()
        inactivityTask = nil
        isPresentingInactivityAlert = true
        startInactivityAlertCountdown()
    }

    private func dismissInactivityAlert() {
        inactivityAlertTask?.cancel()
        inactivityAlertTask = nil
        inactivityAlertRemainingSeconds = nil
        isPresentingInactivityAlert = false
    }

    private func startInactivityAlertCountdown() {
        inactivityAlertTask?.cancel()
        let deadline = Date().addingTimeInterval(inactivityAlertGraceDuration)
        inactivityAlertRemainingSeconds = Int(inactivityAlertGraceDuration.rounded(.up))

        inactivityAlertTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.isPresentingInactivityAlert, self.state == .recording else {
                    self.dismissInactivityAlert()
                    return
                }

                let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                self.inactivityAlertRemainingSeconds = remaining

                if remaining == 0 {
                    self.inactivityAlertTask = nil
                    self.inactivityAlertRemainingSeconds = nil
                    self.isPresentingInactivityAlert = false
                    await self.stopRecording(endingAt: self.lastActivityDate, reason: .inactivity)
                    return
                }
            }
        }
    }

    private func startInactivityMonitor() {
        inactivityTask?.cancel()
        inactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.inactivityCheckInterval ?? .seconds(2))
                guard let self else { return }
                guard self.state == .recording, let last = self.lastActivityDate else { continue }
                if Date().timeIntervalSince(last) >= self.inactivityTimeout {
                    self.handleInactivityTimeout()
                    return
                }
            }
        }
    }

    // MARK: - Live Activity (Dynamic Island / Lock Screen)

    private func startLiveActivity(start: Date) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RideActivityAttributes.ContentState(startDate: start)
        activity = try? Activity.request(
            attributes: RideActivityAttributes(),
            content: ActivityContent(state: state, staleDate: start.addingTimeInterval(liveActivityStaleAfter))
        )
    }

    private func updateLiveActivity(with metrics: BikeMetrics, at now: Date) {
        guard let activity, let startDate else { return }
        // Throttle pushes: the elapsed timer animates on its own, so the numbers
        // only need refreshing every couple of seconds to keep background cost low.
        if let last = lastLiveActivityDate, now.timeIntervalSince(last) < liveActivityUpdateInterval {
            return
        }
        lastLiveActivityDate = now
        let state = RideActivityAttributes.ContentState(
            startDate: startDate,
            powerWatts: metrics.powerWatts,
            cadenceRPM: metrics.cadenceRPM,
            speedKPH: metrics.speedKPH,
            heartRate: metrics.heartRate,
            energyKcal: currentWorkoutEnergyKcal
        )
        // ActivityKit's Activity isn't Sendable, but this recorder is the sole
        // owner and ActivityKit is internally thread-safe.
        nonisolated(unsafe) let liveActivity = activity
        // When woken by a BLE packet in the background, hold a background-task
        // assertion so iOS doesn't suspend us before this async update lands —
        // otherwise the Dynamic Island freezes while its timer keeps ticking.
        let assertion = BackgroundAssertion(name: "LiveActivityUpdate")
        let staleDate = now.addingTimeInterval(liveActivityStaleAfter)
        Task { @MainActor in
            await liveActivity.update(ActivityContent(state: state, staleDate: staleDate))
            assertion.end()
        }
    }

    private func endLiveActivity() {
        guard let activity else { return }
        self.activity = nil
        nonisolated(unsafe) let liveActivity = activity
        Task {
            await liveActivity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Feeds a fresh metrics snapshot into the workout as HealthKit samples.
    private func ingest(_ metrics: BikeMetrics, at now: Date) {
        guard state == .recording, builder != nil else { return }

        let intervalStart = previousSampleDate ?? startDate ?? now
        // Guard against out-of-order timestamps.
        let sampleStart = min(intervalStart, now)

        var samples: [HKQuantitySample] = []

        // Instantaneous (discrete) metrics recorded at the current moment.
        if let heartRate = metrics.heartRate {
            samples.append(sample(
                heartRateType,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: Double(heartRate),
                start: now, end: now
            ))
        }

        if let cadence = metrics.cadenceRPM {
            samples.append(sample(
                cadenceType,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: cadence,
                start: now, end: now
            ))
        }

        if let power = metrics.powerWatts {
            samples.append(sample(
                powerType,
                unit: .watt(),
                value: Double(power),
                start: now, end: now
            ))
        }

        if let speedKPH = metrics.speedKPH {
            samples.append(sample(
                speedType,
                unit: HKUnit.meter().unitDivided(by: .second()),
                value: speedKPH / 3.6,
                start: now, end: now
            ))
        }

        // Cumulative distance: accrue the delta into the current minute bucket.
        if let total = metrics.distanceMeters {
            if firstDistanceMeters == nil { firstDistanceMeters = total }
            if let previousTotal = latestDistanceMeters, total > previousTotal, now > sampleStart {
                accrueCumulative(
                    total - previousTotal,
                    into: &distanceBucketMeters,
                    bucketStart: &distanceBucketStart,
                    from: sampleStart, at: now,
                    type: distanceType, unit: .meter()
                )
            }
            latestDistanceMeters = total
        }

        // Keep the app's power-based estimate as a secondary UI value only.
        if let power = metrics.powerWatts, power > 0 {
            let seconds = now.timeIntervalSince(sampleStart)
            if seconds > 0 {
                estimatedEnergyKcal += CyclingEnergyEstimator.kilocalories(
                    powerWatts: Double(power),
                    duration: seconds,
                    bodyMassKilograms: currentBodyMassKilograms()
                )
            }
        }

        // FTMS expended energy is cumulative. Accrue the delta into the current
        // minute bucket instead of writing a sample every kcal (~8/min).
        if let totalEnergyKcal = metrics.totalEnergyKcal.map(Double.init) {
            if firstBikeEnergyKcal == nil { firstBikeEnergyKcal = totalEnergyKcal }
            if let previousTotalEnergyKcal = latestBikeEnergyKcal,
               totalEnergyKcal > previousTotalEnergyKcal,
               now > sampleStart {
                accrueCumulative(
                    totalEnergyKcal - previousTotalEnergyKcal,
                    into: &energyBucketKcal,
                    bucketStart: &energyBucketStart,
                    from: sampleStart, at: now,
                    type: activeEnergyType, unit: .kilocalorie()
                )
            }
            latestBikeEnergyKcal = totalEnergyKcal
        }

        previousSampleDate = now

        updateLiveStats(with: metrics, at: now)
        // The throttled Live Activity reflects the bike-reported workout energy total.
        updateLiveActivity(with: metrics, at: now)

        guard !samples.isEmpty else { return }
        sampleCount += samples.count
        pendingSamples.append(contentsOf: samples)

        // Flush in batches rather than on every packet to cut background wakeups.
        let lastFlush = lastFlushDate ?? startDate ?? now
        if now.timeIntervalSince(lastFlush) >= sampleFlushInterval {
            lastFlushDate = now
            flushPendingSamples()
        }
    }

    /// Adds `delta` to a cumulative bucket, buffering a single Health sample for the
    /// whole bucket once its minute has elapsed (then starting a fresh bucket).
    private func accrueCumulative(
        _ delta: Double,
        into bucketValue: inout Double,
        bucketStart: inout Date?,
        from intervalStart: Date,
        at now: Date,
        type: HKQuantityType,
        unit: HKUnit
    ) {
        if bucketStart == nil { bucketStart = intervalStart }
        bucketValue += delta
        guard let start = bucketStart,
              now.timeIntervalSince(start) >= cumulativeBucketInterval,
              now > start else { return }
        enqueueCumulativeSample(type, unit: unit, value: bucketValue, start: start, end: now)
        bucketStart = now
        bucketValue = 0
    }

    /// Emits any partial (sub-minute) energy/distance buckets — called at a pause
    /// boundary and at workout end so no accrued amount is lost or spans a pause.
    private func flushCumulativeBuckets(at now: Date) {
        if let start = energyBucketStart, energyBucketKcal > 0, now > start {
            enqueueCumulativeSample(activeEnergyType, unit: .kilocalorie(), value: energyBucketKcal, start: start, end: now)
        }
        energyBucketStart = nil
        energyBucketKcal = 0

        if let start = distanceBucketStart, distanceBucketMeters > 0, now > start {
            enqueueCumulativeSample(distanceType, unit: .meter(), value: distanceBucketMeters, start: start, end: now)
        }
        distanceBucketStart = nil
        distanceBucketMeters = 0
    }

    private func enqueueCumulativeSample(_ type: HKQuantityType, unit: HKUnit, value: Double, start: Date, end: Date) {
        pendingSamples.append(sample(type, unit: unit, value: value, start: start, end: end))
        sampleCount += 1
    }

    /// Writes any buffered samples to the workout builder in one batch.
    private func flushPendingSamples() {
        guard let builder, !pendingSamples.isEmpty else { return }
        let batch = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        // Keep the app alive until the write finishes when running in the background.
        let assertion = BackgroundAssertion(name: "WorkoutSampleFlush")
        builder.add(batch) { [weak self] _, error in
            Task { @MainActor in
                assertion.end()
                guard let error else { return }
                self?.statusMessage = "Failed to record a sample: \(error.localizedDescription)"
            }
        }
    }

    /// Flushes buffered samples and waits for the write to complete, so nothing is
    /// dropped when the workout ends.
    private func flushPendingSamplesAndWait() async {
        guard let builder, !pendingSamples.isEmpty else { return }
        let batch = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        await withCheckedContinuation { continuation in
            builder.add(batch) { _, _ in continuation.resume() }
        }
    }

    // MARK: - Live aggregates

    private func resetLiveStats() {
        live = LiveRideStats()
        heartRateSum = 0; heartRateCount = 0
        heartRateWarmupFilter.reset()
        resistanceSum = 0; resistanceCount = 0
        powerSum = 0; powerCount = 0
        cadenceSum = 0; cadenceCount = 0
    }

    private func updateLiveStats(with metrics: BikeMetrics, at now: Date) {
        var stats = live

        if let power = metrics.powerWatts {
            powerSum += Double(power); powerCount += 1
            stats.avgPower = Int((powerSum / Double(powerCount)).rounded())
            stats.maxPower = max(stats.maxPower ?? power, power)
        }
        if let averagePower = metrics.averagePowerWatts {
            stats.avgPower = averagePower
        }
        if let cadence = metrics.cadenceRPM {
            cadenceSum += cadence; cadenceCount += 1
            stats.avgCadence = cadenceSum / Double(cadenceCount)
            stats.maxCadence = max(stats.maxCadence ?? cadence, cadence)
        }
        if let averageCadence = metrics.averageCadenceRPM {
            stats.avgCadence = averageCadence
        }
        if let averageSpeed = metrics.averageSpeedKPH {
            stats.avgSpeed = averageSpeed
        }
        if let speed = metrics.speedKPH {
            stats.maxSpeed = max(stats.maxSpeed ?? speed, speed)
        }
        if let heartRate = metrics.heartRate {
            if heartRate > 0, heartRateWarmupFilter.shouldInclude(heartRate) {
                heartRateSum += Double(heartRate); heartRateCount += 1
                stats.avgHeartRate = Int((heartRateSum / Double(heartRateCount)).rounded())
            }
            stats.maxHeartRate = max(stats.maxHeartRate ?? heartRate, heartRate)
        }
        if let resistance = metrics.resistanceLevel {
            resistanceSum += resistance; resistanceCount += 1
            stats.avgResistance = resistanceSum / Double(resistanceCount)
            stats.maxResistance = max(stats.maxResistance ?? resistance, resistance)
        }

        stats.energyKcal = currentWorkoutEnergyKcal
        stats.estimatedEnergyKcal = estimatedEnergyKcal
        if let startDate { stats.elapsed = now.timeIntervalSince(startDate) }

        live = stats
    }

    enum StopReason {
        case manual, inactivity, disconnect
    }

    /// Ends collection and saves the workout to the HealthKit store.
    /// - Parameter endingAt: the workout's end date. Pass the last active
    ///   timestamp for auto-stops so trailing idle time is excluded. Defaults to now.
    func stopRecording(endingAt requestedEnd: Date? = nil, reason: StopReason = .manual) async {
        guard state == .recording, let builder, let startDate else { return }

        inactivityTask?.cancel()
        inactivityTask = nil
        reconnectGraceTask?.cancel()
        reconnectGraceTask = nil
        dismissInactivityAlert()
        isPausedForInactivity = false
        endLiveActivity()

        state = .saving
        statusMessage = "Saving workout to Apple Health..."

        // Clamp the end date into a valid range: at least the start, at most now.
        let end = min(Date(), max(startDate, requestedEnd ?? Date()))
        // Emit the final partial energy/distance buckets, then persist everything
        // still buffered before closing out the workout.
        flushCumulativeBuckets(at: end)
        await flushPendingSamplesAndWait()

        do {
            // Active duration excludes any paused (idle) intervals.
            let activeDuration = builder.elapsedTime(at: end)
            try await builder.endCollection(at: end)
            let workout = try await builder.finishWorkout()

            let distanceMeters = (latestDistanceMeters ?? 0) - (firstDistanceMeters ?? 0)
            lastSavedSummary = summary(
                duration: activeDuration,
                distanceMeters: max(0, distanceMeters),
                energyKcal: currentWorkoutEnergyKcal
            )

            if workout == nil {
                statusMessage = "Workout saved, but is unavailable because the device is locked."
            } else {
                statusMessage = savedMessage(for: reason)
            }
            await onWorkoutSaved()
        } catch {
            statusMessage = "Could not save the workout: \(error.localizedDescription)"
        }

        self.builder = nil
        self.startDate = nil
        self.previousSampleDate = nil
        self.lastActivityDate = nil
        autoStartArmed = shouldRearmAutoStart(after: reason)
        state = .idle
    }

    private func savedMessage(for reason: StopReason) -> String {
        switch reason {
        case .manual:
            "Saved to Apple Health. Find it in the Fitness and Health apps."
        case .inactivity:
            "No activity detected — workout saved to Apple Health."
        case .disconnect:
            "Bike disconnected — workout saved to Apple Health."
        }
    }

    private func shouldRearmAutoStart(after reason: StopReason) -> Bool {
        switch reason {
        case .manual, .disconnect:
            false
        case .inactivity:
            autoStartEnabled
        }
    }

    private func sample(
        _ type: HKQuantityType,
        unit: HKUnit,
        value: Double,
        start: Date,
        end: Date
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start,
            end: end
        )
    }

    private func summary(duration: TimeInterval, distanceMeters: Double, energyKcal: Double) -> String {
        "\(MetricFormatter.duration(duration)) · \(MetricFormatter.distance(distanceMeters)) · \(MetricFormatter.energy(energyKcal)) · \(sampleCount) samples"
    }

    private var currentWorkoutEnergyKcal: Double {
        guard let firstBikeEnergyKcal, let latestBikeEnergyKcal else { return 0 }
        return max(0, latestBikeEnergyKcal - firstBikeEnergyKcal)
    }
}

struct HeartRateWarmupFilter {
    private enum State {
        case waitingForFirstSample
        case waitingForRampToSettle(previous: Int, skippedCount: Int)
        case including
    }

    private static let syntheticStartUpperBound = 85
    private static let maxSkippedRampSamples = 20

    private var state: State = .waitingForFirstSample

    mutating func reset() {
        state = .waitingForFirstSample
    }

    mutating func shouldInclude(_ heartRate: Int) -> Bool {
        guard heartRate > 0 else { return false }

        switch state {
        case .waitingForFirstSample:
            if heartRate <= Self.syntheticStartUpperBound {
                state = .waitingForRampToSettle(previous: heartRate, skippedCount: 1)
                return false
            }
            state = .including
            return true

        case let .waitingForRampToSettle(previous, skippedCount):
            let nextSkippedCount = skippedCount + 1
            if heartRate <= previous || nextSkippedCount >= Self.maxSkippedRampSamples {
                state = .including
                return true
            }
            state = .waitingForRampToSettle(previous: heartRate, skippedCount: nextSkippedCount)
            return false

        case .including:
            return true
        }
    }
}
