import XCTest
@testable import LoopStrapEngine

/// Détection bracelet et fusion multisource des séances. Données synthétiques uniquement.
final class WorkoutDetectionTests: XCTestCase {
    private let t0 = 1_800_000_000.0

    /// FC à 1 Hz : `rest` partout, `effort` sur les plages données (secondes depuis `t0`).
    private func series(hours: Double, rest: Double = 60, effort: [(Double, Double, Double)])
        -> [(ts: Double, bpm: Double)] {
        stride(from: 0.0, to: hours * 3600, by: 1).map { s in
            let bpm = effort.first { s >= $0.0 && s < $0.1 }?.2 ?? rest
            return (ts: t0 + s, bpm: bpm)
        }
    }

    private func detect(_ hr: [(ts: Double, bpm: Double)], sleep: [WorkoutInterval] = [],
                        recorded: [WorkoutInterval] = []) -> [DetectedWorkout] {
        WorkoutDetector.detect(hrSeries: hr, thresholdSeries: hr,
                               startWindow: (from: t0, to: t0 + 86_400), sleep: sleep, recorded: recorded)
    }

    func testSustainedEffortIsDetected() {
        let hr = series(hours: 6, effort: [(3600, 3600 + 40 * 60, 150)])
        let found = detect(hr)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.start, t0 + 3600)
        XCTAssertEqual(found.first?.averageBPM ?? 0, 150, accuracy: 0.001)
    }

    func testDetectionInsideSleepWindowIsRejected() {
        // Soirée à FC élevée qui se prolonge jusqu'à l'endormissement.
        let hr = series(hours: 8, effort: [(3600, 3600 + 120 * 60, 130)])
        let sleep = WorkoutInterval(start: t0 + 3600 + 121 * 60, end: t0 + 8 * 3600)
        XCTAssertEqual(detect(hr).count, 1)
        XCTAssertTrue(detect(hr, sleep: [sleep]).isEmpty)
        // Effort pendant la nuit elle-même.
        let inside = WorkoutInterval(start: t0 + 3000, end: t0 + 8 * 3600)
        XCTAssertTrue(detect(hr, sleep: [inside]).isEmpty)
    }

    func testDetectionClearlySeparatedFromSleepIsKept() {
        let hr = series(hours: 8, effort: [(3600, 3600 + 40 * 60, 150)])
        // Coucher 1 h après la fin de la séance : au-delà de la garde.
        let sleep = WorkoutInterval(start: t0 + 3600 + 100 * 60, end: t0 + 8 * 3600)
        XCTAssertGreaterThan(sleep.start - (t0 + 3600 + 40 * 60), WorkoutDetectionPolicy.sleepGuardSeconds)
        XCTAssertEqual(detect(hr, sleep: [sleep]).count, 1)
    }

    func testShortFragmentIsNotCreated() {
        let hr = series(hours: 4, effort: [(3600, 3600 + 3 * 60, 150)])
        XCTAssertTrue(detect(hr).isEmpty)
    }

    func testIsolatedSpikesSpanningTenMinutesAreNotASession() {
        // Pics de 20 s toutes les 4 min sur 20 min : durée apparente > 10 min, effort quasi nul.
        let spikes = stride(from: 3600.0, to: 3600 + 20 * 60, by: 240).map { ($0, $0 + 20, 140.0) }
        let hr = series(hours: 4, effort: spikes)
        XCTAssertTrue(detect(hr).isEmpty)
    }

    func testRecordedWorkoutCutsBandDetection() {
        let hr = series(hours: 4, effort: [(3600, 3600 + 60 * 60, 150)])
        // Séance Santé sur toute la plage : la détection bracelet n'est pas recréée à côté.
        let recorded = WorkoutInterval(start: t0 + 3600 - 60, end: t0 + 3600 + 60 * 60 + 60)
        XCTAssertTrue(detect(hr, recorded: [recorded]).isEmpty)
        // Seul un débordement d'au moins la durée minimale peut rester une détection.
        let partial = WorkoutInterval(start: t0 + 3600, end: t0 + 3600 + 30 * 60)
        let rest = detect(hr, recorded: [partial])
        XCTAssertEqual(rest.count, 1)
        XCTAssertGreaterThanOrEqual(rest.first?.start ?? 0, partial.end)
    }

    // MARK: - Fusion

    private func run(_ id: String, _ source: WorkoutSource, _ origin: String?, _ sport: Int?,
                     _ start: Double, _ end: Double) -> WorkoutCandidate {
        WorkoutCandidate(id: id, source: source, origin: origin, sportType: sport, start: t0 + start, end: t0 + end)
    }

    func testPriorityIsWatchThenStravaThenOtherHealthThenBand() {
        XCTAssertEqual(WorkoutSourcePriority.order, [.appleWatch, .strava, .otherHealth, .band])
        XCTAssertEqual(WorkoutSourcePriority.classify(sourceName: "Apple Watch de Test", recorded: true), .appleWatch)
        XCTAssertEqual(WorkoutSourcePriority.classify(sourceName: "Strava", recorded: true), .strava)
        XCTAssertEqual(WorkoutSourcePriority.classify(sourceName: "Hevy", recorded: true), .otherHealth)
        XCTAssertEqual(WorkoutSourcePriority.classify(sourceName: nil, recorded: false), .band)
    }

    func testWatchAbsorbsOverlappingBandDetection() {
        let groups = WorkoutCanonicalization.canonicalize([
            run("watch", .appleWatch, "Apple Watch", 37, 0, 4500),
            // Détection partielle : moins de la moitié de la course, plus de la moitié d'elle-même.
            run("band", .band, nil, nil, 3000, 5000)
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary.id, "watch")
        XCTAssertEqual(groups.first?.members.map(\.id), ["watch", "band"])
    }

    func testDistinctBandEffortIsKept() {
        let groups = WorkoutCanonicalization.canonicalize([
            run("watch", .appleWatch, "Apple Watch", 37, 0, 4500),
            run("band", .band, nil, nil, 4500 + 13 * 60, 9000)
        ])
        XCTAssertEqual(groups.map(\.primary.id), ["watch", "band"])
    }

    func testBandContinuationOfRecordedWorkoutIsAbsorbed() {
        // Retour au calme encore au-dessus du seuil juste après la séance : même effort.
        let groups = WorkoutCanonicalization.canonicalize([
            run("watch", .appleWatch, "Apple Watch", 52, 0, 2700),
            run("band", .band, nil, nil, 2700, 4600)
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary.end, t0 + 2700)
    }

    func testGenericStravaCopyMergesWithNamedSession() {
        // Strava écrit « Autre » (3000) pour une séance de musculation enregistrée par Hevy.
        let groups = WorkoutCanonicalization.canonicalize([
            run("strava", .strava, "Strava", 3000, 0, 2921),
            run("hevy", .otherHealth, "Hevy", 50, 0, 3874)
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.primary.id, "strava")
        XCTAssertEqual(groups.first?.sportType, 50)
    }

    func testRunAndWalkStayDistinctAndFalseStartIsAbsorbed() {
        let groups = WorkoutCanonicalization.canonicalize([
            run("watch-false-start", .appleWatch, "Apple Watch", 37, 0, 156),
            run("strava-false-start", .strava, "Strava", 37, 0, 156),
            run("watch-run", .appleWatch, "Apple Watch", 37, 560, 5114),
            run("strava-walk", .strava, "Strava", 52, 5123, 7823),
            run("watch-walk", .appleWatch, "Apple Watch", 52, 5133, 7823)
        ])
        XCTAssertEqual(groups.map(\.primary.id), ["watch-run", "watch-walk"])
        XCTAssertEqual(groups.first?.primary.start, t0 + 560)
        XCTAssertEqual(Set(groups.first?.members.map(\.id) ?? []),
                       ["watch-run", "watch-false-start", "strava-false-start"])
    }

    func testIsolatedShortRecordedWorkoutIsKept() {
        let groups = WorkoutCanonicalization.canonicalize([
            run("short", .appleWatch, "Apple Watch", 37, 0, 300),
            run("later", .appleWatch, "Apple Watch", 37, 7200, 9000)
        ])
        XCTAssertEqual(groups.count, 2)
    }

    func testSameProducerSessionsStayDistinct() {
        let groups = WorkoutCanonicalization.canonicalize([
            run("a", .appleWatch, "Apple Watch", 37, 0, 3600),
            run("b", .appleWatch, "Apple Watch", 37, 10, 3600)
        ])
        XCTAssertEqual(groups.count, 2)
    }

    // MARK: - Charge

    func testDailyLoadDoesNotCountDuplicatedPeriodTwice() throws {
        // Même effort vu par le bracelet et par une séance Santé : la FC est fusionnée par
        // seconde avant le calcul. Mêmes valeurs → même charge que le bracelet seul ; valeurs
        // Santé différentes → elles remplacent le bracelet, sans ajouter de minutes.
        let band = series(hours: 3, effort: [(3600, 3600 + 45 * 60, 150)])
        let window = band.filter { $0.ts >= t0 + 3600 && $0.ts < t0 + 3600 + 45 * 60 }
        let range = [(start: t0 + 3600, end: t0 + 3600 + 45 * 60)]
        let alone = try strain(hrSeries: band, restingHR: 60, hrmaxEstimate: 190, sex: .male)
        let same = mergePrioritizedHR(band: band, supplemental: [], preferred: window, preferredRanges: range)
        XCTAssertEqual(same.count, band.count)
        let fusedSame = try strain(hrSeries: same, restingHR: 60, hrmaxEstimate: 190, sex: .male)
        XCTAssertEqual(fusedSame.strain, alone.strain, accuracy: 1e-9)
        let higher = window.map { (ts: $0.ts, bpm: $0.bpm + 10) }
        let replaced = mergePrioritizedHR(band: band, supplemental: [], preferred: higher, preferredRanges: range)
        XCTAssertEqual(replaced.count, band.count)
        let fusedHigher = try strain(hrSeries: replaced, restingHR: 60, hrmaxEstimate: 190, sex: .male)
        XCTAssertEqual(fusedHigher.observedMinutes, alone.observedMinutes, accuracy: 0.01)
    }

    func testPerSessionLoadIsCountedOncePerCanonicalSession() {
        // Strava + Hevy + bracelet pour le même effort : une seule séance canonique à charger.
        let groups = WorkoutCanonicalization.canonicalize([
            run("strava", .strava, "Strava", 3000, 0, 3075),
            run("hevy", .otherHealth, "Hevy", 50, 1, 3077),
            run("band", .band, nil, nil, 200, 2800)
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.members.count, 3)
    }
}
