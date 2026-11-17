import XCTest
import WhoopStore
import enum LoopStrapEngine.WorkoutSourcePriority
@testable import Loop

final class HealthReconciliationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func activity(_ id: String, _ source: HealthDataSource, from: Double, to: Double,
                          kcal: Double? = nil, distance: Double? = nil) -> HealthSourceActivity {
        HealthSourceActivity(id: id, source: source, sportType: 37, start: at(from), end: at(to),
                             durationSec: (to - from) * 60, energyKcal: kcal, distanceM: distance)
    }

    private func hr(_ source: HealthDataSource, _ values: [(minute: Double, bpm: Double)]) -> HealthSourceSeries {
        HealthSourceSeries(source: source, points: values.map { HealthMeasurePoint(at: at($0.minute), value: $0.bpm) })
    }

    // MARK: - Séances

    func testOverlappingWorkoutsMergeIntoOneActivity() {
        // Watch 10:00–10:40, bracelet 10:05–10:45 : recouvrement 35 min ≥ 50 % de 40 min.
        let merged = HealthReconciliation.mergeActivities([
            activity("whoop-1", .whoop, from: 5, to: 45, kcal: 380),
            activity("watch-1", .appleWatch, from: 0, to: 40, kcal: nil, distance: 7_200)
        ])
        XCTAssertEqual(merged.count, 1)
        let a = merged[0]
        XCTAssertEqual(a.primary.id, "watch-1", "Watch prioritaire pour les séances par défaut")
        XCTAssertEqual(a.durationSec, 40 * 60)
        XCTAssertEqual(a.energyKcal, 380)
        XCTAssertEqual(a.energySource, .whoop, "kcal : première source qui les fournit")
        XCTAssertEqual(a.distanceM, 7_200)
        XCTAssertEqual(a.distanceSource, .appleWatch)
        XCTAssertEqual(a.sources, [.appleWatch, .whoop])
        XCTAssertEqual(a.members.count, 2, "toutes les lignes sources sont conservées")
    }

    func testDisjointWorkoutsStaySeparate() {
        let merged = HealthReconciliation.mergeActivities([
            activity("watch-1", .appleWatch, from: 0, to: 30),
            activity("whoop-1", .whoop, from: 60, to: 90)
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.primary.id), ["watch-1", "whoop-1"])
    }

    func testSmallOverlapBelowThresholdStaysSeparate() {
        // Recouvrement 10 min < 50 % de 30 min.
        let merged = HealthReconciliation.mergeActivities([
            activity("a", .appleWatch, from: 0, to: 30),
            activity("b", .whoop, from: 20, to: 50)
        ])
        XCTAssertEqual(merged.count, 2)
    }

    func testWorkoutPriorityIsConfigurable() {
        var priority = HealthSourcePriority.default
        priority.workouts = [.whoop, .appleWatch]
        let merged = HealthReconciliation.mergeActivities([
            activity("watch-1", .appleWatch, from: 0, to: 40),
            activity("whoop-1", .whoop, from: 5, to: 45)
        ], priority: priority)
        XCTAssertEqual(merged.first?.primary.id, "whoop-1")
        XCTAssertEqual(merged.first?.durationSec, 40 * 60)
    }

    func testInvalidWorkoutIsIgnored() {
        let merged = HealthReconciliation.mergeActivities([
            activity("bad", .appleWatch, from: 30, to: 10),
            activity("ok", .whoop, from: 0, to: 20)
        ])
        XCTAssertEqual(merged.map(\.primary.id), ["ok"])
    }

    // MARK: - Séries FC

    func testHeartRatePriorityFollowsContext() {
        // Minutes 0–1 : sommeil (bracelet prioritaire) ; 1–2 : activité (Watch prioritaire).
        let timeline = HealthContextTimeline(sleep: [DateInterval(start: at(0), end: at(1))],
                                             activity: [DateInterval(start: at(1), end: at(2))])
        let merged = HealthReconciliation.mergeSeries(
            kind: .heartRate,
            series: [hr(.whoop, [(0.5, 52), (1.5, 140)]), hr(.appleWatch, [(0.5, 55), (1.5, 146)])],
            from: at(0), to: at(2), bucket: 60, timeline: timeline)
        XCTAssertEqual(merged.buckets.count, 2)
        XCTAssertEqual(merged.buckets[0].context, .sleep)
        XCTAssertEqual(merged.buckets[0].source, .whoop)
        XCTAssertEqual(merged.buckets[0].value, 52)
        XCTAssertEqual(merged.buckets[1].context, .activity)
        XCTAssertEqual(merged.buckets[1].source, .appleWatch)
        XCTAssertEqual(merged.buckets[1].value, 146)
        XCTAssertEqual(merged.buckets[0].candidates[.appleWatch], 55, "la source non retenue reste visible")
    }

    func testMissingSourceFallsBackAndSeriesNamesTheSource() {
        // Watch sans batterie à partir de la minute 1, bracelet absent à la minute 2, rien à la minute 3.
        let merged = HealthReconciliation.mergeSeries(
            kind: .heartRate,
            series: [hr(.whoop, [(0.5, 60), (1.5, 62)]), hr(.appleWatch, [(0.5, 61), (2.5, 70)])],
            from: at(0), to: at(4), bucket: 60)
        XCTAssertEqual(merged.buckets.map(\.source), [.whoop, .whoop, .appleWatch, nil])
        XCTAssertEqual(merged.buckets.map(\.value), [60, 62, 70, nil])
        XCTAssertEqual(merged.bucketsBySource[.whoop], 2)
        XCTAssertEqual(merged.bucketsBySource[.appleWatch], 1)
    }

    func testInvalidValuesAreIgnored() {
        let bad = HealthSourceSeries(source: .whoop, points: [
            HealthMeasurePoint(at: at(0.2), value: .nan),
            HealthMeasurePoint(at: at(0.4), value: .infinity),
            HealthMeasurePoint(at: at(0.6), value: 400),
            HealthMeasurePoint(start: at(0.9), end: at(0.1), value: 60)
        ])
        let merged = HealthReconciliation.mergeSeries(
            kind: .heartRate, series: [bad, hr(.appleWatch, [(0.5, 58)])],
            from: at(0), to: at(1), bucket: 60)
        XCTAssertEqual(merged.ignoredPointCount, 4)
        XCTAssertEqual(merged.buckets.first?.source, .appleWatch)
        XCTAssertEqual(merged.buckets.first?.value, 58)
        XCTAssertNil(merged.buckets.first?.candidates[.whoop])
        XCTAssertTrue(merged.agreements.isEmpty)
    }

    func testAgreementOnKnownDifferences() {
        // Écarts absolus : 2, 4, 6, 10 → médiane 5, 4 paires. Minute 4 : Watch seule, non comparée.
        let merged = HealthReconciliation.mergeSeries(
            kind: .heartRate,
            series: [hr(.whoop, [(0.5, 60), (1.5, 70), (2.5, 80), (3.5, 90)]),
                     hr(.appleWatch, [(0.5, 62), (1.5, 66), (2.5, 86), (3.5, 100), (4.5, 75)])],
            from: at(0), to: at(5), bucket: 60)
        let agreement = merged.agreement(.whoop, .appleWatch)
        XCTAssertEqual(agreement?.pairCount, 4)
        XCTAssertEqual(agreement?.medianAbsoluteDifference, 5)
        XCTAssertEqual(merged.agreements.count, 1)
    }

    func testCumulativeKindIsProratedAcrossBuckets() {
        // 100 pas sur 2 minutes → 50 par minute.
        let steps = HealthSourceSeries(source: .appleWatch, points: [
            HealthMeasurePoint(start: at(0), end: at(2), value: 100)
        ])
        let merged = HealthReconciliation.mergeSeries(kind: .stepCount, series: [steps],
                                                      from: at(0), to: at(2), bucket: 60)
        XCTAssertEqual(merged.buckets.map(\.value), [50, 50])
    }

    func testGroupingRetainsProducerWithoutChangingExistingCumulativeMerge() {
        func sample(_ id: String, bundle: String?, name: String?, value: Double?) -> HealthSample {
            HealthSample(uuid: id, type: HealthSampleKind.stepCount.rawValue,
                         startDate: at(0).timeIntervalSince1970, endDate: at(1).timeIntervalSince1970,
                         value: value, unit: "count", sourceName: name, sourceBundle: bundle,
                         metadataOrigin: nil, importedAt: 0)
        }
        let samples = [
            sample("a", bundle: "com.example.a", name: "Phone", value: 100),
            sample("b", bundle: "com.example.b", name: "Other App", value: 100),
            sample("c", bundle: "COM.EXAMPLE.A", name: "Phone renamed", value: 0),
            sample("d", bundle: nil, name: "Third App", value: 10),
            sample("e", bundle: nil, name: nil, value: nil)
        ]
        let grouped = HealthSourceSeries.groupedByProducer(samples)
        XCTAssertEqual(Set(grouped.compactMap(\.producerID)),
                       Set(["bundle:com.example.a", "bundle:com.example.b", "name:third app"]))
        XCTAssertEqual(grouped.first(where: { $0.producerID == "bundle:com.example.a" })?.points.count, 2)
        XCTAssertTrue(grouped.allSatisfy { $0.source == .healthKit })

        // L'identité est conservée, mais l'agrégation par catégorie demeure inchangée :
        // ce total peut compter deux fois des données concurrentes et n'est pas une résolution.
        let merged = HealthReconciliation.mergeSeries(kind: .stepCount, series: grouped,
                                                      from: at(0), to: at(1), bucket: 60)
        XCTAssertEqual(merged.buckets.first?.value, 210)

        // L'API historique conserve une seule série par catégorie, avec l'ordre des points,
        // car le moteur FC écarte les points proches de séries différentes.
        let legacy = HealthSourceSeries.grouped(samples)
        XCTAssertEqual(legacy.count, 1)
        XCTAssertNil(legacy[0].producerID)
        XCTAssertEqual(legacy[0].points.map(\.value), [100, 100, 0, 10])
    }

    func testGroupingKeepsMissingProducerExplicitAndZeroValid() {
        let sample = HealthSample(uuid: "unknown", type: HealthSampleKind.stepCount.rawValue,
                                  startDate: at(0).timeIntervalSince1970,
                                  endDate: at(1).timeIntervalSince1970, value: 0,
                                  unit: "count", sourceName: nil, sourceBundle: nil,
                                  metadataOrigin: nil, importedAt: 0)
        let grouped = HealthSourceSeries.groupedByProducer([sample])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertNil(grouped[0].producerID)
        let merged = HealthReconciliation.mergeSeries(kind: .stepCount, series: grouped,
                                                      from: at(0), to: at(1), bucket: 60)
        XCTAssertEqual(merged.buckets.first?.value, 0)
    }

    func testSupplementalHeartRateKeepsNearbySamplesFromSameCategory() {
        func sample(_ id: String, bundle: String, seconds: Double, bpm: Double) -> HealthSample {
            let timestamp = t0.addingTimeInterval(seconds).timeIntervalSince1970
            return HealthSample(uuid: id, type: HealthSampleKind.heartRate.rawValue,
                                startDate: timestamp, endDate: timestamp, value: bpm,
                                unit: "count/min", sourceName: "Third party", sourceBundle: bundle,
                                metadataOrigin: nil, importedAt: 0)
        }
        let rows = [sample("a", bundle: "z.app", seconds: 0, bpm: 90),
                    sample("b", bundle: "a.app", seconds: 1, bpm: 91)]
        let values = HealthEngineInputs.supplementalHR(rows, priority: .default)
        XCTAssertEqual(values.map(\.bpm), [90, 91])
    }

    // MARK: - Classement des sources

    func testSourceClassification() {
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Apple Watch de Théo"), .appleWatch)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "iPhone"), .healthKit)
        XCTAssertEqual(HealthDataSource.classify(sourceName: nil), .healthKit)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Loop", metadataOrigin: "loop"), .whoop)
    }

    func testSourceClassificationPrefersStableDeviceIdentity() {
        let apple = "com.apple.health.ABC"
        XCTAssertEqual(HealthDataSource.classify(sourceName: "iPhone de Théo", metadataOrigin: nil, sourceBundle: apple,
                                                 productType: "Watch6,1", deviceModel: nil), .appleWatch)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Ma watch perso", metadataOrigin: nil, sourceBundle: apple,
                                                 productType: "iPhone15,2", deviceModel: nil), .healthKit)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Watch renommée", metadataOrigin: nil, sourceBundle: apple,
                                                 productType: "iPad13,4", deviceModel: "Watch"), .healthKit)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Montre", metadataOrigin: nil, sourceBundle: apple,
                                                 productType: nil, deviceModel: "Watch"), .appleWatch)
        // Égalité stricte sur le modèle : un appareil tiers « ScanWatch » ne devient pas Apple Watch.
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Balance", metadataOrigin: nil, sourceBundle: apple,
                                                 productType: nil, deviceModel: "ScanWatch"), .healthKit)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Loop", metadataOrigin: "loop", sourceBundle: apple,
                                                 productType: "Watch6,1", deviceModel: "Watch"), .whoop)
        // Sans identité matérielle : repli inchangé sur le nom.
        XCTAssertEqual(HealthDataSource.classify(sourceName: "Apple Watch de Théo", metadataOrigin: nil, sourceBundle: nil,
                                                 productType: nil, deviceModel: nil), .appleWatch)
        XCTAssertEqual(HealthDataSource.classify(sourceName: "iPhone", metadataOrigin: nil, sourceBundle: nil,
                                                 productType: nil, deviceModel: nil), .healthKit)
    }

    /// App de sommeil tierce qui tourne sur la montre : productType Watch mais bundle non Apple.
    /// Elle n'est pas fusionnée avec les données natives de la montre (repli sur le nom).
    func testThirdPartyWatchAppIsNotGroupedWithNativeAppleWatch() {
        XCTAssertEqual(HealthDataSource.classify(sourceName: "SleepApp", metadataOrigin: nil,
                                                 sourceBundle: "com.example.sleepapp.watchkitapp",
                                                 productType: "Watch6,1", deviceModel: "Watch"), .healthKit)
        let native = HealthSample(uuid: "n", type: "sleepAnalysis", startDate: 0, endDate: 60, value: 3,
                                  unit: "category", sourceName: "Montre de Théo", sourceBundle: "com.apple.health.ABC",
                                  metadataOrigin: nil, importedAt: 0, productType: "Watch6,1", deviceModel: "Watch")
        let thirdParty = HealthSample(uuid: "t", type: "sleepAnalysis", startDate: 0, endDate: 60, value: 4,
                                      unit: "category", sourceName: "SleepApp", sourceBundle: "com.example.sleepapp.watchkitapp",
                                      metadataOrigin: nil, importedAt: 0, productType: "Watch6,1", deviceModel: "Watch")
        let series = HealthSourceSeries.grouped([native, thirdParty])
        XCTAssertEqual(series.first(where: { $0.source == .appleWatch })?.points.map(\.value), [3])
        XCTAssertEqual(series.first(where: { $0.source == .healthKit })?.points.map(\.value), [4])
    }

    func testGroupedSeriesUsesStoredProductType() {
        let renamedWatch = HealthSample(uuid: "w", type: "heartRate", startDate: 0, endDate: 60, value: 60,
                                        unit: "count/min", sourceName: "iPhone de Théo", sourceBundle: "com.apple.health.ABC",
                                        metadataOrigin: nil, importedAt: 0, productType: "Watch6,1", deviceModel: "Watch")
        let phoneNamedWatch = HealthSample(uuid: "p", type: "heartRate", startDate: 0, endDate: 60, value: 70,
                                           unit: "count/min", sourceName: "Watch app", sourceBundle: "com.apple.health.DEF",
                                           metadataOrigin: nil, importedAt: 0, productType: "iPhone15,2", deviceModel: "iPhone")
        let series = HealthSourceSeries.grouped([renamedWatch, phoneNamedWatch])
        XCTAssertEqual(series.first(where: { $0.source == .appleWatch })?.points.map(\.value), [60])
        XCTAssertEqual(series.first(where: { $0.source == .healthKit })?.points.map(\.value), [70])
    }

    /// Montre renommée « Montre de Théo » (Watch6,1, bundle Apple) : Apple Watch dans l'adaptateur
    /// sommeil, dans la session retenue et dans `retainedSleepSource`, sans reclasser par le nom.
    func testRenamedWatchSleepIsAppleWatchEverywhere() throws {
        let start = 1_700_000_000.0
        let night = HealthSample(uuid: "night", type: "sleepAnalysis", startDate: start, endDate: start + 7 * 3600,
                                 value: 3, unit: "category", sourceName: "Montre de Théo",
                                 sourceBundle: "com.apple.health.ABC", metadataOrigin: nil, importedAt: 0,
                                 productType: "Watch6,1", deviceModel: "Watch")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = formatter.string(from: Date(timeIntervalSince1970: start + 7 * 3600))
        let result = try XCTUnwrap(HealthSleepAdapter.summaries(samples: [night], date: date))
        XCTAssertEqual(result.source, .appleWatch)
        XCTAssertEqual(result.session.healthSource, .appleWatch)
        XCTAssertEqual(HealthDataSource.classify(sourceName: result.session.sourceName), .healthKit,
                       "le nom seul ne suffit pas : la source doit venir de l'identité stockée")
        let snapshot = sleepSnapshot(start: start, end: start + 7 * 3600, minutes: 420)
        XCTAssertEqual(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: [result.session]),
                       .appleWatch)
    }

    /// Le rapport (`HealthSourceActivity`) et la projection canonique (`WorkoutSourcePriority`)
    /// classent une séance avec la même identité stable.
    func testWorkoutClassificationSharedByReportAndCanonicalizer() {
        func workout(_ name: String, bundle: String?, product: String?) -> ExternalWorkout {
            ExternalWorkout(id: name, source: "healthkit", sportType: 37, startDate: 0, endDate: 600,
                            durationSec: 600, energyKcal: nil, distanceM: nil, sourceName: name,
                            importedAt: 0, sourceBundle: bundle, productType: product, deviceModel: nil)
        }
        let renamedWatch = workout("Montre de Théo", bundle: "com.apple.health.ABC", product: "Watch6,1")
        XCTAssertEqual(HealthSourceActivity(renamedWatch).source, .appleWatch)
        XCTAssertEqual(WorkoutSourcePriority.classify(renamedWatch), .appleWatch)
        let phoneNamedWatch = workout("Watch Runner", bundle: "com.example.runner", product: "iPhone15,2")
        XCTAssertEqual(HealthSourceActivity(phoneNamedWatch).source, .healthKit)
        XCTAssertEqual(WorkoutSourcePriority.classify(phoneNamedWatch), .otherHealth)
        let strava = workout("Strava", bundle: "com.strava.stravaride", product: "iPhone15,2")
        XCTAssertEqual(WorkoutSourcePriority.classify(strava), .strava)
        // Sans identité : identique à l'ancienne règle par nom.
        for name in ["Apple Watch de Test", "Strava", "Hevy"] {
            XCTAssertEqual(WorkoutSourcePriority.classify(workout(name, bundle: nil, product: nil)),
                           WorkoutSourcePriority.classify(sourceName: name, recorded: true))
        }
    }

    // MARK: - Réglages

    func testSettingsDefaultsAndOverrides() throws {
        let suite = "HealthReconciliationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = HealthReconciliationSettings(defaults: defaults)

        XCTAssertEqual(settings.load(), .default)
        XCTAssertEqual(settings.load().order(for: .heartRate, context: .sleep).first, .whoop)

        settings.setOrder([.appleWatch, .appleWatch, .whoop], for: .heartRate, context: .sleep)
        settings.setWorkoutOrder([.whoop])
        let loaded = settings.load()
        XCTAssertEqual(loaded.order(for: .heartRate, context: .sleep), [.appleWatch, .whoop])
        XCTAssertEqual(loaded.workouts, [.whoop])
        XCTAssertEqual(loaded.order(for: .heartRate, context: .rest).first, .whoop, "autres contextes inchangés")

        settings.reset()
        XCTAssertEqual(settings.load(), .default)
    }
}

