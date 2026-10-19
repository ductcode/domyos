//
//  domyosTests.swift
//  domyosTests
//
//  Created by Georg von der Howen on 24.07.26.
//

import Foundation
import Testing
@testable import domyos

struct domyosTests {

    @Test @MainActor func cyclingEnergyIncludesMechanicalWorkAndRestingCalories() {
        // 100 W for 25 minutes = 150 kJ of bike work, about 149 kcal at 24%
        // cycling efficiency, plus 31.25 resting kcal for a 75 kg rider.
        let calories = CyclingEnergyEstimator.kilocalories(
            powerWatts: 100,
            duration: 25 * 60,
            bodyMassKilograms: 75
        )

        #expect(abs(calories - 180.6) < 0.1)
    }

    @Test @MainActor func cyclingEnergyIsZeroWithoutWorkOrTime() {
        #expect(CyclingEnergyEstimator.kilocalories(powerWatts: 0, duration: 60, bodyMassKilograms: 0) == 0)
        #expect(CyclingEnergyEstimator.kilocalories(powerWatts: 100, duration: 0, bodyMassKilograms: 75) == 0)
    }

    @Test @MainActor func parserRetainsBikeReportedAverages() {
        // Flags: instantaneous speed/cadence/power plus average speed/cadence/power are present.
        let data = Data([
            0xCE, 0x00,
            0xB8, 0x0B, // instantaneous speed: 30.00 km/h
            0xBE, 0x0A, // average speed: 27.50 km/h
            0xA0, 0x00, // instantaneous cadence: 80 rpm
            0x96, 0x00, // average cadence: 75 rpm
            0xC8, 0x00, // instantaneous power: 200 W
            0xAF, 0x00  // average power: 175 W
        ])

        let metrics = BikeMetricsParser.parse(data: data)

        #expect(metrics.averageSpeedKPH == 27.5)
        #expect(metrics.averageCadenceRPM == 75)
        #expect(metrics.averagePowerWatts == 175)
    }

    @Test @MainActor func parserRetainsBikeReportedTotalEnergy() {
        // Flags: expended energy present.
        let data = Data([
            0x00, 0x01,
            0xB8, 0x0B, // instantaneous speed: 30.00 km/h
            0x41, 0x01, // total energy: 321 kcal
            0x00, 0x00, // energy per hour
            0x00        // energy per minute
        ])

        let metrics = BikeMetricsParser.parse(data: data)

        #expect(metrics.totalEnergyKcal == 321)
    }

    @Test @MainActor func parserRetainsBikeReportedElapsedTime() {
        // Flags: elapsed time present.
        let data = Data([
            0x00, 0x08,
            0xB8, 0x0B, // instantaneous speed: 30.00 km/h
            0x2C, 0x01  // elapsed time: 300 s
        ])

        let metrics = BikeMetricsParser.parse(data: data)

        #expect(metrics.elapsedTimeSeconds == 300)
    }

    @Test @MainActor func heartRateWarmupFilterSkipsInitialMachineRamp() {
        var filter = HeartRateWarmupFilter()

        #expect(filter.shouldInclude(80) == false)
        #expect(filter.shouldInclude(88) == false)
        #expect(filter.shouldInclude(96) == false)
        #expect(filter.shouldInclude(104) == false)
        #expect(filter.shouldInclude(104) == true)
        #expect(filter.shouldInclude(106) == true)
    }

    @Test @MainActor func heartRateWarmupFilterIncludesImmediatelyWithoutSyntheticStart() {
        var filter = HeartRateWarmupFilter()

        #expect(filter.shouldInclude(112) == true)
        #expect(filter.shouldInclude(114) == true)
    }

    @Test @MainActor func heartRateWarmupFilterCanResetForNextWorkout() {
        var filter = HeartRateWarmupFilter()

        #expect(filter.shouldInclude(80) == false)
        #expect(filter.shouldInclude(90) == false)
        #expect(filter.shouldInclude(90) == true)

        filter.reset()

        #expect(filter.shouldInclude(80) == false)
    }

}
