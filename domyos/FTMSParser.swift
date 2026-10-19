//
//  FTMSParser.swift
//  domyos
//
//  Byte-level parsing for FTMS Indoor Bike Data packets and related ranges.
//

import CoreBluetooth
import Foundation

enum BikeMetricsParser {
    nonisolated static func parse(data: Data) -> BikeMetrics {
        var reader = FTMSDataReader(data: data)

        guard let flags = reader.readUInt16() else {
            return BikeMetrics(rawPayload: data.hexString)
        }

        let moreData = flags & (1 << 0) != 0
        let averageSpeedPresent = flags & (1 << 1) != 0
        let instantaneousCadencePresent = flags & (1 << 2) != 0
        let averageCadencePresent = flags & (1 << 3) != 0
        let totalDistancePresent = flags & (1 << 4) != 0
        let resistanceLevelPresent = flags & (1 << 5) != 0
        let instantaneousPowerPresent = flags & (1 << 6) != 0
        let averagePowerPresent = flags & (1 << 7) != 0
        let expendedEnergyPresent = flags & (1 << 8) != 0
        let heartRatePresent = flags & (1 << 9) != 0
        let metabolicEquivalentPresent = flags & (1 << 10) != 0
        let elapsedTimePresent = flags & (1 << 11) != 0
        let remainingTimePresent = flags & (1 << 12) != 0

        var metrics = BikeMetrics(rawPayload: data.hexString)
        metrics.flags = flags
        metrics.isInstantaneousSpeedPresent = !moreData
        metrics.isAverageSpeedPresent = averageSpeedPresent
        metrics.isInstantaneousCadencePresent = instantaneousCadencePresent
        metrics.isAverageCadencePresent = averageCadencePresent
        metrics.isTotalDistancePresent = totalDistancePresent
        metrics.isResistanceLevelPresent = resistanceLevelPresent
        metrics.isInstantaneousPowerPresent = instantaneousPowerPresent
        metrics.isAveragePowerPresent = averagePowerPresent
        metrics.isExpendedEnergyPresent = expendedEnergyPresent
        metrics.isHeartRatePresent = heartRatePresent
        metrics.isMetabolicEquivalentPresent = metabolicEquivalentPresent
        metrics.isElapsedTimePresent = elapsedTimePresent
        metrics.isRemainingTimePresent = remainingTimePresent

        if !moreData, let speed = reader.readUInt16() {
            metrics.speedKPH = Double(speed) / 100
        }

        if averageSpeedPresent, let averageSpeed = reader.readUInt16() {
            metrics.averageSpeedKPH = Double(averageSpeed) / 100
        }

        if instantaneousCadencePresent, let cadence = reader.readUInt16() {
            metrics.cadenceRPM = Double(cadence) / 2
        }

        if averageCadencePresent, let averageCadence = reader.readUInt16() {
            metrics.averageCadenceRPM = Double(averageCadence) / 2
        }

        if totalDistancePresent, let distance = reader.readUInt24() {
            metrics.distanceMeters = Double(distance)
        }

        if resistanceLevelPresent, let resistance = reader.readInt16() {
            metrics.resistanceLevel = Double(resistance) / 10
        }

        if instantaneousPowerPresent, let power = reader.readInt16() {
            metrics.powerWatts = Int(power)
        }

        if averagePowerPresent, let averagePower = reader.readInt16() {
            metrics.averagePowerWatts = Int(averagePower)
        }

        if expendedEnergyPresent {
            if let totalEnergy = reader.readUInt16() {
                metrics.totalEnergyKcal = Int(totalEnergy)
            }
            if let energyPerHour = reader.readUInt16() {
                metrics.energyPerHourKcal = Int(energyPerHour)
            }
            if let energyPerMinute = reader.readUInt8() {
                metrics.energyPerMinuteKcal = Int(energyPerMinute)
            }
        }

        if heartRatePresent, let heartRate = reader.readUInt8() {
            metrics.heartRate = Int(heartRate)
        }

        if metabolicEquivalentPresent, let metabolicEquivalent = reader.readUInt8() {
            metrics.metabolicEquivalent = Double(metabolicEquivalent) / 10
        }

        if elapsedTimePresent, let elapsedTime = reader.readUInt16() {
            metrics.elapsedTimeSeconds = TimeInterval(elapsedTime)
        }

        if remainingTimePresent, let remainingTime = reader.readUInt16() {
            metrics.remainingTimeSeconds = TimeInterval(remainingTime)
        }

        return metrics
    }
}

enum FTMSUUID {
    nonisolated(unsafe) static let service = CBUUID(string: "1826")
    nonisolated(unsafe) static let fitnessMachineFeature = CBUUID(string: "2ACC")
    nonisolated(unsafe) static let indoorBikeData = CBUUID(string: "2AD2")
    nonisolated(unsafe) static let supportedInclinationRange = CBUUID(string: "2AD5")
    nonisolated(unsafe) static let supportedResistanceLevelRange = CBUUID(string: "2AD6")
    nonisolated(unsafe) static let fitnessMachineControlPoint = CBUUID(string: "2AD9")
    nonisolated(unsafe) static let fitnessMachineStatus = CBUUID(string: "2ADA")
    nonisolated(unsafe) static let genericAccess = CBUUID(string: "1800")
    nonisolated(unsafe) static let deviceName = CBUUID(string: "2A00")
}

private nonisolated struct FTMSDataReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func readUInt8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() -> UInt16? {
        guard offset + 1 < bytes.count else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    mutating func readInt16() -> Int16? {
        guard let value = readUInt16() else { return nil }
        return Int16(bitPattern: value)
    }

    mutating func readUInt24() -> UInt32? {
        guard offset + 2 < bytes.count else { return nil }
        defer { offset += 3 }
        return UInt32(bytes[offset]) |
            (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16)
    }
}

nonisolated extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

enum FTMSRangeParser {
    static func parse(data: Data, scale: Double, suffix: String = "") -> String? {
        var reader = FTMSDataReader(data: data)
        guard let minimum = reader.readInt16(),
              let maximum = reader.readInt16(),
              let increment = reader.readUInt16()
        else { return nil }

        return [
            format(Double(minimum) * scale, suffix: suffix),
            format(Double(maximum) * scale, suffix: suffix),
            format(Double(increment) * scale, suffix: suffix)
        ]
        .enumerated()
        .map { index, value in
            switch index {
            case 0: "min \(value)"
            case 1: "max \(value)"
            default: "step \(value)"
            }
        }
        .joined(separator: ", ")
    }

    private static func format(_ value: Double, suffix: String) -> String {
        let number = String(format: value.rounded(.towardZero) == value ? "%.0f" : "%.1f", value)
        return suffix.isEmpty ? number : "\(number)\(suffix)"
    }
}
