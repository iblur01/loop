import XCTest
import LoopStrapEngine
import WhoopStore
@testable import Loop

/// Séance importée d'un export CSV Hevy : classement de source et fusion avec une séance montre
/// par la règle existante (`WorkoutCanonicalization`, 50 % / 70 %), sans règle nouvelle.
final class HevyImportTests: XCTestCase {
    private let start: Double = 1_794_654_000

    private func hevy(start: Double, minutes: Double) -> ExternalWorkout {
        let session = HevySession(title: "Push 💪", start: Date(timeIntervalSince1970: start),
                                  end: Date(timeIntervalSince1970: start + minutes * 60),
                                  workingSetCount: 3, warmupSetCount: 1, volumeKg: 1200, warmupVolumeKg: 200)
        return HevyImport.workout(from: session, importedAt: Date(timeIntervalSince1970: start))
    }

    private func watch(sport: Int, start: Double, end: Double) -> ExternalWorkout {
        ExternalWorkout(id: "W1", source: "healthkit", sportType: sport, startDate: start, endDate: end,
                        durationSec: end - start, energyKcal: 320, distanceM: nil,
                        sourceName: "Apple Watch de Théo", importedAt: 0,
                        sourceBundle: "com.apple.health.ABC", productType: "Watch6,1", deviceModel: "Watch")
    }

    func testHevyWorkoutIsNeitherAppleWatchNorBand() {
        let w = hevy(start: start, minutes: 60)
        XCTAssertEqual(HealthDataSource.classify(w), .healthKit)
        XCTAssertEqual(WorkoutSourcePriority.classify(w), .otherHealth)
        XCTAssertFalse(ManualWorkout.isManual(w), "pas une saisie manuelle")
        XCTAssertTrue(HevyImport.isHevy(w))
    }

    func testOverlappingWatchStrengthSessionMergesWithoutDoubleCount() {
        // Hevy 12:00–13:00, montre 12:05–13:00 : 55 min communes ≥ 70 % de la plus longue.
        let h = hevy(start: start, minutes: 60)
        let w = watch(sport: 50, start: start + 300, end: start + 3600)
        let merged = HealthWorkoutCanonicalizer.merge(band: [], external: [h, w])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.externalID, "W1", "la montre reste primaire")
        XCTAssertEqual(merged.first?.sportType, 50)
    }

    /// L'app Hevy écrit aussi la séance dans Apple Santé (nom « Hevy ») : avec l'export CSV de la
    /// même séance, une seule activité, la plus longue retenue (les deux sont « autre source »).
    func testHealthHevyAndCSVHevyOfSameSessionMergeOnce() {
        let csv = hevy(start: start, minutes: 60)
        let health = ExternalWorkout(id: "HK-HEVY", source: "healthkit", sportType: 50, startDate: start + 60,
                                     endDate: start + 3600, durationSec: 3540, energyKcal: 250, distanceM: nil,
                                     sourceName: "Hevy", importedAt: 0, sourceBundle: "com.hevy.app")
        XCTAssertEqual(WorkoutSourcePriority.classify(health), .otherHealth)
        let merged = HealthWorkoutCanonicalizer.merge(band: [], external: [csv, health])
        XCTAssertEqual(merged.count, 1, "pas de double charge")
        XCTAssertEqual(merged.first?.externalID, csv.id, "la plus longue est retenue")
        XCTAssertEqual(merged.first?.caloriesKcal, 250)
        let activities = HealthReconciliation.mergeActivities([HealthSourceActivity(csv), HealthSourceActivity(health)])
        XCTAssertEqual(activities.count, 1, "le rapport Santé compte aussi une seule activité")
    }

    func testTwoCSVHevySessionsStayDistinct() {
        let a = hevy(start: start, minutes: 60)
        let b = hevy(start: start + 120, minutes: 60)
        XCTAssertEqual(HealthWorkoutCanonicalizer.merge(band: [], external: [a, b]).count, 2,
                       "deux séances du même export restent deux séances voulues")
    }

    func testDifferentSportIsNotMerged() {
        let h = hevy(start: start, minutes: 60)
        let w = watch(sport: 37, start: start + 300, end: start + 3600)
        XCTAssertEqual(HealthWorkoutCanonicalizer.merge(band: [], external: [h, w]).count, 2)
    }
}
