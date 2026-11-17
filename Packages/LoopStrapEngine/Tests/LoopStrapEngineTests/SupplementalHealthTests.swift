import XCTest
@testable import LoopStrapEngine

/// Entrées Apple Santé du calcul journalier : additives, optionnelles, sans double comptage.
final class SupplementalHealthTests: XCTestCase {
    private let baseline = BaselineState(baseline: 60, spread: 10, nValid: 30,
                                         nightsSinceUpdate: 0, status: .trusted)

    private func summary(rhr: Double?, hrv: Double? = 60) -> DailySleepSummary {
        DailySleepSummary(date: "2026-01-02", totalSleepMin: 420, efficiency: 0.9,
                          deepMin: 90, remMin: 90, lightMin: 240, disturbances: 1,
                          restingHR: rhr, avgRmssd: hrv, sleepStart: 1_000, sleepEnd: 26_200)
    }

    /// Journée bracelet réaliste : repos 1 Hz, une séance de 30 min, un trou de 1 h (bracelet retiré).
    private func bandDay() -> [(ts: Double, bpm: Double)] {
        var out: [(ts: Double, bpm: Double)] = []
        for t in stride(from: 30_000.0, to: 40_000.0, by: 1) {
            let inWorkout = t >= 32_000 && t < 33_800
            out.append((ts: t, bpm: inWorkout ? 155 + (t.truncatingRemainder(dividingBy: 7)) : 70))
        }
        for t in stride(from: 43_600.0, to: 50_000.0, by: 1) { out.append((ts: t, bpm: 72)) }
        return out
    }

    private func history() -> [DailyInputs] {
        (0..<10).map { i in
            DailyInputs(date: "2025-12-\(20 + i)",
                        sleepSummary: DailySleepSummary(date: "2025-12-\(20 + i)", totalSleepMin: 400 + Double(i),
                                                        efficiency: 0.88, deepMin: 80, remMin: 85, lightMin: 235,
                                                        disturbances: 2, restingHR: 52 + Double(i % 3),
                                                        avgRmssd: 58 + Double(i % 4), sleepStart: nil, sleepEnd: nil),
                        hrSeries: [])
        }
    }