extension HealthReconciliationTests {
    func testThirdPartyDuplicatesAndDistinctSportsAreKeptCorrectly() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        func a(_ id: String, _ source: HealthDataSource, _ origin: String, _ sport: Int, _ start: Double, _ end: Double) -> HealthSourceActivity {
            HealthSourceActivity(id: id, source: source, sportType: sport,
                                 start: t.addingTimeInterval(start), end: t.addingTimeInterval(end), origin: origin)
        }
        let merged = HealthReconciliation.mergeActivities([
            a("watch-run", .appleWatch, "Watch", 37, 0, 4500),
            a("strava-run", .healthKit, "Strava", 37, 3, 4502),
            a("watch-walk", .appleWatch, "Watch", 52, 4505, 7200),
            a("strava-walk", .healthKit, "Strava", 52, 4502, 7202),
            a("hevy", .healthKit, "Hevy", 50, 7300, 9000),
            a("strava-gym", .healthKit, "Strava", 50, 7302, 9001)
        ])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map { $0.members.count }, [2, 2, 2])
        XCTAssertEqual(merged.map { $0.primary.sportType }, [37, 52, 50])
    }

    func testLongDetectedActivityDoesNotFuseRunAndWalk() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let long = HealthSourceActivity(id: "band", source: .whoop, start: t, end: t.addingTimeInterval(11000))
        let run = HealthSourceActivity(id: "run", source: .appleWatch, sportType: 37,
                                       start: t.addingTimeInterval(1800), end: t.addingTimeInterval(6300))
        let walk = HealthSourceActivity(id: "walk", source: .appleWatch, sportType: 52,
                                        start: t.addingTimeInterval(6301), end: t.addingTimeInterval(9000))
        XCTAssertEqual(HealthReconciliation.mergeActivities([long, run, walk]).count, 3)
    }

    func testUnspecifiedSleepHasDurationWithoutInventedStagesOrHRV() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HealthSample(uuid: "sleep", type: "sleepAnalysis", startDate: start.timeIntervalSince1970,
                                  endDate: start.timeIntervalSince1970 + 3600, value: 1, unit: "category",
                                  sourceName: "Third-party app", sourceBundle: "example.app", metadataOrigin: nil, importedAt: 0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = formatter.string(from: start.addingTimeInterval(3600))
        let result = try XCTUnwrap(HealthSleepAdapter.summaries(samples: [sample], date: date))
        XCTAssertEqual(result.summary.totalSleepMin, 60)
        XCTAssertFalse(result.stagesComplete)
        XCTAssertNil(result.session.stages)
        XCTAssertNil(result.summary.avgRmssd)
        XCTAssertEqual(result.session.sourceName, "Third-party app")
    }

    func testSleepSourcesAreNotAddedTogether() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = ["Apple Watch", "Third-party app"].enumerated().map { index, name in
            HealthSample(uuid: String(index), type: "sleepAnalysis", startDate: start.timeIntervalSince1970,
                         endDate: start.timeIntervalSince1970 + 3600, value: 3, unit: "category",
                         sourceName: name, sourceBundle: name, metadataOrigin: nil, importedAt: 0)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let result = try XCTUnwrap(HealthSleepAdapter.summaries(samples: samples,
                      date: formatter.string(from: start.addingTimeInterval(3600))))
        XCTAssertEqual(result.summary.totalSleepMin, 60)
    }
}

