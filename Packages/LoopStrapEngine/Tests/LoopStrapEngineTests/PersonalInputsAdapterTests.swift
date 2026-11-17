import XCTest
@testable import LoopStrapEngine

final class MaxHeartRatePolicyTests: XCTestCase {
    func testReferenceValidation() {
        XCTAssertNotNil(MaxHeartRateReference(bpm: 190, provenance: "manual"))
        XCTAssertNil(MaxHeartRateReference(bpm: .nan, provenance: "manual"))
        XCTAssertNil(MaxHeartRateReference(bpm: 300, provenance: "manual"))
        XCTAssertNil(MaxHeartRateReference(bpm: 190, provenance: "  "))
    }

    func testPrecedenceOverrideThenPersonalThenEstimate() {
        let p = MaxHeartRateReference(bpm: 190, provenance: "measured")
        XCTAssertEqual(MaxHeartRatePolicy.fixedValue(override: 185, personal: p), 185)
        XCTAssertEqual(MaxHeartRatePolicy.fixedValue(override: nil, personal: p), 190)
        XCTAssertNil(MaxHeartRatePolicy.fixedValue(override: nil, personal: nil))
    }

    func testCacheKeyUnchangedWithoutPersonalAndInvalidatedByValueOrProvenance() {
        XCTAssertEqual(MaxHeartRatePolicy.cacheKeyComponent(override: nil, personal: nil), "estimated")
        XCTAssertEqual(MaxHeartRatePolicy.cacheKeyComponent(override: 185, personal: nil), String(185.0))
        let a = MaxHeartRatePolicy.cacheKeyComponent(override: nil, personal: MaxHeartRateReference(bpm: 190, provenance: "manual"))
        let b = MaxHeartRatePolicy.cacheKeyComponent(override: nil, personal: MaxHeartRateReference(bpm: 191, provenance: "manual"))
        let c = MaxHeartRatePolicy.cacheKeyComponent(override: nil, personal: MaxHeartRateReference(bpm: 190, provenance: "measured"))
        XCTAssertEqual(Set([a, b, c, "estimated"]).count, 4)
        // The override (replay) hides the personal value, in the value and in the key.
        XCTAssertEqual(MaxHeartRatePolicy.cacheKeyComponent(override: 185, personal: MaxHeartRateReference(bpm: 190, provenance: "manual")),
                       MaxHeartRatePolicy.cacheKeyComponent(override: 185, personal: nil))
    }
}

final class TrainingInputsAdapterTests: XCTestCase {
    func testNoUsableDataReturnsNil() {
        XCTAssertNil(TrainingInputsAdapter.makeInputs(asOfDay: 100, days: []))
        XCTAssertNil(TrainingInputsAdapter.makeInputs(
            asOfDay: 100,
            days: [TrainingDayRecord(day: 99, strain: nil, recovery: nil),
                   TrainingDayRecord(day: 98, strain: .nan, recovery: 140)],
            sleep: [TrainingSleepRecord(day: 99, totalSleepMin: nil, efficiency: nil)]))
        // Data only after asOfDay is ignored.
        XCTAssertNil(TrainingInputsAdapter.makeInputs(
            asOfDay: 100, days: [TrainingDayRecord(day: 101, strain: 10)]))
    }

