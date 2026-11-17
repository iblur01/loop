import Foundation
import WhoopStore

// MARK: - Vue fusionnée d'un jour (bracelet + Apple Santé), pour Aujourd'hui
//
// Pur : construit à partir de lignes déjà lues (`HealthDayRaw`) et de la réconciliation
// (`HealthReconciliation`). Chaque valeur porte sa source ; une grandeur sans aucune source reste
// une ligne avec `value == nil` (trou visible, jamais de valeur inventée).

/// Lignes brutes d'un jour, lues par `LocalMetricsEngine.healthDayRaw(date:)`.
struct HealthDayRaw: Sendable {
    let date: String
    /// Bornes du jour civil local, converties en timestamps UTC ; `to` exclusif.
    let from: Double
    let to: Double
    /// Par type ; le sommeil commence 6 h avant `from` (veille vers 18:00 locale).
    let samples: [HealthSampleKind: [HealthSample]]
    let workouts: [ExternalWorkout]
    /// FC du bracelet sur le jour.
    let bandHR: [HealthMeasurePoint]

    var hasHealthData: Bool {
        !workouts.isEmpty || samples.values.contains { !$0.isEmpty }
    }
}

struct HealthDayRow: Identifiable, Equatable {
    let kind: HealthSampleKind
    let title: String
    /// Valeur formatée, nil = aucune source ce jour.
    let value: String?
    /// Source(s) retenue(s), ex. "Apple Watch" ou "Apple Watch 80 % · iPhone 20 %".
    let source: String?
    /// Accord entre deux sources quand elles se recouvrent, ex. "Bracelet / Apple Watch : écart médian 2 bpm (40 créneaux)".
    let agreement: String?
    /// Précision (ex. VFC du bracelet non comparable).
    let note: String?
    /// Part de chaque source retenue (0…1, triée décroissante), pour les barres par source.
    var shares: [HealthDaySourceShare] = []
    /// Valeurs retenues par créneau (heure pour les cumulés), pour le graphique du jour.
    var points: [HealthDayPoint] = []
    /// Conflits non résolus, conservés avec les producteurs et périodes concernés.
    var conflicts: [HealthCumulativeConflict] = []
    var conflictSourceNames: [String] = []
    var hasUnknownConflictSource: Bool = false
    var hasConflicts: Bool { !conflicts.isEmpty }
    var isPartial: Bool = false
    /// Sommeil : une valeur est retenue mais aucune autre source distincte n'est disponible pour
    /// la comparer (ex. nuit Apple Watch retenue, nuit du bracelet écartée du calcul).
    var isSingleSource: Bool = false

    var id: String { kind.rawValue }
}

/// Part d'une source dans une grandeur fusionnée (mise en forme de `bucketsBySource`).
struct HealthDaySourceShare: Equatable, Identifiable {
    let source: HealthDataSource
    let fraction: Double

    var id: String { source.rawValue }
}

/// Valeur retenue sur un créneau de la fusion.
struct HealthDayPoint: Equatable, Identifiable {
    let start: Date
    let value: Double

    var id: Date { start }
}

struct HealthDayActivityRow: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let durationMin: Int
    /// Sources contributrices, par priorité.
    let sources: [HealthDataSource]
    let energy: String?
}

struct HealthDayReport: Equatable {
    let date: String
    let rows: [HealthDayRow]
    let activities: [HealthDayActivityRow]
    /// Au moins une donnée Apple Santé ce jour (sinon la carte est masquée).
    let hasHealthData: Bool

    func row(_ kind: HealthSampleKind) -> HealthDayRow? { rows.first { $0.kind == kind } }
}

// MARK: - Construction

enum HealthDayReportBuilder {
    /// Créneau de comparaison de la FC (5 min) : assez fin pour suivre une séance, assez large
    /// pour que la Watch (une mesure toutes les quelques minutes au repos) ait une valeur.
    static let heartRateBucket: TimeInterval = 300
    /// Créneau des grandeurs cumulées (1 h) : une seule source retenue par heure, ce qui évite
    /// d'additionner les pas de la Watch ET de l'iPhone pour la même marche.
    static let cumulativeBucket: TimeInterval = 3600

    /// Valeurs `HKCategoryValueSleepAnalysis` « endormi » : asleepUnspecified(1), asleepCore(3),
    /// asleepDeep(4), asleepREM(5). inBed(0) et awake(2) sont exclus.
    static let asleepValues: Set<Int> = [1, 3, 4, 5]