extension HealthReconciliationTests {
    func testCanonicalSessionsPreserveRecordedRunAndWalkInsteadOfLongDetection() {
        let base = 1_700_000_000
        let band = WorkoutSession(deviceId: "band", startTs: base, endTs: base + 11000,
                                  avgHr: 145, peakHr: 180, strain: nil, kind: "detected_cardio",
                                  durationS: 11000, caloriesKcal: nil)
        func workout(_ id: String, _ type: Int, _ start: Int, _ end: Int, _ name: String, _ distance: Double) -> ExternalWorkout {
            ExternalWorkout(id: id, source: "healthkit", sportType: type, startDate: Double(base + start),
                            endDate: Double(base + end), durationSec: Double(end - start), energyKcal: nil,
                            distanceM: distance, sourceName: name, importedAt: 0)
        }
        let workouts = [workout("watch-run", 37, 1800, 6300, "Apple Watch", 10027),
                        workout("strava-run", 37, 1801, 6301, "Strava", 10027),
                        workout("watch-walk", 52, 6305, 9000, "Apple Watch", 2896)]
        let merged = HealthWorkoutCanonicalizer.merge(band: [band], external: workouts)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.kind), ["running", "walking"])
        XCTAssertEqual(merged.first?.distanceM, 10027)
        XCTAssertEqual(merged.first?.externalID, "watch-run")
        XCTAssertEqual(merged.first?.sourceName, "Apple Watch")
    }

    func testOldWorkoutCacheWithoutNewFieldsStillDecodes() throws {
        let json = #"{"deviceId":"band","startTs":1,"endTs":2}"#.data(using: .utf8)!
        let session = try JSONDecoder().decode(WorkoutSession.self, from: json)
        XCTAssertNil(session.sportType)
        XCTAssertNil(session.distanceM)
        XCTAssertNil(session.externalID)
    }
}

