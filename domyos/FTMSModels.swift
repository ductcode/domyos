//
//  FTMSModels.swift
//  domyos
//
//  Shared FTMS state, metrics, capabilities, and diagnostic display models.
//

import Foundation
import SwiftUI

enum ConnectionState {
    case idle
    case scanning
    case connecting
    case connected
    case bluetoothUnavailable

    var title: String {
        switch self {
        case .idle: "Ready"
        case .scanning: "Scanning"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .bluetoothUnavailable: "Bluetooth Unavailable"
        }
    }

    var icon: String {
        switch self {
        case .idle: "bolt.horizontal.circle"
        case .scanning: "dot.radiowaves.left.and.right"
        case .connecting: "link"
        case .connected: "checkmark.circle.fill"
        case .bluetoothUnavailable: "bolt.slash.circle"
        }
    }

    var color: Color {
        switch self {
        case .idle: .blue
        case .scanning: .orange
        case .connecting: .orange
        case .connected: .green
        case .bluetoothUnavailable: .red
        }
    }
}

struct BikeMetrics: Sendable {
    var flags: UInt16?
    var isInstantaneousSpeedPresent = false
    var isAverageSpeedPresent = false
    var isInstantaneousCadencePresent = false
    var isAverageCadencePresent = false
    var isTotalDistancePresent = false
    var isResistanceLevelPresent = false
    var isInstantaneousPowerPresent = false
    var isAveragePowerPresent = false
    var isExpendedEnergyPresent = false
    var isHeartRatePresent = false
    var isMetabolicEquivalentPresent = false
    var isElapsedTimePresent = false
    var isRemainingTimePresent = false
    var cadenceRPM: Double?
    var averageCadenceRPM: Double?
    var powerWatts: Int?
    var averagePowerWatts: Int?
    var speedKPH: Double?
    var averageSpeedKPH: Double?
    var resistanceLevel: Double?
    var distanceMeters: Double?
    var totalEnergyKcal: Int?
    var energyPerHourKcal: Int?
    var energyPerMinuteKcal: Int?
    var elapsedTimeSeconds: TimeInterval?
    var remainingTimeSeconds: TimeInterval?
    var heartRate: Int?
    var metabolicEquivalent: Double?
    var rawPayload: String?

    var cadenceText: String { MetricFormatter.cadence(cadenceRPM) }
    var powerText: String { MetricFormatter.power(powerWatts) }
    var speedText: String { MetricFormatter.speed(speedKPH) }
    var resistanceText: String { MetricFormatter.decimal(resistanceLevel, decimals: 1) }
    var distanceText: String { MetricFormatter.distance(distanceMeters) }
    var heartRateText: String { MetricFormatter.heartRate(heartRate) }
    var averageCadenceText: String { MetricFormatter.cadence(averageCadenceRPM) }
    var averagePowerText: String { MetricFormatter.power(averagePowerWatts) }
    var averageSpeedText: String { MetricFormatter.speed(averageSpeedKPH) }
    var totalEnergyText: String { MetricFormatter.energy(totalEnergyKcal.map(Double.init)) }
    var energyPerHourText: String { energyPerHourKcal.map { "\($0) kcal/h" } ?? "--" }
    var energyPerMinuteText: String { energyPerMinuteKcal.map { "\($0) kcal/min" } ?? "--" }
    var elapsedTimeText: String { MetricFormatter.duration(elapsedTimeSeconds) }
    var remainingTimeText: String { MetricFormatter.duration(remainingTimeSeconds) }
    var metabolicEquivalentText: String { MetricFormatter.decimal(metabolicEquivalent, suffix: "MET", decimals: 1) }