    static func build(raw: HealthDayRaw,
                      snapshot: DailySnapshot?,
                      bandSleep: [SleepSession],
                      bandWorkouts: [WorkoutSession],
                      priority: HealthSourcePriority = .default,
                      producerOrders: [String: [String]] = [:]) -> HealthDayReport {
        let from = Date(timeIntervalSince1970: raw.from)
        let to = Date(timeIntervalSince1970: raw.to)

        let activities = mergedActivities(raw: raw, bandWorkouts: bandWorkouts, priority: priority)
        let timeline = HealthContextTimeline(
            sleep: bandSleep.compactMap { s in
                s.endTs > s.startTs ? DateInterval(start: Date(timeIntervalSince1970: Double(s.startTs)),
                                                   end: Date(timeIntervalSince1970: Double(s.endTs))) : nil
            },
            activity: activities.map { DateInterval(start: $0.start, end: $0.end) })

        var rows: [HealthDayRow] = []
        rows.append(heartRateRow(raw: raw, from: from, to: to, timeline: timeline, priority: priority))
        for kind in [HealthSampleKind.stepCount, .activeEnergyBurned, .basalEnergyBurned,
                     .distanceWalkingRunning, .appleExerciseTime] {
            rows.append(cumulativeRow(kind, raw: raw, from: from, to: to, priority: priority,
                                      producerOrder: producerOrders[kind.rawValue] ?? []))
        }
        rows.append(sleepRow(raw: raw, snapshot: snapshot, sessions: bandSleep, priority: priority))
        rows.append(restingHRRow(raw: raw, snapshot: snapshot, from: from, to: to, priority: priority))
        rows.append(hrvRow(raw: raw, snapshot: snapshot, from: from, to: to, priority: priority))
        for kind in [HealthSampleKind.vo2Max, .bodyMass] {
            rows.append(dailyAverageRow(kind, raw: raw, from: from, to: to, priority: priority))
        }

        let activityRows = activities.map { a in
            HealthDayActivityRow(
                id: a.primary.id,
                title: sportTitle(a),
                start: a.start, end: a.end,
                durationMin: Int((a.durationSec / 60).rounded()),
                sources: a.sources,
                energy: a.energyKcal.map { "\(Int($0.rounded())) kcal" + (a.energySource.map { " · \($0.label)" } ?? "") })
        }

        return HealthDayReport(date: raw.date, rows: rows, activities: activityRows,
                               hasHealthData: raw.hasHealthData)
    }

    // MARK: Séances

    static func mergedActivities(raw: HealthDayRaw, bandWorkouts: [WorkoutSession],
                                 priority: HealthSourcePriority) -> [HealthMergedActivity] {
        let band = bandWorkouts
            .filter { $0.externalID == nil && Double($0.startTs) >= raw.from && Double($0.startTs) < raw.to }
            .map { w in
                HealthSourceActivity(id: "band-\(w.startTs)", source: .whoop, sportType: nil,
                                     start: Date(timeIntervalSince1970: Double(w.startTs)),
                                     end: Date(timeIntervalSince1970: Double(w.endTs)),
                                     durationSec: w.durationS.map(Double.init),
                                     energyKcal: w.caloriesKcal)
            }
        let external = raw.workouts.map(HealthSourceActivity.init)
        return HealthReconciliation.mergeActivities(band + external, priority: priority)
    }

    // MARK: FC

    private static func heartRateRow(raw: HealthDayRaw, from: Date, to: Date,
                                     timeline: HealthContextTimeline, priority: HealthSourcePriority) -> HealthDayRow {
        var series = externalSeries(raw.samples[.heartRate])
        let band = perMinute(raw.bandHR)
        if !band.isEmpty { series.append(HealthSourceSeries(source: .whoop, points: band)) }
        let merged = HealthReconciliation.mergeSeries(kind: .heartRate, series: series, from: from, to: to,
                                                      bucket: heartRateBucket, timeline: timeline, priority: priority)
        let values = merged.buckets.compactMap(\.value)
        let value = values.isEmpty ? nil : String(format: String(localized: "health.report.average", table: "Core"), Int((values.reduce(0, +) / Double(values.count)).rounded()))
        return HealthDayRow(kind: .heartRate, title: HealthSampleKind.heartRate.label,
                            value: value,
                            source: sourceShares(merged.bucketsBySource),
                            agreement: agreementText(merged, unit: "bpm", slot: String(localized: "health.report.slots", table: "Core")),
                            note: nil,
                            shares: shareList(merged.bucketsBySource))
    }

    // MARK: Cumulés