extension HealthReconciliationTests {
    func testSleepRetainsLongStageAfterSubmicrosecondOverlap() throws {
        let start = 1_700_000_000.0
        func sample(_ id: String, _ a: Double, _ b: Double, _ value: Double) -> HealthSample {
            HealthSample(uuid: id, type: "sleepAnalysis", startDate: a, endDate: b, value: value,
                         unit: "category", sourceName: "Apple Watch", sourceBundle: "watch",
                         metadataOrigin: nil, importedAt: 0)
        }
        let rows = [sample("first", start, start + 3600, 3),
                    sample("last", (start + 3600).nextDown, start + 3600 + 23 * 60, 5)]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let result = try XCTUnwrap(HealthSleepAdapter.summaries(samples: rows,
                      date: formatter.string(from: Date(timeIntervalSince1970: start + 4980))))
        XCTAssertEqual(result.summary.totalSleepMin, 83, accuracy: 0.001)
        XCTAssertEqual(result.summary.remMin, 23, accuracy: 0.001)
        XCTAssertEqual(result.session.endTs, Int(start + 4980))
    }
}

extension HealthReconciliationTests {
    func testCumulativeOverlappingSameCategoryIsIncompleteAndKeepsCandidates() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(120), value: 100)], producerID: "a")
        let b = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(60), end: t.addingTimeInterval(180), value: 200)], producerID: "b")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b], from: t, to: t.addingTimeInterval(180), bucket: 180).buckets.first)
        XCTAssertTrue(bucket.isIncomplete)
        XCTAssertNil(bucket.value)
        XCTAssertEqual(bucket.partialValue, 150)
        XCTAssertEqual(bucket.candidates.count, 2)
        XCTAssertTrue(bucket.conflicts.contains { $0.reason == .overlappingProducers && !$0.isResolved })
    }

    func testCumulativeDisjointCategoriesIncludeBothAndZero() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .appleWatch, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(30), value: 0)], producerID: "watch")
        let b = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(30), end: t.addingTimeInterval(60), value: 15)], producerID: "app")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b], from: t, to: t.addingTimeInterval(60), bucket: 60).buckets.first)
        XCTAssertFalse(bucket.isIncomplete)
        XCTAssertEqual(bucket.value, 15)
        XCTAssertEqual(bucket.sources, [.appleWatch, .healthKit])
        XCTAssertTrue(bucket.conflicts.isEmpty)
    }

    func testCumulativePreferredSourceWinsOnlyOverlappingPortion() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let watch = HealthSourceSeries(source: .appleWatch, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 60)], producerID: "watch")
        let app = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(30), end: t.addingTimeInterval(90), value: 120)], producerID: "app")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .activeEnergyBurned, series: [watch, app], from: t, to: t.addingTimeInterval(90), bucket: 90).buckets.first)
        XCTAssertEqual(bucket.value, 120)
        XCTAssertTrue(bucket.conflicts.contains { $0.reason == .overlappingProducers && $0.isResolved })
    }

    func testCumulativeUnknownProducerIsNotReportedAsComplete() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let unknown = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(at: t, value: 0)])
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [unknown], from: t, to: t.addingTimeInterval(60), bucket: 60).buckets.first)
        XCTAssertTrue(bucket.isIncomplete)
        XCTAssertNil(bucket.value)
        XCTAssertEqual(bucket.candidates.first?.value, 0)
        XCTAssertEqual(bucket.conflicts.first?.reason, .unknownProducer)
    }

    func testCumulativeSeparatePointTimesRemainAmbiguous() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(at: t, value: 10)], producerID: "a")
        let b = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(at: t.addingTimeInterval(30), value: 20)], producerID: "b")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b], from: t, to: t.addingTimeInterval(60), bucket: 60).buckets.first)
        XCTAssertNil(bucket.value)
        XCTAssertTrue(bucket.conflicts.contains { $0.reason == .instantaneousOverlap && !$0.isResolved })
    }

    func testCumulativeIntervalsProratedAndEndIsExclusive() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let series = HealthSourceSeries(source: .healthKit, points: [
            HealthMeasurePoint(start: t, end: t.addingTimeInterval(120), value: 100),
            HealthMeasurePoint(at: t.addingTimeInterval(120), value: 7)
        ], producerID: "a")
        let result = HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [series], from: t, to: t.addingTimeInterval(120), bucket: 60)
        XCTAssertEqual(result.buckets.map(\.value), [50, 50])
        XCTAssertTrue(result.buckets.allSatisfy { !$0.isIncomplete })
    }
}

