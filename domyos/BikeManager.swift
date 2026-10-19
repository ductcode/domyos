//
//  BikeManager.swift
//  domyos
//
//  Created by Codex on 24.07.26.
//

import CoreBluetooth
import Foundation
import Observation
import OSLog
import SwiftUI

/// One timestamped connection-lifecycle event, mirrored into the unified log and
/// kept in a small in-app ring buffer so the Diagnostics screen can show recent
/// Bluetooth activity on-device without a Mac.
struct ConnectionLogEntry: Identifiable, Codable {
    var id = UUID()
    let date: Date
    let message: String
}

@MainActor
@Observable
final class BikeManager: NSObject {
    private(set) var connectionState: ConnectionState = .idle
    private(set) var statusMessage = "Waiting for Bluetooth permission."
    private(set) var deviceName: String?
    private(set) var metrics = BikeMetrics()
    private(set) var capabilities = FTMSCapabilities()
    private(set) var isScanning = false
    /// Last known Bluetooth state, mirrored so the UI can decide availability without
    /// touching (and thereby creating) the central manager before the user scans.
    private(set) var bluetoothState: CBManagerState = .unknown

    /// Recent connection-lifecycle events (newest last), for the Diagnostics screen.
    /// Persisted so a background disconnect survives even if iOS terminates the app
    /// before it is reopened.
    private(set) var eventLog: [ConnectionLogEntry] = []
    /// Cap on the in-app event ring buffer; older entries are dropped.
    private static let maxEventLogEntries = 100
    /// UserDefaults key backing the persisted event log.
    private static let eventLogDefaultsKey = "connectionEventLog"

    /// Writes to the unified log (subsystem `de.howen.domyos`, category `bluetooth`)
    /// so events survive to a `log collect` / sysdiagnose export off-device.
    @ObservationIgnored private let logger = Logger(subsystem: "de.howen.domyos", category: "bluetooth")

    /// Records one connection event to the unified log, the in-app buffer, and disk.
    /// Called on the main actor from the CoreBluetooth callbacks — which iOS delivers
    /// even while the app is backgrounded (thanks to the `bluetooth-central` mode),
    /// so background disconnects are captured too.
    private func logEvent(_ message: String) {
        logger.info("\(message, privacy: .public)")
        eventLog.append(ConnectionLogEntry(date: Date(), message: message))
        if eventLog.count > Self.maxEventLogEntries {
            eventLog.removeFirst(eventLog.count - Self.maxEventLogEntries)
        }
        persistEventLog()
    }