    private func assertIdentical(_ a: DailyResult, _ b: DailyResult, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.date, b.date, file: file, line: line)
        XCTAssertEqual(a.totalSleepMin, b.totalSleepMin, file: file, line: line)
        XCTAssertEqual(a.efficiency, b.efficiency, file: file, line: line)
        XCTAssertEqual(a.deepMin, b.deepMin, file: file, line: line)
        XCTAssertEqual(a.remMin, b.remMin, file: file, line: line)
        XCTAssertEqual(a.lightMin, b.lightMin, file: file, line: line)
        XCTAssertEqual(a.disturbances, b.disturbances, file: file, line: line)
        XCTAssertEqual(a.sleepStart, b.sleepStart, file: file, line: line)
        XCTAssertEqual(a.sleepEnd, b.sleepEnd, file: file, line: line)
        XCTAssertEqual(a.restingHR, b.restingHR, file: file, line: line)
        XCTAssertEqual(a.avgHrv, b.avgHrv, file: file, line: line)
        XCTAssertEqual(a.recovery, b.recovery, file: file, line: line)
        XCTAssertEqual(a.recoveryStatus, b.recoveryStatus, file: file, line: line)
        XCTAssertEqual(a.recoveryBand, b.recoveryBand, file: file, line: line)
        XCTAssertEqual(a.sleepScore, b.sleepScore, file: file, line: line)
        XCTAssertEqual(a.strain, b.strain, file: file, line: line)
    }

    // MARK: - Sans santé = identique

    /// Même entrée bracelet, avec les champs santé vides/nil explicites ou omis : sortie identique,
    /// avec ou sans exclusions, avec ou sans FC repos de nuit.
    func testNoHealthDataLeavesResultStrictlyIdentical() {
        let exclusions: [[(start: Double, end: Double)]] = [[], [(start: 32_500, end: 33_000)]]
        for rhr in [55.0, nil] {
            for excl in exclusions {
                let legacy = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: rhr), hrSeries: bandDay(),
                                         hrmaxOverride: 190, strainDifficulty: 0.8, strainExcludeRanges: excl)
                let explicitEmpty = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: rhr), hrSeries: bandDay(),
                                                hrmaxOverride: 190, strainDifficulty: 0.8, strainExcludeRanges: excl,
                                                supplementalHRSeries: [], supplementalRestingHR: nil)
                let a = DailyEngine.compute(day: legacy, history: history(), baseline: baseline)
                let b = DailyEngine.compute(day: explicitEmpty, history: history(), baseline: baseline)
                assertIdentical(a, b)
            }
        }
        // Garde-fou : la journée de référence produit bien un strain (sinon l'égalité serait vide).
        let ref = DailyEngine.compute(day: DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55),
                                                       hrSeries: bandDay(), hrmaxOverride: 190),
                                      history: history(), baseline: baseline)
        XCTAssertNotNil(ref.strain)
        XCTAssertNotNil(ref.recovery)
    }

    func testMergeWithoutSupplementalReturnsBandUnchanged() {
        let band = bandDay()
        let merged = mergeSupplementalHR(band: band, supplemental: [])
        XCTAssertEqual(merged.count, band.count)
        XCTAssertTrue(zip(merged, band).allSatisfy { $0.ts == $1.ts && $0.bpm == $1.bpm })
    }

    // MARK: - Pas de double comptage

    /// La Watch enregistre la même séance que le bracelet (mêmes secondes) : strain inchangé.
    func testOverlappingWatchWorkoutDoesNotChangeStrain() {
        let watch = stride(from: 32_000.0, to: 33_800, by: 5).map { (ts: $0, bpm: 170.0) }
        let bandOnly = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                   hrmaxOverride: 190)
        let withWatch = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                    hrmaxOverride: 190, supplementalHRSeries: watch)
        let a = DailyEngine.compute(day: bandOnly, history: history(), baseline: baseline)
        let b = DailyEngine.compute(day: withWatch, history: history(), baseline: baseline)
        assertIdentical(a, b)
    }

    /// La Watch couvre le trou du bracelet (40 000 → 43 600) avec une séance : le strain monte, la
    /// récupération et le sommeil ne bougent pas.
    func testWatchFillsBandGapAndRaisesStrainOnly() throws {
        let watch = stride(from: 40_200.0, to: 42_000, by: 5).map { (ts: $0, bpm: 160.0) }
        let bandOnly = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                   hrmaxOverride: 190)
        let withWatch = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                    hrmaxOverride: 190, supplementalHRSeries: watch)
        let a = DailyEngine.compute(day: bandOnly, history: history(), baseline: baseline)
        let b = DailyEngine.compute(day: withWatch, history: history(), baseline: baseline)
        XCTAssertGreaterThan(try XCTUnwrap(b.strain), try XCTUnwrap(a.strain))
        XCTAssertEqual(a.recovery, b.recovery)
        XCTAssertEqual(a.sleepScore, b.sleepScore)
        XCTAssertEqual(a.restingHR, b.restingHR)
    }

    /// Les secondes comblées sont tenues ≤ `maxHoldSeconds` et jamais posées sur une seconde bracelet.
    func testMergeFillsOnlyUncoveredSecondsWithBoundedHold() {
        let band = (0..<100).map { (ts: Double($0), bpm: 60.0) }
        let ext = [(ts: 50.0, bpm: 120.0), (ts: 200.0, bpm: 130.0), (ts: 500.0, bpm: 140.0)]
        let merged = mergeSupplementalHR(band: band, supplemental: ext)
        let added = merged.filter { $0.bpm > 100 }
        // 50 est couvert par le bracelet ; 200 et 500 tenus chacun maxHoldSeconds (10 s).
        XCTAssertEqual(added.count, 2 * Int(SupplementalHR.maxHoldSeconds))
        XCTAssertFalse(added.contains { $0.ts < 103 })
        XCTAssertEqual(merged.map(\.ts), merged.map(\.ts).sorted())
    }

    func testDuplicateAndSubsecondHealthSamplesDoNotCreateDuplicateSeconds() {
        let merged = mergeSupplementalHR(band: [], supplemental: [
            (ts: 100.2, bpm: 120), (ts: 100.2, bpm: 120),
            (ts: 100.8, bpm: 125), (ts: 105.4, bpm: 130)
        ])
        XCTAssertEqual(merged.count, 15)
        XCTAssertEqual(Set(merged.map(\.ts)).count, merged.count)
        XCTAssertEqual(merged.first?.ts, 100)
        XCTAssertEqual(merged.first?.bpm, 125)
        XCTAssertEqual(merged.last?.ts, 114)
    }

    /// Un rejet utilisateur exclut aussi la FC externe de la fenêtre.
    func testExclusionAppliesToSupplementalHR() {
        let watch = stride(from: 40_200.0, to: 42_000, by: 5).map { (ts: $0, bpm: 160.0) }
        let bandOnly = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                   hrmaxOverride: 190)
        let rejected = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                   hrmaxOverride: 190, strainExcludeRanges: [(start: 40_000, end: 43_000)],
                                   supplementalHRSeries: watch)
        let a = DailyEngine.compute(day: bandOnly, history: history(), baseline: baseline)
        let b = DailyEngine.compute(day: rejected, history: history(), baseline: baseline)
        XCTAssertEqual(a.strain, b.strain)
    }

    // MARK: - FC repos externe

    func testSupplementalRestingHROnlyUsedWhenBandNightMissing() throws {
        // Nuit bracelet sans FC repos : strain nil sans santé, calculé avec la FC repos Watch.
        let noRHR = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: nil), hrSeries: bandDay(),
                                hrmaxOverride: 190)
        let withExt = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: nil), hrSeries: bandDay(),
                                  hrmaxOverride: 190, supplementalRestingHR: 58)
        let a = DailyEngine.compute(day: noRHR, history: history(), baseline: baseline)
        let b = DailyEngine.compute(day: withExt, history: history(), baseline: baseline)
        XCTAssertNil(a.strain)
        XCTAssertNotNil(b.strain)
        XCTAssertNil(b.recovery, "la FC repos externe ne doit jamais alimenter la récupération")
        XCTAssertNil(b.restingHR)

        // Nuit bracelet avec FC repos : la valeur externe est ignorée.
        let band = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                               hrmaxOverride: 190)
        let bandPlusExt = DailyInputs(date: "2026-01-02", sleepSummary: summary(rhr: 55), hrSeries: bandDay(),
                                      hrmaxOverride: 190, supplementalRestingHR: 65)
        assertIdentical(DailyEngine.compute(day: band, history: history(), baseline: baseline),
                        DailyEngine.compute(day: bandPlusExt, history: history(), baseline: baseline))
    }
}