extension HealthReconciliationTests {
    func testCumulativeDifferentProducerPointsAcrossBucketsAreAmbiguous() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(at: t.addingTimeInterval(59), value: 10)], producerID: "a")
        let b = HealthSourceSeries(source: .appleWatch, points: [HealthMeasurePoint(at: t.addingTimeInterval(61), value: 20)], producerID: "b")
        let result = HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b], from: t, to: t.addingTimeInterval(120), bucket: 60)
        XCTAssertEqual(result.buckets.count, 2)
        XCTAssertTrue(result.buckets.allSatisfy(\.isIncomplete))
        XCTAssertTrue(result.buckets.allSatisfy { $0.value == nil })
    }

    func testCumulativeSameProducerOverlappingIntervalsAreAmbiguousButContiguousAreNot() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 10)
        let overlap = HealthMeasurePoint(start: t.addingTimeInterval(59), end: t.addingTimeInterval(90), value: 20)
        let adjacent = HealthMeasurePoint(start: t.addingTimeInterval(60), end: t.addingTimeInterval(90), value: 20)
        func merge(_ second: HealthMeasurePoint) -> HealthCumulativeBucket? {
            let series = HealthSourceSeries(source: .healthKit, points: [a, second], producerID: "same-app")
            return HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [series], from: t, to: t.addingTimeInterval(120), bucket: 120).buckets.first
        }
        let uncertain = try XCTUnwrap(merge(overlap))
        XCTAssertTrue(uncertain.isIncomplete)
        XCTAssertNil(uncertain.value)
        XCTAssertEqual(uncertain.conflicts.first?.reason, .sameProducerOverlap)
        let valid = try XCTUnwrap(merge(adjacent))
        XCTAssertFalse(valid.isIncomplete)
        XCTAssertEqual(valid.value, 30)
    }
}