    private static func cumulativeRow(_ kind: HealthSampleKind, raw: HealthDayRaw, from: Date, to: Date,
                                      priority: HealthSourcePriority, producerOrder: [String]) -> HealthDayRow {
        let isSteps = kind == .stepCount
        let series = HealthSourceSeries.groupedByProducer(raw.samples[kind] ?? [], stepsOnly: isSteps).filter { $0.source != .whoop }
        var effectivePriority = priority
        if isSteps { effectivePriority.orders[kind.rawValue] = [.appleWatch, .healthKit] }
        let merged = HealthReconciliation.mergeCumulativeSeries(kind: kind, series: series,
                                                                from: from, to: to, bucket: cumulativeBucket,
                                                                priority: effectivePriority, producerOrder: isSteps ? [] : producerOrder)
        let conflicts = merged.buckets.flatMap(\.conflicts).filter { !$0.isResolved }
        // Les seules fenêtres ambiguës récupérables sont des intervalles connus : les points
        // instantanés et les producteurs inconnus peuvent masquer un doublon hors fenêtre.
        let partial = isSteps && !conflicts.isEmpty && conflicts.allSatisfy {
            $0.reason == .overlappingProducers || $0.reason == .sameProducerOverlap
        } && !merged.buckets.contains { bucket in
            bucket.candidates.contains { candidate in
                series.contains { $0.producerID == candidate.producerID && $0.source == candidate.source && $0.points.contains { $0.start == $0.end } }
            }
        }
        let values = merged.buckets.compactMap { partial ? $0.partialValue : $0.value }
        let total = values.reduce(0, +)
        let conflictCandidates = conflicts.flatMap(\.candidates)
        let conflictIDs = Set(conflictCandidates.compactMap(\.producerID))
        let names = (raw.samples[kind] ?? []).compactMap { sample -> String? in
            let bundle = sample.sourceBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = sample.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = bundle.flatMap { $0.isEmpty ? nil : "bundle:" + $0.lowercased() }
                ?? name.flatMap { $0.isEmpty ? nil : "name:" + $0.lowercased() }
            guard let id, conflictIDs.contains(id) else { return nil }
            return (name?.isEmpty == false ? name : nil) ?? bundle
        }
        // The engine reports only IDs that actually contributed, not all candidates.
        // A bundle may have several displayed names; use the bundle in that case instead
        // of attributing the result to an arbitrary name.
        let selectedIDs = Set(merged.buckets.flatMap(\.selectedProducerIDs))
        var selectedNames: [String: Set<String>] = [:]
        for sample in raw.samples[kind] ?? [] {
            let bundle = sample.sourceBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = sample.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = bundle.flatMap { $0.isEmpty ? nil : "bundle:" + $0.lowercased() }
                ?? name.flatMap { $0.isEmpty ? nil : "name:" + $0.lowercased() }
            guard let id, selectedIDs.contains(id) else { continue }
            if let name, !name.isEmpty { selectedNames[id, default: []].insert(name) }
        }
        let labelsByID = Dictionary(uniqueKeysWithValues: selectedIDs.map { id -> (String, String) in
            let labels = selectedNames[id] ?? []
            let fallback = String(id.dropFirst(id.hasPrefix("bundle:") ? 7 : 5))
            return (id, labels.count == 1 ? labels.first! : fallback)
        })
        let producerLabels = labelsByID.map { id, label in
            labelsByID.values.filter { $0 == label }.count > 1 ? "\(label) (\(id))" : label
        }.sorted()
        var counts: [HealthDataSource: Int] = [:]
        for bucket in merged.buckets {
            for source in Set(bucket.sources) { counts[source, default: 0] += 1 }
        }
        return HealthDayRow(kind: kind, title: kind.label,
                            value: values.isEmpty || (!conflicts.isEmpty && !partial) ? nil : format(total, kind: kind),
                            source: (conflicts.isEmpty || partial) ? (isSteps ? [HealthDataSource.appleWatch, .healthKit].filter { counts[$0] != nil }.map { $0 == .appleWatch ? "Apple Watch" : "iPhone" }.joined(separator: " · ") : (producerLabels.isEmpty ? sourceShares(counts) : producerLabels.joined(separator: " · "))) : nil,
                            agreement: nil,
                            note: nil,
                            shares: conflicts.isEmpty ? shareList(counts) : [],
                            points: conflicts.isEmpty ? merged.buckets.compactMap { b in b.value.map { HealthDayPoint(start: b.start, value: $0) } } : [],
                            conflicts: conflicts,
                            conflictSourceNames: Array(Set(names)).sorted(),
                            hasUnknownConflictSource: conflictCandidates.contains { $0.producerID == nil },
                            isPartial: partial && !values.isEmpty)
    }