    /// Clears the in-app event log (the unified log is untouched).
    func clearEventLog() {
        eventLog.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.eventLogDefaultsKey)
    }

    private func persistEventLog() {
        guard let data = try? JSONEncoder().encode(eventLog) else { return }
        UserDefaults.standard.set(data, forKey: Self.eventLogDefaultsKey)
    }

    private static func loadPersistedEventLog() -> [ConnectionLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: eventLogDefaultsKey),
              let entries = try? JSONDecoder().decode([ConnectionLogEntry].self, from: data)
        else { return [] }
        return entries
    }

    /// A readable one-line description of a CoreBluetooth error, including the domain
    /// and numeric code — the disconnect code is the key clue for *why* a link dropped.
    private func describe(_ error: Error?) -> String {
        guard let error else { return "no error (clean)" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code) — \(nsError.localizedDescription)"
    }

    /// A readable name for a Bluetooth power/authorization state.
    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "unhandled(\(state.rawValue))"
        }
    }

    /// A readable name for a peripheral's connection state.
    private static func describe(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        @unknown default: "unhandled(\(state.rawValue))"
        }
    }

    /// Called on the main actor whenever a fresh FTMS packet has been parsed.
    @ObservationIgnored var metricsHandler: ((BikeMetrics) -> Void)?

    /// Called on the main actor when a bike finishes connecting.
    @ObservationIgnored var onConnect: (() -> Void)?

    /// Called on the main actor when a bike disconnects for good (the user asked to
    /// disconnect, or there is no known bike to return to).
    @ObservationIgnored var onDisconnect: (() -> Void)?

    /// Called on the main actor when a connected bike drops unexpectedly and we begin
    /// silently reconnecting. Lets an in-progress ride stay open across a brief dropout.
    @ObservationIgnored var onConnectionInterrupted: (() -> Void)?

    var canStartScan: Bool {
        guard !isScanning else { return false }
        // Before the central exists the state is `.unknown`; keep the button enabled
        // so tapping it is what creates the central and prompts for permission.
        switch bluetoothState {
        case .poweredOff, .unauthorized, .unsupported: return false
        default: return true
        }
    }

    /// Restore identifier so iOS can relaunch us in the background and hand back the
    /// connected bike if the app is jettisoned mid-ride (State Preservation & Restoration).
    private static let restoreIdentifier = "de.howen.domyos.ftms.central"
    /// UserDefaults key holding the identifier of the most recently connected bike.
    private static let lastBikeDefaultsKey = "lastConnectedBikeID"
    /// UserDefaults key prefix for the best known display name of a peripheral.
    private static let bikeNameDefaultsKeyPrefix = "knownBikeName."

    @ObservationIgnored private lazy var centralManager = CBCentralManager(
        delegate: self,
        queue: nil,
        options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
    )
    @ObservationIgnored private var connectedPeripheral: CBPeripheral?
    /// Set when the user taps Scan before Bluetooth is powered on, so we scan as soon as it is.
    @ObservationIgnored private var pendingScan = false
    /// Set at launch when a previously connected bike should be reconnected once powered on.
    @ObservationIgnored private var shouldAutoReconnect = false
    /// True while the user-initiated disconnect is in flight, so the resulting
    /// `didDisconnectPeripheral` settles into idle instead of auto-reconnecting.
    @ObservationIgnored private var intentionalDisconnect = false
    /// Bounds how long we silently retry after an unexpected drop before giving up,
    /// releasing the link, and telling the user the bike likely needs a power cycle.
    @ObservationIgnored private var reconnectDeadlineTask: Task<Void, Never>?
    /// Set while giving up on a reconnect so the resulting disconnect callback (if
    /// CoreBluetooth delivers one for the cancelled pending connect) is a no-op.
    @ObservationIgnored private var reconnectGaveUp = false
    /// Set while the link was deliberately released because the app was backgrounded
    /// with no ride in progress. Foregrounding resumes auto-reconnect. This keeps a
    /// pocketed second phone from holding — or silently stealing — the bike, which
    /// accepts only one connection at a time, without the rider disabling Bluetooth.
    @ObservationIgnored private var isSuspendedForBackground = false
    /// How long to wait for an unresponsive bike to come back before giving up. A
    /// stuck FTMS console never re-advertises, so retrying past this only strings the
    /// user along; kept just under the recorder's ride grace so this drives the end.
    private let reconnectDeadline: TimeInterval = 75
    /// Fails first-contact FTMS discovery cleanly instead of leaving the UI in
    /// "Connecting" forever when a bike never exposes usable services/characteristics.
    @ObservationIgnored private var discoveryTimeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        // Restore the persisted event log so a background disconnect that happened
        // before a termination is still visible after relaunch.
        eventLog = Self.loadPersistedEventLog()
        // Only create the central at launch if we have a bike to reconnect to — that
        // means permission was already granted, so no prompt appears. On a truly first
        // launch we stay lazy and defer the prompt until the user taps Scan.
        if UserDefaults.standard.string(forKey: Self.lastBikeDefaultsKey) != nil {
            logEvent("App launched — central created for auto-reconnect")
            shouldAutoReconnect = true
            _ = centralManager
        } else {
            logEvent("App launched")
        }
    }

    func startScan() {
        metrics = BikeMetrics()
        capabilities = FTMSCapabilities()
        deviceName = nil
        isScanning = true
        connectionState = .scanning

        // Accessing `centralManager` here is what creates it on first use — and thus
        // what triggers the Bluetooth permission prompt, only once the user scans.
        if centralManager.state == .poweredOn {
            beginScanning()
        } else {
            // Wait for `centralManagerDidUpdateState` to report power-on (which also
            // covers the permission prompt being answered on first launch).
            pendingScan = true
            statusMessage = "Preparing Bluetooth…"
        }
    }

    /// Starts looking for a bike automatically only when Bluetooth permission was
    /// already granted, preserving the first-launch "ask on explicit scan" behavior.
    func startAutomaticDiscoveryIfPossible() {
        guard connectedPeripheral == nil, !isScanning else { return }

        if UserDefaults.standard.string(forKey: Self.lastBikeDefaultsKey) != nil {
            shouldAutoReconnect = true
            _ = centralManager
            if centralManager.state == .poweredOn {
                if !attemptReconnect() {
                    beginScanning()
                }
            }
            return
        }

        guard CBManager.authorization == .allowedAlways else { return }

        metrics = BikeMetrics()
        capabilities = FTMSCapabilities()
        deviceName = nil
        isScanning = true
        connectionState = .scanning
        _ = centralManager

        if centralManager.state == .poweredOn {
            beginScanning()
        } else {
            pendingScan = true
            statusMessage = "Preparing Bluetooth…"
        }
    }

    private func beginScanning() {
        pendingScan = false
        isScanning = true
        connectionState = .scanning
        statusMessage = "Scanning for FTMS bikes nearby..."
        logEvent("Scanning for FTMS service \(FTMSUUID.service.uuidString)")
        centralManager.scanForPeripherals(withServices: [FTMSUUID.service], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    private func knownName(for peripheral: CBPeripheral) -> String? {
        UserDefaults.standard.string(forKey: Self.bikeNameDefaultsKeyPrefix + peripheral.identifier.uuidString)
    }

    private func rememberDeviceName(_ name: String, for peripheral: CBPeripheral) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        UserDefaults.standard.set(trimmedName, forKey: Self.bikeNameDefaultsKeyPrefix + peripheral.identifier.uuidString)
        if connectedPeripheral?.identifier == peripheral.identifier {
            deviceName = trimmedName
        }
    }

    private func preferredName(for peripheral: CBPeripheral, fallback: String) -> String {
        if let peripheralName = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !peripheralName.isEmpty {
            rememberDeviceName(peripheralName, for: peripheral)
            return peripheralName
        }
        if let knownName = knownName(for: peripheral) {
            return knownName
        }
        return fallback
    }

    /// Attempts to reconnect to the last bike we connected to. The connect request has
    /// no timeout, so iOS links up whenever the bike next comes into range — even in
    /// the background — without another scan.
    @discardableResult
    private func attemptReconnect() -> Bool {
        shouldAutoReconnect = false
        guard connectedPeripheral == nil,
              centralManager.state == .poweredOn,
              let idString = UserDefaults.standard.string(forKey: Self.lastBikeDefaultsKey),
              let uuid = UUID(uuidString: idString),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
        else { return false }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        deviceName = preferredName(for: peripheral, fallback: "FTMS Bike")
        connectionState = .connecting
        statusMessage = "Reconnecting to \(deviceName ?? "your bike")…"
        logEvent("Auto-reconnect requested for \(deviceName ?? "known bike") (\(peripheral.identifier.uuidString))")
        centralManager.connect(peripheral, options: nil)
        return true
    }

    func disconnect() {
        guard let connectedPeripheral else { return }
        // Mark this as deliberate so the disconnect callback ends the ride instead of
        // silently reconnecting, and drop any pending reconnect request.
        intentionalDisconnect = true
        cancelDiscoveryTimeout()
        cancelReconnectDeadline()
        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    /// The app was backgrounded. If a ride is in progress we keep the link alive so
    /// background BLE keeps feeding the workout; otherwise we release it (or a lurking
    /// timeout-free connect) so an idle, pocketed phone stops competing for the
    /// single-connection bike. Foregrounding re-arms auto-reconnect.
    func handleAppBackground(isRecording: Bool) {
        guard !isRecording else { return }
        // Only act when Bluetooth is actually engaged; otherwise there's nothing
        // lurking, and touching the (lazy) central here could needlessly create it.
        guard connectedPeripheral != nil || isScanning || connectionState == .connecting else { return }

        isSuspendedForBackground = true
        cancelDiscoveryTimeout()
        cancelReconnectDeadline()
        reconnectGaveUp = false
        pendingScan = false
        shouldAutoReconnect = false

        if isScanning {
            isScanning = false
            if centralManager.state == .poweredOn { centralManager.stopScan() }
        }
        if let peripheral = connectedPeripheral {
            logEvent("App backgrounded with no active ride — releasing \(deviceName ?? "bike") link")
            // Cancels an active link or a pending timeout-free connect. Any resulting
            // disconnect callback is swallowed via `isSuspendedForBackground`.
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        connectionState = .idle
        statusMessage = "Bluetooth paused while the app is in the background."
    }

    /// The app returned to the foreground. If we released the bike while backgrounded,
    /// re-arm auto-reconnect so simply opening the app and starting to pedal reconnects
    /// and records, exactly as before — while a still-pocketed phone stays out.
    func handleAppForeground() {
        guard isSuspendedForBackground else { return }
        isSuspendedForBackground = false
        guard connectedPeripheral == nil, !isScanning else { return }

        shouldAutoReconnect = true
        _ = centralManager
        if centralManager.state == .poweredOn {
            if !attemptReconnect() {
                beginScanning()
            }
        }
        // Otherwise `centralManagerDidUpdateState` resumes via `shouldAutoReconnect`
        // once Bluetooth reports powered-on.
    }

    /// Stops an in-progress scan and returns to idle so the user can choose to scan again.
    func stopScan() {
        guard isScanning else { return }
        isScanning = false
        pendingScan = false
        deviceName = nil
        if centralManager.state == .poweredOn {
            centralManager.stopScan()
        }
        connectionState = .idle
        statusMessage = "Stopped scanning."
    }

    private func armDiscoveryTimeout(
        seconds: TimeInterval = 12,
        message: @autoclosure @escaping @MainActor () -> String
    ) {
        discoveryTimeoutTask?.cancel()
        let peripheralIdentifier = connectedPeripheral?.identifier
        discoveryTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            guard self.connectionState == .connecting,
                  self.connectedPeripheral?.identifier == peripheralIdentifier
            else { return }

            self.statusMessage = message()
            self.logEvent("Discovery timeout: \(message())")
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            } else {
                self.connectionState = .idle
            }
        }
    }

    private func cancelDiscoveryTimeout() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
    }

    /// Starts the reconnect deadline after an unexpected drop. If the bike hasn't
    /// come back by the deadline, `giveUpReconnect()` releases the link and guides
    /// the user, instead of showing "Reconnecting…" forever.
    private func armReconnectDeadline() {
        reconnectDeadlineTask?.cancel()
        let peripheralIdentifier = connectedPeripheral?.identifier
        reconnectDeadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.reconnectDeadline ?? 75))
            guard let self, !Task.isCancelled else { return }
            // Only give up if we're still waiting on the same peripheral to return.
            guard self.connectionState == .connecting,
                  self.connectedPeripheral?.identifier == peripheralIdentifier
            else { return }
            self.giveUpReconnect()
        }
    }

    private func cancelReconnectDeadline() {
        reconnectDeadlineTask?.cancel()
        reconnectDeadlineTask = nil
    }

    /// The bike never came back within the deadline. Cancel the outstanding connect so
    /// iOS releases its side of the link — the only lever we have to let a stuck
    /// console's own supervision timeout clear the stale link — then surface a clear
    /// recovery instruction and end the ride.
    private func giveUpReconnect() {
        cancelReconnectDeadline()
        logEvent("Gave up reconnecting after \(Int(reconnectDeadline))s — releasing the link")
        reconnectGaveUp = true
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        connectionState = .idle
        statusMessage = "Couldn't reconnect to \(deviceName ?? "the bike"). If it's unresponsive, switch it off and on, then tap Scan."
        onDisconnect?()
    }