extension HealthReconciliationTests {
    func testExcludedProducerDoesNotMakePreferredCumulativeSourceIncomplete() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let watch = HealthSourceSeries(source: .appleWatch, points: [
            HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 25)
        ], producerID: "watch")
        // Unknown producer and a point in the next bucket would otherwise prevent
        // resolving even an explicitly isolated Watch source.
        let excluded = HealthSourceSeries(source: .healthKit, points: [
            HealthMeasurePoint(at: t.addingTimeInterval(61), value: 99),
            HealthMeasurePoint(start: t, end: t.addingTimeInterval(50), value: 15)
        ])
        let priority = HealthSourcePriority(orders: [:], workouts: [.appleWatch], fallback: [.appleWatch])
        let result = HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [watch, excluded],
            from: t, to: t.addingTimeInterval(120), bucket: 60, priority: priority)
        let first = try XCTUnwrap(result.buckets.first)
        XCTAssertEqual(first.value, 25)
        XCTAssertFalse(first.isIncomplete)
        XCTAssertEqual(first.sources, [.appleWatch])
        XCTAssertEqual(first.candidates.count, 2)
        let second = try XCTUnwrap(result.buckets.last)
        XCTAssertNil(second.value)
        XCTAssertFalse(second.isIncomplete)
        XCTAssertEqual(second.candidates.count, 1)
    }
}

extension HealthReconciliationTests {
    func testCumulativeConflictDoesNotListExcludedProducersAsParticipants() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let watch = HealthSourceSeries(source: .appleWatch, points: [HealthMeasurePoint(at: t, value: 10)], producerID: "watch")
        let app = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(at: t.addingTimeInterval(61), value: 20)], producerID: "app")
        let excluded = HealthSourceSeries(source: .whoop, points: [HealthMeasurePoint(at: t, value: 30)], producerID: "excluded")
        let priority = HealthSourcePriority(orders: [:], workouts: [], fallback: [.appleWatch, .healthKit])
        let result = HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [watch, app, excluded],
            from: t, to: t.addingTimeInterval(120), bucket: 60, priority: priority)
        let first = try XCTUnwrap(result.buckets.first)
        let conflict = try XCTUnwrap(first.conflicts.first { $0.reason == .instantaneousOverlap })
        XCTAssertEqual(Set(conflict.candidates.map(\.source)), Set([.appleWatch, .healthKit]))
        XCTAssertTrue(first.candidates.contains { $0.source == .whoop })
    }
}

extension HealthReconciliationTests {
    func testExplicitProducerOrderSelectsOverlapAndPreservesDisjointPortions() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let watch = HealthSourceSeries(source: .appleWatch, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 60)], producerID: "bundle:watch")
        let app = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(30), end: t.addingTimeInterval(90), value: 120)], producerID: "bundle:app")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [watch, app], from: t, to: t.addingTimeInterval(90), bucket: 90, producerOrder: ["bundle:app", "bundle:watch"]).buckets.first)
        XCTAssertEqual(bucket.value, 150)
        XCTAssertTrue(bucket.conflicts.contains { $0.reason == .overlappingProducers && $0.isResolved })
    }

    func testExplicitProducerOrderResolvesSameCategoryAndRetainsZero() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 0)], producerID: "bundle:a")
        let b = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 50)], producerID: "bundle:b")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b], from: t, to: t.addingTimeInterval(60), bucket: 60, producerOrder: ["bundle:a"]).buckets.first)
        XCTAssertEqual(bucket.value, 0)
        XCTAssertFalse(bucket.isIncomplete)
    }

    func testExplicitProducerOrderDoesNotResolveFragileNamesOrInstants() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 20)], producerID: "bundle:a")
        let fragile = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 50)], producerID: "name:other")
        let point = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(at: t, value: 50)], producerID: "bundle:b")
        for other in [fragile, point] {
            let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, other], from: t, to: t.addingTimeInterval(60), bucket: 60, producerOrder: ["bundle:a"]).buckets.first)
            XCTAssertNil(bucket.value)
            XCTAssertTrue(bucket.isIncomplete)
        }
    }

    func testExplicitProducerOrderDoesNotEnableExcludedCategory() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let watch = HealthSourceSeries(source: .appleWatch, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 25)], producerID: "bundle:watch")
        let app = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 50)], producerID: "bundle:app")
        var priority = HealthSourcePriority.default
        priority.orders[HealthSampleKind.stepCount.rawValue] = [.appleWatch]
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [watch, app], from: t, to: t.addingTimeInterval(60), bucket: 60, priority: priority, producerOrder: ["bundle:app"]).buckets.first)
        XCTAssertEqual(bucket.value, 25)
    }
}