    /// - Parameter includeEmpty: when true, fields absent from the packet are also
    ///   listed (shown as `--`) so you can see which the bike never sends.
    func diagnosticEntries(includeEmpty: Bool = false) -> [DiagnosticEntry] {
        let entries = [
            DiagnosticEntry(key: "Flags", value: flags.map { String(format: "0x%04X", $0) } ?? "--"),
            entry("Instantaneous Speed", isPresent: isInstantaneousSpeedPresent, value: speedText, includeEmpty: includeEmpty),
            entry("Average Speed", isPresent: isAverageSpeedPresent, value: averageSpeedText, includeEmpty: includeEmpty),
            entry("Instantaneous Cadence", isPresent: isInstantaneousCadencePresent, value: cadenceText, includeEmpty: includeEmpty),
            entry("Average Cadence", isPresent: isAverageCadencePresent, value: averageCadenceText, includeEmpty: includeEmpty),
            entry("Total Distance", isPresent: isTotalDistancePresent, value: distanceText, includeEmpty: includeEmpty),
            entry("Resistance Level", isPresent: isResistanceLevelPresent, value: resistanceText, includeEmpty: includeEmpty),
            entry("Instantaneous Power", isPresent: isInstantaneousPowerPresent, value: powerText, includeEmpty: includeEmpty),
            entry("Average Power", isPresent: isAveragePowerPresent, value: averagePowerText, includeEmpty: includeEmpty),
            entry("Total Energy", isPresent: isExpendedEnergyPresent, value: totalEnergyText, includeEmpty: includeEmpty),
            entry("Energy Per Hour", isPresent: isExpendedEnergyPresent, value: energyPerHourText, includeEmpty: includeEmpty),
            entry("Energy Per Minute", isPresent: isExpendedEnergyPresent, value: energyPerMinuteText, includeEmpty: includeEmpty),
            entry("Heart Rate", isPresent: isHeartRatePresent, value: heartRateText, includeEmpty: includeEmpty),
            entry("Metabolic Equivalent", isPresent: isMetabolicEquivalentPresent, value: metabolicEquivalentText, includeEmpty: includeEmpty),
            entry("Elapsed Time", isPresent: isElapsedTimePresent, value: elapsedTimeText, includeEmpty: includeEmpty),
            entry("Remaining Time", isPresent: isRemainingTimePresent, value: remainingTimeText, includeEmpty: includeEmpty),
            DiagnosticEntry(key: "Raw Payload", value: rawPayload ?? "--")
        ]
        .compactMap { $0 }
        return entries.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    var indicatesActivity: Bool {
        (cadenceRPM ?? 0) > 0
            || (powerWatts ?? 0) > 0
            || (speedKPH ?? 0) > 0
    }

    private func entry(_ key: String, isPresent: Bool, value: String, includeEmpty: Bool) -> DiagnosticEntry? {
        guard includeEmpty || isPresent else { return nil }
        return DiagnosticEntry(key: key, value: value)
    }
}

struct DiagnosticEntry: Identifiable, Sendable {
    let key: String
    let value: String

    var id: String { key }
}

struct FTMSCapabilities: Sendable {
    var discoveredServices: [String] = []
    var discoveredCharacteristics: [String] = []
    var hasIndoorBikeData = false
    var hasFitnessMachineFeature = false
    var hasFitnessMachineStatus = false
    var hasFitnessMachineControlPoint = false
    var controlPointWritable = false
    var hasSupportedResistanceLevelRange = false
    var hasSupportedInclinationRange = false
    var featureRawValue: String?
    var machineFeatures: UInt32?
    var targetSettingFeatures: UInt32?
    var supportedResistanceLevelRange: String?
    var supportedInclinationRange: String?

    func diagnosticEntries() -> [DiagnosticEntry] {
        [
            DiagnosticEntry(key: "FTMS Service", value: "0x1826"),
            DiagnosticEntry(key: "Indoor Bike Data UUID", value: "0x2AD2"),
            DiagnosticEntry(key: "FTMS Control Point", value: yesNo(hasFitnessMachineControlPoint)),
            DiagnosticEntry(key: "FTMS Control Writable", value: yesNo(controlPointWritable)),
            DiagnosticEntry(key: "FTMS Feature Characteristic", value: yesNo(hasFitnessMachineFeature)),
            DiagnosticEntry(key: "FTMS Status Characteristic", value: yesNo(hasFitnessMachineStatus)),
            DiagnosticEntry(key: "Indoor Bike Data Characteristic", value: yesNo(hasIndoorBikeData)),
            DiagnosticEntry(key: "Supported Resistance Range Characteristic", value: yesNo(hasSupportedResistanceLevelRange)),
            DiagnosticEntry(key: "Supported Inclination Range Characteristic", value: yesNo(hasSupportedInclinationRange)),
            DiagnosticEntry(key: "Resistance Range", value: supportedResistanceLevelRange ?? "--"),
            DiagnosticEntry(key: "Inclination Range", value: supportedInclinationRange ?? "--"),
            DiagnosticEntry(key: "Feature Flags Raw", value: featureRawValue ?? "--"),
            DiagnosticEntry(key: "Machine Features Bits", value: machineFeatures.map(hex32) ?? "--"),
            DiagnosticEntry(key: "Target Setting Bits", value: targetSettingFeatures.map(hex32) ?? "--"),
            DiagnosticEntry(
                key: "Discovered FTMS Characteristics",
                value: discoveredCharacteristics.isEmpty ? "--" : discoveredCharacteristics.joined(separator: ", ")
            ),
            DiagnosticEntry(
                key: "Discovered Services",
                value: discoveredServices.isEmpty ? "--" : discoveredServices.joined(separator: ", ")
            )
        ]
        .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func hex32(_ value: UInt32) -> String {
        String(format: "0x%08X", value)
    }
}