    // MARK: Valeurs du jour (VO2max, poids)

    private static func dailyAverageRow(_ kind: HealthSampleKind, raw: HealthDayRaw, from: Date, to: Date,
                                        priority: HealthSourcePriority) -> HealthDayRow {
        let merged = HealthReconciliation.mergeSeries(kind: kind, series: externalSeries(raw.samples[kind]),
                                                      from: from, to: to, bucket: to.timeIntervalSince(from),
                                                      priority: priority)
        let bucket = merged.buckets.first
        return HealthDayRow(kind: kind, title: kind.label,
                            value: bucket?.value.map { format($0, kind: kind) },
                            source: bucket?.source?.label,
                            agreement: agreementText(merged, unit: unitLabel(kind), slot: nil),
                            note: nil)
    }

    // MARK: FC repos

    private static func restingHRRow(raw: HealthDayRaw, snapshot: DailySnapshot?, from: Date, to: Date,
                                     priority: HealthSourcePriority) -> HealthDayRow {
        var series = externalSeries(raw.samples[.restingHeartRate])
        if let rhr = snapshot?.restingHR, rhr.isFinite, rhr > 0 {
            series.append(HealthSourceSeries(source: .whoop, points: [HealthMeasurePoint(at: from, value: rhr)]))
        }
        let merged = HealthReconciliation.mergeSeries(kind: .restingHeartRate, series: series, from: from, to: to,
                                                      bucket: to.timeIntervalSince(from), priority: priority)
        let bucket = merged.buckets.first
        return HealthDayRow(kind: .restingHeartRate, title: HealthSampleKind.restingHeartRate.label,
                            value: bucket?.value.map { "\(Int($0.rounded())) bpm" },
                            source: bucket?.source?.label,
                            agreement: agreementText(merged, unit: "bpm", slot: nil),
                            note: nil)
    }

    // MARK: VFC

    /// La VFC Santé est un SDNN, celle du bracelet un RMSSD : pas de fusion ni d'accord entre les deux.
    private static func hrvRow(raw: HealthDayRaw, snapshot: DailySnapshot?, from: Date, to: Date,
                               priority: HealthSourcePriority) -> HealthDayRow {
        let merged = HealthReconciliation.mergeSeries(kind: .heartRateVariabilitySDNN,
                                                      series: externalSeries(raw.samples[.heartRateVariabilitySDNN]),
                                                      from: from, to: to, bucket: to.timeIntervalSince(from),
                                                      priority: priority)
        let bucket = merged.buckets.first
        let bandNote = snapshot?.avgHrv.flatMap { v -> String? in
            guard v.isFinite, v > 0 else { return nil }
            return String(format: String(localized: "health.report.hrvBand", table: "Core"), Int(v.rounded()))
        }
        return HealthDayRow(kind: .heartRateVariabilitySDNN, title: HealthSampleKind.heartRateVariabilitySDNN.label,
                            value: bucket?.value.map { "\(Int($0.rounded())) ms" },
                            source: bucket?.source?.label,
                            agreement: agreementText(merged, unit: "ms", slot: nil),
                            note: bandNote)
    }

    // MARK: Sommeil

    /// Source réelle de la nuit retenue par le calcul. Quand le moteur retient une nuit Santé, il
    /// remplace la session du bracelet par la session Santé (`sourceName` non nil) dont les bornes
    /// sont celles du résumé du jour ; une session sans `sourceName` vient du bracelet. Une nuit
    /// bracelet peut être fragmentée (bornes = premier début / dernière fin) : elle est reconnue
    /// si au moins une session bracelet tient dans ces bornes. Sinon (ex. session Santé retirée
    /// du cache par une nuit voisine), la source est inconnue : nil, jamais « Bracelet » par défaut.
    static func retainedSleepSource(snapshot: DailySnapshot?, sessions: [SleepSession]) -> HealthDataSource? {
        guard let snapshot, let total = snapshot.totalSleepMin, total.isFinite, total > 0,
              let start = snapshot.sleepStart, let end = snapshot.sleepEnd, start.isFinite, end.isFinite else { return nil }
        // Same truncation as `SleepSession.startTs/endTs` (`Int(_:)`), so fractional bounds match.
        let lo = Int(start), hi = Int(end)
        if let health = sessions.first(where: { $0.sourceName != nil && $0.startTs == lo && $0.endTs == hi }) {
            return health.healthSource ?? HealthDataSource.classify(sourceName: health.sourceName)
        }
        if sessions.contains(where: { $0.sourceName == nil && $0.startTs >= lo && $0.endTs <= hi && $0.endTs > $0.startTs }) {
            return .whoop
        }
        return nil
    }