extension HealthReconciliationTests {
    func testOverlappingSecondaryProducerDoesNotBlockCoveredPreferredSource() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let preferred = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(120), value: 120)], producerID: "bundle:a")
        let secondary = HealthSourceSeries(source: .healthKit, points: [
            HealthMeasurePoint(start: t.addingTimeInterval(20), end: t.addingTimeInterval(80), value: 60),
            HealthMeasurePoint(start: t.addingTimeInterval(40), end: t.addingTimeInterval(100), value: 60)
        ], producerID: "bundle:b")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [preferred, secondary], from: t, to: t.addingTimeInterval(120), bucket: 120, producerOrder: ["bundle:a", "bundle:b"]).buckets.first)
        XCTAssertEqual(bucket.value, 120)
        XCTAssertFalse(bucket.isIncomplete)
    }

    func testOverlappingSecondaryProducerRemainsAmbiguousOutsidePreferredCoverage() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let preferred = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(30), value: 30)], producerID: "bundle:a")
        let secondary = HealthSourceSeries(source: .healthKit, points: [
            HealthMeasurePoint(start: t.addingTimeInterval(20), end: t.addingTimeInterval(80), value: 60),
            HealthMeasurePoint(start: t.addingTimeInterval(40), end: t.addingTimeInterval(100), value: 60)
        ], producerID: "bundle:b")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [preferred, secondary], from: t, to: t.addingTimeInterval(120), bucket: 120, producerOrder: ["bundle:a", "bundle:b"]).buckets.first)
        XCTAssertNil(bucket.value)
        XCTAssertTrue(bucket.conflicts.contains { $0.reason == .sameProducerOverlap && !$0.isResolved })
    }
}

extension HealthReconciliationTests {
    func testSelectedProducersReflectActualDisjointAndOverlappingContributions() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 60)], producerID: "bundle:a")
        let b = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(30), end: t.addingTimeInterval(90), value: 60)], producerID: "bundle:b")
        let c = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(30), end: t.addingTimeInterval(60), value: 50)], producerID: "bundle:c")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b, c], from: t, to: t.addingTimeInterval(90), bucket: 90, producerOrder: ["bundle:a", "bundle:b", "bundle:c"]).buckets.first)
        XCTAssertEqual(bucket.selectedProducerIDs, ["bundle:a", "bundle:b"])
        XCTAssertFalse(bucket.selectedProducerIDs.contains("bundle:c"))
    }

    func testIncompleteBucketDoesNotClaimPartialProducersAsSelected() throws {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let a = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t, end: t.addingTimeInterval(60), value: 60)], producerID: "bundle:a")
        let b = HealthSourceSeries(source: .healthKit, points: [HealthMeasurePoint(start: t.addingTimeInterval(30), end: t.addingTimeInterval(90), value: 60)], producerID: "bundle:b")
        let bucket = try XCTUnwrap(HealthReconciliation.mergeCumulativeSeries(kind: .stepCount, series: [a, b], from: t, to: t.addingTimeInterval(90), bucket: 90).buckets.first)
        XCTAssertTrue(bucket.isIncomplete)
        XCTAssertTrue(bucket.selectedProducerIDs.isEmpty)
    }
}

// MARK: - Rapport Santé : source du sommeil

extension HealthReconciliationTests {
    private func sleepSnapshot(start: Double, end: Double, minutes: Double) -> DailySnapshot {
        DailySnapshot(date: "2023-11-15", totalSleepMin: minutes, efficiency: nil, deepMin: nil, remMin: nil,
                      lightMin: nil, disturbances: nil, sleepStart: start, sleepEnd: end, sleepScore: nil,
                      restingHR: nil, avgHrv: nil, recovery: nil, recoveryStatus: "low", recoveryBand: nil,
                      strain: nil, sleepTargetMin: nil, targetStrain: nil, targetStrainConfidence: nil,
                      recentOverload: nil, adviceSignals: [])
    }

    private func night(_ id: String, name: String, start: Double, end: Double) -> HealthSample {
        HealthSample(uuid: id, type: HealthSampleKind.sleepAnalysis.rawValue, startDate: start, endDate: end,
                     value: 3, unit: "HKCategoryValueSleepAnalysis", sourceName: name,
                     sourceBundle: name.lowercased(), metadataOrigin: nil, importedAt: 0)
    }

    private func sleepRow(samples: [HealthSample], snapshot: DailySnapshot, sessions: [SleepSession],
                          priority: HealthSourcePriority = .default) throws -> HealthDayRow {
        let from = 1_700_000_000.0
        let raw = HealthDayRaw(date: "2023-11-15", from: from, to: from + 86_400,
                               samples: [.sleepAnalysis: samples], workouts: [], bandHR: [])
        return try XCTUnwrap(HealthDayReportBuilder.build(raw: raw, snapshot: snapshot, bandSleep: sessions,
                                                          bandWorkouts: [], priority: priority).row(.sleepAnalysis))
    }

    /// Bracelet + Watch, même nuit, Watch retenue (priorité par défaut) : le moteur a remplacé la
    /// session bracelet par celle de la Watch ; la nuit du bracelet n'est plus disponible.
    func testSleepRowWatchRetainedOverBandIsSingleSourceNotSelfComparison() throws {
        let start = 1_700_000_000.0 + 1_800, end = start + 8 * 3600
        let snapshot = sleepSnapshot(start: start, end: end, minutes: 480)
        let watchSession = SleepSession(startTs: Int(start), endTs: Int(end), efficiency: nil, restingHr: nil,
                                        avgHrv: nil, stages: nil, sourceName: "Apple Watch")
        let row = try sleepRow(samples: [night("w", name: "Apple Watch", start: start, end: end)],
                               snapshot: snapshot, sessions: [watchSession])
        XCTAssertEqual(row.source, HealthDataSource.appleWatch.label)
        XCTAssertNil(row.agreement)
        XCTAssertTrue(row.isSingleSource)
    }

