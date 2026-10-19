//
//  MetricFormatter.swift
//  DomyosWidget
//
//  Widget-target metric formatting used by the Live Activity.
//

import Foundation

enum MetricFormatter {
    static func powerWithPlaceholderUnit(_ watts: Int?) -> String {
        watts.map { "\($0) W" } ?? "-- W"
    }

    static func cadenceWhole(_ rpm: Double?) -> String {
        rpm.map { String(format: "%.0f", $0) } ?? "--"
    }

    static func cadenceWholeWithUnit(_ rpm: Double?) -> String {
        rpm.map { String(format: "%.0f rpm", $0) } ?? "-- rpm"
    }

    static func speedWithPlaceholderUnit(_ kph: Double?) -> String {
        kph.map { String(format: "%.1f km/h", $0) } ?? "-- km/h"
    }

    static func heartRateWithPlaceholderUnit(_ bpm: Int?) -> String {
        bpm.map { "\($0) bpm" } ?? "-- bpm"
    }

    static func energyWithPlaceholderUnit(_ kcal: Double?) -> String {
        kcal.map { "\(Int($0.rounded())) kcal" } ?? "-- kcal"
    }
}