    /// Minutes endormies de la nuit qui se termine ce jour (même rattachement que le bracelet),
    /// par source ; les intervalles d'une même source sont réunis avant d'être sommés.
    /// La valeur du calcul (snapshot) est attribuée à sa source réelle : une nuit Santé retenue
    /// n'est jamais présentée comme celle du bracelet, ni comparée avec elle-même.
    private static func sleepRow(raw: HealthDayRaw, snapshot: DailySnapshot?, sessions: [SleepSession],
                                 priority: HealthSourcePriority) -> HealthDayRow {
        var minutes: [HealthDataSource: Double] = [:]
        var intervals: [HealthDataSource: [(Double, Double)]] = [:]
        for s in raw.samples[.sleepAnalysis] ?? [] {
            guard let v = s.value, asleepValues.contains(Int(v)),
                  s.endDate > s.startDate, s.endDate >= raw.from, s.endDate < raw.to else { continue }
            let source = HealthDataSource.classify(sourceName: s.sourceName, metadataOrigin: s.metadataOrigin,
                                                   sourceBundle: s.sourceBundle,
                                                   productType: s.productType, deviceModel: s.deviceModel)
            guard source != .whoop else { continue }
            intervals[source, default: []].append((s.startDate, s.endDate))
        }
        for (source, list) in intervals { minutes[source] = unionSeconds(list) / 60 }

        let chosen: HealthDataSource?
        if let retained = retainedSleepSource(snapshot: snapshot, sessions: sessions),
           let total = snapshot?.totalSleepMin {
            // The computed value wins over the raw union for its own source.
            minutes[retained] = total
            chosen = retained
        } else {
            chosen = priority.order(for: .sleepAnalysis, context: .sleep).first { minutes[$0] != nil }
        }
        var agreement: String?
        var singleSource = false
        if let chosen, let chosenMin = minutes[chosen] {
            let others = [HealthDataSource.whoop, .appleWatch, .healthKit].filter { $0 != chosen && minutes[$0] != nil }
            if let other = others.first, let otherMin = minutes[other] {
                // Bracelet first when it is part of the pair, as in the other rows.
                let (a, b) = other == .whoop ? (other, chosen) : (chosen, other)
                agreement = String(format: String(localized: "health.report.difference", table: "Core"),
                                   a.label, b.label, duration(abs(chosenMin - otherMin)))
            } else {
                singleSource = true
            }
        }
        var row = HealthDayRow(kind: .sleepAnalysis, title: HealthSampleKind.sleepAnalysis.label,
                               value: chosen.flatMap { minutes[$0] }.map(duration),
                               source: chosen?.label,
                               agreement: agreement,
                               note: nil)
        row.isSingleSource = singleSource
        return row
    }

    // MARK: - Helpers

    private static func externalSeries(_ rows: [HealthSample]?) -> [HealthSourceSeries] {
        // Les écritures de Loop sont une copie du bracelet : le bracelet est déjà compté via son flux.
        HealthSourceSeries.grouped(rows ?? []).filter { $0.source != .whoop }
    }

    /// Moyenne par minute : la FC bracelet 1 Hz (≈86 400 points/jour) ramenée à ≤ 1 440 points.
    private static func perMinute(_ points: [HealthMeasurePoint]) -> [HealthMeasurePoint] {
        var sums: [Double: (Double, Int)] = [:]
        for p in points {
            let minute = (p.start.timeIntervalSince1970 / 60).rounded(.down) * 60
            let acc = sums[minute] ?? (0, 0)
            sums[minute] = (acc.0 + p.value, acc.1 + 1)
        }
        return sums.keys.sorted().map { m in
            let (sum, n) = sums[m]!
            return HealthMeasurePoint(at: Date(timeIntervalSince1970: m), value: sum / Double(n))
        }
    }

