//
//  MetricFormatter.swift
//  domyos
//
//  Shared display formatting for ride metrics across the app and widget.
//

import Foundation

enum MetricFormatter {
    static func decimal(_ value: Double?, suffix: String = "", decimals: Int) -> String {
        guard let value else { return "--" }
        let number = String(format: "%.\(decimals)f", value)
        return suffix.isEmpty ? number : "\(number) \(suffix)"
    }

    static func power(_ watts: Int?) -> String {
        watts.map { "\($0) W" } ?? "--"
    }

    static func powerWithPlaceholderUnit(_ watts: Int?) -> String {
        watts.map { "\($0) W" } ?? "-- W"
    }

    static func cadence(_ rpm: Double?) -> String {
        decimal(rpm, suffix: "rpm", decimals: 1)
    }

    static func cadenceWhole(_ rpm: Double?) -> String {
        rpm.map { String(format: "%.0f", $0) } ?? "--"
    }

    static func cadenceWholeWithUnit(_ rpm: Double?) -> String {
        rpm.map { String(format: "%.0f rpm", $0) } ?? "-- rpm"
    }

    static func speed(_ kph: Double?) -> String {
        decimal(kph, suffix: "km/h", decimals: 1)
    }

    static func speedWithPlaceholderUnit(_ kph: Double?) -> String {
        kph.map { String(format: "%.1f km/h", $0) } ?? "-- km/h"
    }

    static func heartRate(_ bpm: Int?) -> String {
        bpm.map { "\($0) bpm" } ?? "--"
    }

    static func heartRateWithPlaceholderUnit(_ bpm: Int?) -> String {
        bpm.map { "\($0) bpm" } ?? "-- bpm"
    }

    static func wholeNumber(_ value: Double?) -> String? {
        value.map { String(format: "%.0f", $0) }
    }

    static func oneDecimal(_ value: Double?) -> String? {
        value.map { String(format: "%.1f", $0) }
    }

    static func energy(_ kcal: Double?) -> String {
        kcal.map { "\(Int($0.rounded())) kcal" } ?? "--"
    }

    static func energyWithPlaceholderUnit(_ kcal: Double?) -> String {
        kcal.map { "\(Int($0.rounded())) kcal" } ?? "-- kcal"
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters else { return "--" }
        return distance(meters)
    }

    static func distance(_ meters: Double, kilometerDecimals: Int = 2) -> String {
        if meters >= 1000 {
            return String(format: "%.\(kilometerDecimals)f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }

    static func duration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "--" }
        return duration(interval)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    static func compactDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    static func clockTime(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func weight(_ kilograms: Double) -> String {
        String(format: "%.1f kg", kilograms)
    }
}
