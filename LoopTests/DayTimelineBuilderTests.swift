import XCTest
@testable import Loop

/// Fusion et filtrage de la timeline « Journée » (fonction pure, rien n'est écrit en base).
final class DayTimelineBuilderTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-12 00:00:00 UTC.
    private let dayStart = 1_794_441_600
    private let day = "2026-11-12"

    private func at(_ h: Int, _ m: Int) -> Int { dayStart + h * 3600 + m * 60 }

    private func workout(_ start: Int, _ end: Int, kind: String?, sportType: Int? = nil,
                         source: String? = nil, avgHr: Double? = nil, peakHr: Int? = nil) -> WorkoutSession {
        WorkoutSession(deviceId: "band", startTs: start, endTs: end, avgHr: avgHr, peakHr: peakHr,
                       strain: nil, kind: kind, durationS: end - start, caloriesKcal: nil,
                       sportType: sportType, sourceName: source,
                       externalID: source == nil ? nil : "hk-\(start)")
    }

    private func sleep(_ start: Int, _ end: Int) -> SleepSession {
        SleepSession(startTs: start, endTs: end, efficiency: nil, restingHr: nil, avgHrv: nil, stages: nil)
    }

    func testTwoOverlappingRunsMergeWithMostReliableSource() {
        let bandRun = workout(at(14, 17), at(14, 50), kind: "running", avgHr: 140)
        let watchRun = workout(at(14, 26), at(15, 42), kind: "running", sportType: 37,
                               source: "Apple Watch de Théo", avgHr: 152, peakHr: 178)
        let r = DayTimelineBuilder.build(day: day, sleep: [], workouts: [bandRun, watchRun], timeZone: utc)

        XCTAssertEqual(r.entries.count, 1)
        let e = try! XCTUnwrap(r.entries.first)
        XCTAssertEqual(e.kind, .workout(.run))
        XCTAssertEqual(e.source, .appleWatch)
        XCTAssertEqual(e.mergedSources, [.bracelet])
        XCTAssertEqual(e.start, at(14, 17))
        XCTAssertEqual(e.end, at(15, 42))
        XCTAssertEqual(e.avgHr, 152)
        XCTAssertEqual(e.peakHr, 178)
        XCTAssertEqual(e.workoutID, watchRun.id)
    }

    func testRunsTouchingWithinTenMinutesMergeButDifferentSportsDoNot() {
        let shortRun = workout(at(14, 17), at(14, 20), kind: "running")
        let run = workout(at(14, 26), at(15, 42), kind: "running", sportType: 37, source: "Strava")
        let walk = workout(at(15, 45), at(16, 30), kind: "walking", sportType: 52, source: "Strava")
        let r = DayTimelineBuilder.build(day: day, sleep: [], workouts: [shortRun, run, walk], timeZone: utc)

        XCTAssertEqual(r.entries.map(\.kind), [.workout(.run), .workout(.walk)])
        XCTAssertTrue(r.fragments.isEmpty, "le fragment de 3 min est absorbé par la course voisine")
    }

    func testTwoMinuteFragmentIsHiddenAndCounted() {
        let fragment = workout(at(9, 0), at(9, 2), kind: "detected_cardio")
        let run = workout(at(18, 0), at(18, 45), kind: "running", sportType: 37, source: "Apple Watch")
        let r = DayTimelineBuilder.build(day: day, sleep: [], workouts: [fragment, run], timeZone: utc)

        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries.first?.kind, .workout(.run))
        XCTAssertEqual(r.fragments.count, 1)
        XCTAssertEqual(r.fragments.first?.durationMinutes, 2)
    }

    func testWorkoutOverlappingSleepIsFlagged() {
        // Nuit du 12 au 13 : 23:00 → 07:00 ; « cardio » 22:03 → 00:59 qui la recouvre.
        let night = sleep(at(23, 0), at(31, 0))
        let lateCardio = workout(at(22, 3), at(24, 59), kind: "detected_cardio")
        let eveningRun = workout(at(19, 0), at(19, 40), kind: "running", sportType: 37, source: "Apple Watch")
        let r = DayTimelineBuilder.build(day: day, sleep: [night], workouts: [lateCardio, eveningRun], timeZone: utc)

        let cardio = try! XCTUnwrap(r.entries.first { $0.kind == .workout(.detectedCardio) })
        XCTAssertTrue(cardio.overlapsSleep)
        let run = try! XCTUnwrap(r.entries.first { $0.kind == .workout(.run) })
        XCTAssertFalse(run.overlapsSleep)
    }

    func testSportTypeGivesFrenchName() {
        XCTAssertEqual(WorkoutSport(kind: "Detected_Cardio").title, "Cardio détecté")
        XCTAssertEqual(WorkoutSport(kind: "Séance Apple Santé", sportType: 37).title, "Course à pied")
        XCTAssertEqual(WorkoutSport(kind: "Séance Apple Santé").title, "Activité")
        XCTAssertEqual(WorkoutSport(kind: "strength", sportType: 50).title, "Musculation")
    }
}

extension DayTimelineBuilderTests {
    /// Une détection du bracelet (cardio détecté) recouverte par une séance Santé du même créneau
    /// est absorbée : une seule entrée, du type et de la source Santé.
    func testBraceletDetectionAbsorbedByHealthWorkout() {
        let detection = workout(at(7, 5), at(7, 50), kind: "detected_cardio", avgHr: 131)
        let healthRun = workout(at(7, 0), at(7, 48), kind: "Séance Apple Santé", sportType: 37,
                                source: "Strava", avgHr: 149, peakHr: 172)
        let r = DayTimelineBuilder.build(day: day, sleep: [], workouts: [detection, healthRun], timeZone: utc)

        XCTAssertEqual(r.entries.count, 1)
        let e = try! XCTUnwrap(r.entries.first)
        XCTAssertEqual(e.kind, .workout(.run))
        XCTAssertEqual(e.source, .strava)
        XCTAssertEqual(e.mergedSources, [.bracelet])
        XCTAssertEqual(e.workoutID, healthRun.id)
        XCTAssertEqual(e.avgHr, 149)
        XCTAssertEqual(e.end, at(7, 50))
    }

    /// Une détection bracelet du même sport (course) recouverte par une course Apple Watch.
    func testBraceletRunAbsorbedBySameSportHealthRun() {
        let bandRun = workout(at(17, 2), at(17, 40), kind: "running")
        let watchRun = workout(at(17, 0), at(17, 45), kind: "running", sportType: 37, source: "Apple Watch")
        let r = DayTimelineBuilder.build(day: day, sleep: [], workouts: [bandRun, watchRun], timeZone: utc)
        XCTAssertEqual(r.entries.count, 1)
        XCTAssertEqual(r.entries.first?.source, .appleWatch)
    }

    func testSourcePriorityOrder() {
        XCTAssertEqual(DayTimelineSource.priority, [.appleWatch, .strava, .otherHealth, .bracelet])
        XCTAssertGreaterThan(DayTimelineSource.appleWatch.reliability, DayTimelineSource.strava.reliability)
        XCTAssertGreaterThan(DayTimelineSource.strava.reliability, DayTimelineSource.otherHealth(name: nil).reliability)
        XCTAssertGreaterThan(DayTimelineSource.otherHealth(name: "Nike Run Club").reliability, DayTimelineSource.bracelet.reliability)
    }
}