    private static func shareList(_ counts: [HealthDataSource: Int]) -> [HealthDaySourceShare] {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return [] }
        return counts.sorted { $0.value > $1.value }
            .map { HealthDaySourceShare(source: $0.key, fraction: Double($0.value) / Double(total)) }
    }

    private static func sourceShares(_ counts: [HealthDataSource: Int]) -> String? {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }
        let sorted = counts.sorted { $0.value > $1.value }
        if sorted.count == 1 { return sorted[0].key.label }
        return sorted.map { "\($0.key.label) \(Int((Double($0.value) / Double(total) * 100).rounded())) %" }
            .joined(separator: " · ")
    }

    /// Accord bracelet / Watch en priorité, sinon la première paire disponible.
    private static func agreementText(_ merged: HealthMergedSeries, unit: String, slot: String?) -> String? {
        let pair = merged.agreement(.whoop, .appleWatch) ?? merged.agreements.first
        guard let pair, pair.pairCount > 0 else { return nil }
        let diff = pair.medianAbsoluteDifference
        let value = diff >= 10 ? String(Int(diff.rounded())) : String(format: "%.1f", diff)
        let context = slot.map { " (\(pair.pairCount) \($0))" } ?? ""
        return String(format: String(localized: "health.report.median", table: "Core"), pair.first.label, pair.second.label, value, unit, context)
    }

    private static func unionSeconds(_ list: [(Double, Double)]) -> Double {
        let sorted = list.sorted { $0.0 < $1.0 }
        var total = 0.0
        var current: (Double, Double)?
        for iv in sorted {
            if let c = current, iv.0 <= c.1 {
                current = (c.0, max(c.1, iv.1))
            } else {
                if let c = current { total += c.1 - c.0 }
                current = iv
            }
        }
        if let c = current { total += c.1 - c.0 }
        return total
    }

    private static func duration(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    private static func unitLabel(_ kind: HealthSampleKind) -> String {
        switch kind {
        case .stepCount: return String(localized: "health.report.steps", table: "Core")
        case .activeEnergyBurned, .basalEnergyBurned: return "kcal"
        case .distanceWalkingRunning: return "m"
        case .appleExerciseTime: return "min"
        case .vo2Max: return "mL/kg/min"
        case .bodyMass: return "kg"
        case .heartRate, .restingHeartRate: return "bpm"
        case .heartRateVariabilitySDNN: return "ms"
        case .sleepAnalysis: return "min"
        }
    }

    private static func format(_ v: Double, kind: HealthSampleKind) -> String {
        switch kind {
        case .stepCount: return String(format: String(localized: "health.report.steps.value", table: "Core"), Int(v.rounded()).formatted())
        case .activeEnergyBurned, .basalEnergyBurned: return "\(Int(v.rounded())) kcal"
        case .distanceWalkingRunning: return String(format: "%.1f km", v / 1000)
        case .appleExerciseTime: return "\(Int(v.rounded())) min"
        case .vo2Max: return String(format: "%.1f mL/kg/min", v)
        case .bodyMass: return String(format: "%.1f kg", v)
        default: return String(format: "%.0f", v)
        }
    }

    private static func sportTitle(_ a: HealthMergedActivity) -> String {
        if let raw = a.members.compactMap(\.sportType).first, let name = sportNames[raw] { return name }
        return a.primary.source == .whoop ? String(localized: "workout.sport.detectedCardio", table: "Core") : String(localized: "health.report.workout", table: "Core")
    }

    /// `HKWorkoutActivityType.rawValue` → libellé, pour les sports courants.
    private static let sportNames: [Int: String] = [
        6: String(localized: "health.sport.basketball", table: "Core"), 8: String(localized: "health.sport.boxing", table: "Core"), 9: String(localized: "health.sport.climbing", table: "Core"), 11: "Cross training", 13: String(localized: "health.sport.cycling", table: "Core"), 16: String(localized: "health.sport.elliptical", table: "Core"),
        20: String(localized: "health.sport.functional", table: "Core"), 24: String(localized: "health.sport.hike", table: "Core"), 28: String(localized: "health.sport.martialArts", table: "Core"), 35: String(localized: "health.sport.rowing", table: "Core"), 37: String(localized: "health.sport.run", table: "Core"),
        41: "Football", 46: String(localized: "health.sport.swim", table: "Core"), 48: "Tennis", 50: String(localized: "health.sport.strength", table: "Core"), 52: String(localized: "health.sport.walk", table: "Core"), 57: "Yoga",
        59: String(localized: "health.sport.core", table: "Core"), 63: "HIIT", 64: String(localized: "health.sport.jumpRope", table: "Core"), 66: "Pilates", 73: String(localized: "health.sport.mixedCardio", table: "Core"), 79: "Pickleball",
        3000: String(localized: "health.sport.otherSport", table: "Core")
    ]
}