    func testMapsDaysSleepSessionsAndRPE() throws {
        let inputs = try XCTUnwrap(TrainingInputsAdapter.makeInputs(
            asOfDay: 100,
            days: [TrainingDayRecord(day: 100, strain: 12.5, recovery: 64, recoveryConfidence: "high")],
            sleep: [TrainingSleepRecord(day: 100, totalSleepMin: 408, efficiency: 0.9, disturbances: 3)],
            workouts: [
                TrainingWorkoutRecord(id: "external:RUN", day: 100, kind: "running", sportType: 37,
                                      startTs: 1_000, endTs: 3_400, durationS: 2_400, strain: 11.3),
                TrainingWorkoutRecord(id: "external:WALK", day: 100, kind: "walking", sportType: 52,
                                      startTs: 5_000, endTs: 7_000, perceivedEffort: 3)
            ],
            perceivedEfforts: ["external:RUN": 7]))
        XCTAssertEqual(inputs.dailyLoads.map(\.value), [12.5])
        XCTAssertEqual(inputs.recovery.first?.confidence, .high)
        XCTAssertEqual(inputs.sleep.first?.durationMinutes, 408)
        XCTAssertEqual(inputs.sleep.first?.awakenings, 3)
        XCTAssertEqual(inputs.sessions.map(\.id), ["external:RUN", "external:WALK"])
        let run = inputs.sessions[0]
        XCTAssertEqual(run.sport, .run)
        XCTAssertEqual(run.durationMinutes, 40)
        XCTAssertEqual(run.cardioLoad, 11.3)
        XCTAssertEqual(run.srpeLoad, 280)
        let walk = inputs.sessions[1]
        XCTAssertEqual(walk.sport, .other)
        XCTAssertEqual(walk.durationMinutes, 2_000.0 / 60)
        XCTAssertEqual(walk.perceivedExertion, 3)
        XCTAssertNil(walk.cardioLoad)
        // RPE is never folded into the daily cardio load.
        XCTAssertEqual(inputs.dailyLoads.first?.value, 12.5)
    }

    func testRPEAbsentOrInvalidStaysNil() throws {
        let inputs = try XCTUnwrap(TrainingInputsAdapter.makeInputs(
            asOfDay: 10, days: [],
            workouts: [TrainingWorkoutRecord(id: "a", day: 10, kind: nil, startTs: 0, endTs: 600),
                       TrainingWorkoutRecord(id: "b", day: 10, kind: nil, startTs: 900, endTs: 1500, perceivedEffort: 11)]))
        XCTAssertEqual(inputs.sessions.count, 2)
        XCTAssertTrue(inputs.sessions.allSatisfy { $0.perceivedExertion == nil && $0.srpeLoad == nil })
    }

    func testOrderIndependentAndDuplicatesMerged() throws {
        let days = [TrainingDayRecord(day: 3, strain: 8), TrainingDayRecord(day: 1, strain: 5),
                    TrainingDayRecord(day: 2, strain: 6)]
        let workouts = [
            TrainingWorkoutRecord(id: "w1", day: 2, kind: "running", startTs: 200, endTs: 800, strain: 4),
            TrainingWorkoutRecord(id: "w0", day: 1, kind: "swimming", startTs: 100, endTs: 700),
            TrainingWorkoutRecord(id: "w1", day: 2, kind: "running", startTs: 200, endTs: 800, perceivedEffort: 6)
        ]
        let sleep = [TrainingSleepRecord(day: 2, totalSleepMin: 400), TrainingSleepRecord(day: 1, totalSleepMin: 380)]
        let a = try XCTUnwrap(TrainingInputsAdapter.makeInputs(asOfDay: 3, days: days, sleep: sleep, workouts: workouts))
        let b = try XCTUnwrap(TrainingInputsAdapter.makeInputs(asOfDay: 3, days: days.reversed(),
                                                               sleep: sleep.reversed(), workouts: workouts.reversed()))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.dailyLoads.map(\.day), [1, 2, 3])
        XCTAssertEqual(a.sleep.map(\.day), [1, 2])
        XCTAssertEqual(a.sessions.map(\.id), ["w0", "w1"])
        let w1 = a.sessions[1]
        XCTAssertEqual(w1.cardioLoad, 4)
        XCTAssertEqual(w1.perceivedExertion, 6)
        XCTAssertEqual(a.sessions[0].sport, .swim)
        // The analytics module accepts the result.
        _ = TrainingStats.compute(a)
    }

    func testSportMapping() {
        XCTAssertEqual(TrainingInputsAdapter.sport(kind: nil, sportType: 50), .strength)
        XCTAssertEqual(TrainingInputsAdapter.sport(kind: "running", sportType: 13), .other)
        XCTAssertEqual(TrainingInputsAdapter.sport(kind: "detected_cardio", sportType: nil), .other)
        XCTAssertEqual(TrainingInputsAdapter.sport(kind: "Running", sportType: nil), .run)
    }
}