    /// Bracelet + Watch, même nuit, bracelet retenu : comparaison réelle entre deux sources distinctes.
    func testSleepRowBandRetainedComparesWithDistinctWatchNight() throws {
        let start = 1_700_000_000.0 + 1_800, end = start + 8 * 3600
        let snapshot = sleepSnapshot(start: start, end: end, minutes: 450)
        let bandSession = SleepSession(startTs: Int(start), endTs: Int(end), efficiency: 0.94, restingHr: 52,
                                       avgHrv: 60, stages: nil)
        var priority = HealthSourcePriority.default
        priority.orders[HealthSampleKind.sleepAnalysis.rawValue] = [.whoop, .appleWatch, .healthKit]
        let row = try sleepRow(samples: [night("w", name: "Apple Watch", start: start, end: end)],
                               snapshot: snapshot, sessions: [bandSession], priority: priority)
        XCTAssertEqual(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: [bandSession]), .whoop)
        XCTAssertEqual(row.source, HealthDataSource.whoop.label)
        XCTAssertEqual(row.value, "7 h 30")
        let agreement = try XCTUnwrap(row.agreement)
        XCTAssertTrue(agreement.contains(HealthDataSource.whoop.label) && agreement.contains(HealthDataSource.appleWatch.label))
        XCTAssertTrue(agreement.contains("30 min"), agreement)
        XCTAssertFalse(row.isSingleSource)

        // Without a band session in the cache, the computed night is never labelled band.
        XCTAssertNil(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: []))
        let unknown = try sleepRow(samples: [night("w", name: "Apple Watch", start: start, end: end)],
                                   snapshot: snapshot, sessions: [], priority: priority)
        XCTAssertEqual(unknown.source, HealthDataSource.appleWatch.label)
        XCTAssertNil(unknown.agreement)
    }

    /// Nuit bracelet fragmentée en deux sessions (bornes = premier début / dernière fin) + nuit Watch.
    func testSleepRowFragmentedBandNightIsBandAndComparedWithWatch() throws {
        let start = 1_700_000_000.0 + 1_800, end = start + 8 * 3600
        let snapshot = sleepSnapshot(start: start, end: end, minutes: 420)
        let first = SleepSession(startTs: Int(start), endTs: Int(start) + 3 * 3600, efficiency: nil,
                                 restingHr: nil, avgHrv: nil, stages: nil)
        let second = SleepSession(startTs: Int(start) + 4 * 3600, endTs: Int(end), efficiency: nil,
                                  restingHr: nil, avgHrv: nil, stages: nil)
        XCTAssertEqual(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: [first, second]), .whoop)
        let row = try sleepRow(samples: [night("w", name: "Apple Watch", start: start, end: end)],
                               snapshot: snapshot, sessions: [first, second])
        XCTAssertEqual(row.source, HealthDataSource.whoop.label)
        XCTAssertEqual(row.value, "7 h 00")
        let agreement = try XCTUnwrap(row.agreement)
        XCTAssertTrue(agreement.contains(HealthDataSource.appleWatch.label), agreement)
        XCTAssertTrue(agreement.contains("1 h 00"), agreement)
        XCTAssertFalse(row.isSingleSource)
    }

    /// Nuit Santé aux bornes fractionnaires : même troncature que `SleepSession.startTs/endTs`.
    func testRetainedSleepSourceMatchesFractionalHealthBounds() {
        let start = 1_700_000_000.0 + 1_800.6, end = start + 8 * 3600
        let snapshot = sleepSnapshot(start: start, end: end, minutes: 480)
        let watchSession = SleepSession(startTs: Int(start), endTs: Int(end), efficiency: nil, restingHr: nil,
                                        avgHrv: nil, stages: nil, sourceName: "Apple Watch")
        XCTAssertEqual(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: [watchSession]),
                       .appleWatch)
    }

    /// Nuit Santé retenue puis retirée du cache (nuit voisine qui la recouvre) : jamais « Bracelet ».
    func testRetainedSleepSourceIsUnknownWhenHealthSessionLeftTheCache() {
        let start = 1_700_000_000.0 + 1_800, end = start + 8 * 3600
        let snapshot = sleepSnapshot(start: start, end: end, minutes: 480)
        let neighbour = SleepSession(startTs: Int(end) + 3600, endTs: Int(end) + 5 * 3600, efficiency: nil,
                                     restingHr: nil, avgHrv: nil, stages: nil)
        XCTAssertNil(HealthDayReportBuilder.retainedSleepSource(snapshot: snapshot, sessions: [neighbour]))
    }

    /// Watch retenue et nuit iPhone distincte : la comparaison cite Watch et Santé, jamais le bracelet.
    func testSleepRowWatchRetainedComparesWithOtherHealthSourceOnly() throws {
        let start = 1_700_000_000.0 + 1_800, end = start + 8 * 3600
        let snapshot = sleepSnapshot(start: start, end: end, minutes: 480)
        let watchSession = SleepSession(startTs: Int(start), endTs: Int(end), efficiency: nil, restingHr: nil,
                                        avgHrv: nil, stages: nil, sourceName: "Apple Watch")
        let row = try sleepRow(samples: [night("w", name: "Apple Watch", start: start, end: end),
                                         night("p", name: "iPhone", start: start + 3600, end: end)],
                               snapshot: snapshot, sessions: [watchSession])
        let agreement = try XCTUnwrap(row.agreement)
        XCTAssertFalse(agreement.contains(HealthDataSource.whoop.label), agreement)
        XCTAssertTrue(agreement.contains("1 h 00"), agreement)
    }
}