#if targetEnvironment(simulator)
    @ObservationIgnored private var simulationTask: Task<Void, Never>?
    private(set) var isSimulationPaused = false

    /// Simulator-only: fakes a connected bike streaming plausible FTMS metrics so
    /// the Ride screen and recording pipeline can be worked on without hardware.
    func startSimulatedRide() {
        guard connectionState != .connected else { return }

        deviceName = "Simulated Bike"
        connectionState = .connected
        statusMessage = "Simulated bike connected."
        onConnect?()

        simulationTask?.cancel()
        isSimulationPaused = false
        simulationTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isSimulationPaused {
                    let metrics = Self.simulatedMetrics(tick: tick)
                    self.metrics = metrics
                    self.metricsHandler?(metrics)
                    tick += 1
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func toggleSimulationPause() {
        guard connectionState == .connected else { return }
        isSimulationPaused.toggle()
        statusMessage = isSimulationPaused
            ? "Simulated bike paused."
            : "Simulated bike resumed."
    }

    private static func simulatedMetrics(tick: Int) -> BikeMetrics {
        let phase = Double(tick)
        let cadenceRPM = 80 + 15 * sin(phase / 10)
        let powerWatts = Int(150 + 60 * sin(phase / 8))
        let speedKPH = 28 + 6 * sin(phase / 12)
        // Grow the bike-reported energy total at a realistic rate: about 150 W of
        // gross metabolic output is roughly 0.17 kcal per second, not 2 kcal/s.
        let totalEnergyKcal = Int((Double(tick) * 0.17).rounded())
        return BikeMetrics(
            cadenceRPM: cadenceRPM,
            averageCadenceRPM: cadenceRPM,
            powerWatts: powerWatts,
            averagePowerWatts: powerWatts,
            speedKPH: speedKPH,
            averageSpeedKPH: speedKPH,
            resistanceLevel: 8 + 2 * sin(phase / 20),
            distanceMeters: Double(tick) * (speedKPH / 3.6),
            totalEnergyKcal: totalEnergyKcal,
            elapsedTimeSeconds: TimeInterval(tick),
            heartRate: Int(128 + 18 * sin(phase / 15)),
            rawPayload: "SIMULATED"
        )
    }
#endif
}

extension BikeManager: CBCentralManagerDelegate {
    // CoreBluetooth delivers these callbacks on the main queue (the central
    // manager is created with `queue: nil`), so it is safe to assume main-actor
    // isolation and touch the manager's @Published state synchronously.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        nonisolated(unsafe) let central = central
        MainActor.assumeIsolated {
            bluetoothState = central.state
            logEvent("Bluetooth state → \(Self.describe(central.state))")
            switch central.state {
            case .poweredOn:
                statusMessage = "Bluetooth is ready. Start scanning when the bike is awake."
                connectionState = .idle
                // Resume whatever the user or a relaunch asked for once power is on.
                if pendingScan {
                    beginScanning()
                } else if shouldAutoReconnect {
                    if !attemptReconnect() {
                        beginScanning()
                    }
                }
            case .poweredOff:
                statusMessage = "Bluetooth is turned off."
                connectionState = .bluetoothUnavailable
                pendingScan = false
                isScanning = false
            case .unauthorized:
                statusMessage = "Bluetooth access is not authorized for this app."
                connectionState = .bluetoothUnavailable
                pendingScan = false
                isScanning = false
            case .unsupported:
                statusMessage = "This device does not support Bluetooth LE."
                connectionState = .bluetoothUnavailable
                pendingScan = false
                isScanning = false
            case .resetting:
                statusMessage = "Bluetooth is resetting."
                connectionState = .idle
            case .unknown:
                statusMessage = "Bluetooth state is still being determined."
                connectionState = .idle
            @unknown default:
                statusMessage = "Bluetooth is in an unknown state."
                connectionState = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        nonisolated(unsafe) let dict = dict
        MainActor.assumeIsolated {
            // Reattach to the bike iOS kept connected while we were suspended/terminated.
            guard let peripheral = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else {
                logEvent("iOS relaunched the app to restore state, but no peripheral was handed back")
                return
            }

            connectedPeripheral = peripheral
            peripheral.delegate = self
            deviceName = preferredName(for: peripheral, fallback: "FTMS Bike")
            logEvent("iOS relaunched the app in the background — restoring \(deviceName ?? "bike") (state: \(Self.describe(peripheral.state)))")

            switch peripheral.state {
            case .connected:
                connectionState = .connecting
                statusMessage = "Reconnected to \(deviceName ?? "bike") after relaunch."
                // Re-discover so our characteristic references and notifications are live again.
                peripheral.discoverServices(nil)
                armDiscoveryTimeout(message: "Timed out while rediscovering Bluetooth services from \(self.deviceName ?? "the bike").")
            case .connecting:
                connectionState = .connecting
                statusMessage = "Reconnecting to \(deviceName ?? "bike")..."
            default:
                connectedPeripheral = nil
                deviceName = nil
                connectionState = .idle
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        nonisolated(unsafe) let central = central
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            isScanning = false
            deviceName = preferredName(for: peripheral, fallback: "Unnamed FTMS Bike")
            connectionState = .connecting
            statusMessage = "Connecting to \(deviceName ?? "bike")..."
            logEvent("Discovered \(deviceName ?? "bike") (RSSI \(RSSI)) — connecting")

            connectedPeripheral = peripheral
            peripheral.delegate = self

            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            // The bike came back within the deadline: stop the give-up countdown.
            cancelReconnectDeadline()
            // Remember this bike so we can auto-reconnect on the next launch.
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastBikeDefaultsKey)
            logEvent("Connected to \(deviceName ?? "bike") — discovering services")
            peripheral.discoverServices(nil)
            connectionState = .connecting
            statusMessage = "Connected. Discovering services..."
            armDiscoveryTimeout(message: "Timed out while discovering Bluetooth services from \(self.deviceName ?? "the bike").")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            cancelDiscoveryTimeout()
            cancelReconnectDeadline()
            logEvent("Failed to connect: \(describe(error))")
            connectedPeripheral = nil
            deviceName = nil
            connectionState = .idle
            statusMessage = error?.localizedDescription ?? "Could not connect to the bike."
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        nonisolated(unsafe) let central = central
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            cancelDiscoveryTimeout()
            isScanning = false

            // A callback for the connect request we just cancelled while giving up:
            // the terminal state is already set, so swallow it.
            if reconnectGaveUp {
                reconnectGaveUp = false
                intentionalDisconnect = false
                logEvent("Link released after giving up: \(describe(error))")
                return
            }

            // A callback for the link we deliberately released on backgrounding:
            // stay idle (no auto-reconnect) until the app is foregrounded again.
            if isSuspendedForBackground {
                intentionalDisconnect = false
                connectedPeripheral = nil
                connectionState = .idle
                logEvent("Link released for background: \(describe(error))")
                return
            }

            let wasIntentional = intentionalDisconnect
            intentionalDisconnect = false
            logEvent("Disconnected (\(wasIntentional ? "user-initiated" : "unexpected")): \(describe(error))")

            // A deliberate disconnect (or a drop with no known bike to return to)
            // settles into idle and ends the ride.
            guard !wasIntentional, connectedPeripheral?.identifier == peripheral.identifier else {
                connectedPeripheral = nil
                connectionState = .idle
                statusMessage = error?.localizedDescription ?? "Disconnected from the bike."
                onDisconnect?()
                return
            }

            // Unexpected drop: re-issue a timeout-free connect so iOS relinks the
            // moment the bike is back in range — even in the background — without a
            // new scan, and keep the in-progress ride open in the meantime.
            peripheral.delegate = self
            connectionState = .connecting
            statusMessage = "Connection lost. Reconnecting to \(deviceName ?? "your bike")…"
            logEvent("Re-issued timeout-free connect — waiting up to \(Int(reconnectDeadline))s for \(deviceName ?? "bike") to return")
            central.connect(peripheral, options: nil)
            armReconnectDeadline()
            onConnectionInterrupted?()
        }
    }
}

extension BikeManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            guard error == nil else {
                statusMessage = error?.localizedDescription ?? "Failed to discover FTMS services."
                return
            }

            guard let services = peripheral.services, !services.isEmpty else {
                statusMessage = "The bike did not expose any Bluetooth services."
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }

            let ftmsServices = services.filter { $0.uuid == FTMSUUID.service }
            let gapServices = services.filter { $0.uuid == FTMSUUID.genericAccess }

            gapServices.forEach { peripheral.discoverCharacteristics([FTMSUUID.deviceName], for: $0) }
            capabilities.discoveredServices = services.map(\.uuid.uuidString).sorted()

            guard !ftmsServices.isEmpty else {
                let discoveredServices = services.map(\.uuid.uuidString).joined(separator: ", ")
                statusMessage = "Connected, but no FTMS service (1826) was found. Services: \(discoveredServices)"
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }

            statusMessage = "Connected. Discovering FTMS characteristics..."
            armDiscoveryTimeout(message: "Timed out while discovering FTMS characteristics from \(self.deviceName ?? "the bike").")
            ftmsServices.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        nonisolated(unsafe) let peripheral = peripheral
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated {
            guard error == nil else {
                if service.uuid == FTMSUUID.genericAccess {
                    return
                }
                statusMessage = error?.localizedDescription ?? "Failed to discover Indoor Bike Data."
                return
            }

            if service.uuid == FTMSUUID.genericAccess {
                service.characteristics?
                    .filter { $0.uuid == FTMSUUID.deviceName }
                    .forEach { peripheral.readValue(for: $0) }
                return
            }

            if service.uuid == FTMSUUID.service {
                let characteristics = service.characteristics ?? []
                capabilities.hasIndoorBikeData = characteristics.contains { $0.uuid == FTMSUUID.indoorBikeData }
                capabilities.hasFitnessMachineFeature = characteristics.contains { $0.uuid == FTMSUUID.fitnessMachineFeature }
                capabilities.hasFitnessMachineStatus = characteristics.contains { $0.uuid == FTMSUUID.fitnessMachineStatus }
                capabilities.hasFitnessMachineControlPoint = characteristics.contains { $0.uuid == FTMSUUID.fitnessMachineControlPoint }
                capabilities.controlPointWritable = characteristics
                    .first { $0.uuid == FTMSUUID.fitnessMachineControlPoint }?
                    .properties.contains(.write) == true
                    || characteristics
                    .first { $0.uuid == FTMSUUID.fitnessMachineControlPoint }?
                    .properties.contains(.writeWithoutResponse) == true
                capabilities.hasSupportedResistanceLevelRange = characteristics.contains { $0.uuid == FTMSUUID.supportedResistanceLevelRange }
                capabilities.hasSupportedInclinationRange = characteristics.contains { $0.uuid == FTMSUUID.supportedInclinationRange }
                capabilities.discoveredCharacteristics = characteristics.map(\.uuid.uuidString).sorted()

                characteristics
                    .filter {
                        $0.uuid == FTMSUUID.fitnessMachineFeature
                            || $0.uuid == FTMSUUID.supportedResistanceLevelRange
                            || $0.uuid == FTMSUUID.supportedInclinationRange
                    }
                    .forEach { peripheral.readValue(for: $0) }
            }

            let bikeDataCharacteristics = service.characteristics?
                .filter { $0.uuid == FTMSUUID.indoorBikeData } ?? []
            guard !bikeDataCharacteristics.isEmpty else {
                let discoveredCharacteristics = service.characteristics?.map(\.uuid.uuidString).joined(separator: ", ") ?? "none"
                statusMessage = "FTMS service found, but Indoor Bike Data (2AD2) is missing. Characteristics: \(discoveredCharacteristics)"
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }

            bikeDataCharacteristics.forEach { peripheral.setNotifyValue(true, for: $0) }

            statusMessage = "Subscribed to Indoor Bike Data notifications."
            armDiscoveryTimeout(message: "Timed out while enabling Indoor Bike Data notifications on \(self.deviceName ?? "the bike").")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        nonisolated(unsafe) let characteristic = characteristic
        MainActor.assumeIsolated {
            guard error == nil else {
                statusMessage = error?.localizedDescription ?? "Could not enable live updates."
                return
            }

            if characteristic.isNotifying {
                cancelDiscoveryTimeout()
                connectionState = .connected
                statusMessage = "Live FTMS data is streaming."
                logEvent("Streaming live FTMS data from \(deviceName ?? "bike")")
                onConnect?()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        nonisolated(unsafe) let characteristic = characteristic
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            if characteristic.uuid == FTMSUUID.deviceName {
                guard error == nil,
                      let data = characteristic.value,
                      let name = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty
                else { return }

                rememberDeviceName(name, for: peripheral)
                return
            }

            if characteristic.uuid == FTMSUUID.fitnessMachineFeature {
                guard error == nil, let data = characteristic.value else { return }
                capabilities.featureRawValue = data.hexString
                if data.count >= 8 {
                    capabilities.machineFeatures = UInt32(data[0])
                        | (UInt32(data[1]) << 8)
                        | (UInt32(data[2]) << 16)
                        | (UInt32(data[3]) << 24)
                    capabilities.targetSettingFeatures = UInt32(data[4])
                        | (UInt32(data[5]) << 8)
                        | (UInt32(data[6]) << 16)
                        | (UInt32(data[7]) << 24)
                }
                return
            }

            if characteristic.uuid == FTMSUUID.supportedResistanceLevelRange {
                guard error == nil, let data = characteristic.value else { return }
                capabilities.supportedResistanceLevelRange = FTMSRangeParser.parse(data: data, scale: 0.1)
                return
            }

            if characteristic.uuid == FTMSUUID.supportedInclinationRange {
                guard error == nil, let data = characteristic.value else { return }
                capabilities.supportedInclinationRange = FTMSRangeParser.parse(data: data, scale: 0.1, suffix: "%")
                return
            }

            guard error == nil, let data = characteristic.value else {
                statusMessage = error?.localizedDescription ?? "Received an empty FTMS packet."
                return
            }

            let parsedMetrics = BikeMetricsParser.parse(data: data)
            metrics = parsedMetrics
            metricsHandler?(parsedMetrics)
            statusMessage = "Receiving live data from \(deviceName ?? "bike")."
        }
    }
}

