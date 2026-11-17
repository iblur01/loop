import Foundation
import WhoopStore
import LoopStrapEngine

// MARK: - Réconciliation multi-sources (pur, sans HealthKit, sans I/O)
//
// Loop reçoit les mêmes grandeurs de plusieurs capteurs : le bracelet (WHOOP, calcul local) et
// Apple Santé (Apple Watch, iPhone, apps tierces). L'utilisateur porte parfois les deux, parfois
// un seul. Cette couche RECOUPE les sources au lieu d'en garder une :
// - les lignes sources ne sont jamais modifiées ni jetées ; la vue fusionnée se calcule à la lecture ;
// - chaque valeur fusionnée indique la source retenue (pas de trou silencieux) ;
// - quand deux sources couvrent le même intervalle, un indicateur d'accord est produit.

/// Source d'une mesure ou d'une séance. `rawValue` est persisté (réglages) : ne pas renommer.
enum HealthDataSource: String, CaseIterable, Codable, Sendable {
    /// Bracelet WHOOP, flux local Loop (ou échantillon Santé écrit par Loop lui-même).
    case whoop
    /// Apple Watch, via Apple Santé.
    case appleWatch
    /// Toute autre source Apple Santé (iPhone, apps tierces).
    case healthKit

    var label: String {
        switch self {
        case .whoop: return String(localized: "health.source.band", table: "Core")
        case .appleWatch: return "Apple Watch"
        case .healthKit: return String(localized: "health.source.apple", table: "Core")
        }
    }

    /// Classe une ligne Apple Santé. Signature historique : sans identité matérielle, repli sur le
    /// nom de la source ("Apple Watch de …") et le marqueur d'origine pour les écritures de Loop.
    static func classify(sourceName: String?, metadataOrigin: String? = nil) -> HealthDataSource {
        classify(sourceName: sourceName, metadataOrigin: metadataOrigin, sourceBundle: nil,
                 productType: nil, deviceModel: nil)
    }

    /// Classification réservée aux pas : les métadonnées matérielles priment sur le nom.
    static func classifySteps(sourceName: String?, metadataOrigin: String?, sourceBundle: String?, productType: String?, deviceModel: String?) -> HealthDataSource? {
        let bundle = sourceBundle?.lowercased() ?? ""
        let name = sourceName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if metadataOrigin == HealthSampleMapping.loopOrigin || bundle.contains("whoop") || name == "whoop" || name == "loop" { return .whoop }
        func category(_ value: String?) -> HealthDataSource? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else { return nil }
            if value.hasPrefix("iphone") { return .healthKit }
            if value.hasPrefix("watch") || value.hasPrefix("apple watch") { return .appleWatch }
            return nil
        }
        if let source = category(productType) { return source }
        if let source = category(deviceModel) { return source }
        if name.contains("iphone") { return .healthKit }
        if name.contains("watch") { return .appleWatch }
        return nil
    }

    /// Classe une ligne Apple Santé en privilégiant l'identité matérielle stable au nom affiché,
    /// localisé et renommable. Apple Watch = données natives Apple produites sur la montre
    /// (bundle `com.apple.`) : une app tierce qui tourne sur la montre n'est pas fusionnée avec
    /// elles et garde le repli historique sur le nom. Lignes d'avant v15 : repli sur le nom.
    static func classify(sourceName: String?, metadataOrigin: String?, sourceBundle: String?,
                         productType: String?, deviceModel: String?) -> HealthDataSource {
        if metadataOrigin == HealthSampleMapping.loopOrigin { return .whoop }
        let appleBundle = sourceBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("com.apple.") == true
        if let product = productType?.trimmingCharacters(in: .whitespacesAndNewlines), !product.isEmpty {
            if product.hasPrefix("iPhone") || product.hasPrefix("iPad") { return .healthKit }
            if product.hasPrefix("Watch") && appleBundle { return .appleWatch }
        } else if deviceModel?.trimmingCharacters(in: .whitespacesAndNewlines) == "Watch" && appleBundle {
            return .appleWatch
        }
        if let name = sourceName?.lowercased(), name.contains("watch") { return .appleWatch }
        return .healthKit
    }
}

/// Contexte physiologique d'un intervalle : la priorité de source peut en dépendre (FC).
enum HealthMeasureContext: String, CaseIterable, Codable, Sendable {
    case sleep
    case rest
    case activity
}

/// Intervalles connus de sommeil et d'activité, fournis par l'appelant (sessions de sommeil du
/// bracelet, séances fusionnées). Tout le reste est considéré comme repos.
struct HealthContextTimeline: Equatable, Sendable {
    var sleep: [DateInterval]
    var activity: [DateInterval]

    static let empty = HealthContextTimeline(sleep: [], activity: [])

    init(sleep: [DateInterval] = [], activity: [DateInterval] = []) {
        self.sleep = sleep
        self.activity = activity
    }

    /// Contexte au milieu de l'intervalle. Le sommeil l'emporte sur l'activité en cas de recouvrement.
    func context(for start: Date, end: Date) -> HealthMeasureContext {
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        if sleep.contains(where: { $0.contains(mid) }) { return .sleep }
        if activity.contains(where: { $0.contains(mid) }) { return .activity }
        return .rest
    }
}

// MARK: - Priorité configurable

/// Ordre des sources par type de mesure (et par contexte pour les types qui le distinguent).
/// Une source absente de l'ordre n'est jamais retenue comme valeur fusionnée, mais elle reste
/// comparée dans l'indicateur d'accord.
struct HealthSourcePriority: Equatable, Sendable {
    /// Clé : `HealthSampleKind.rawValue` ou `"<kind>.<context>"` pour une surcharge par contexte.
    var orders: [String: [HealthDataSource]]
    /// Ordre pour la fusion des séances (durée et bornes viennent de la première source présente).
    var workouts: [HealthDataSource]
    /// Ordre pour tout type sans entrée explicite.
    var fallback: [HealthDataSource]

    static let defaultFallback: [HealthDataSource] = [.appleWatch, .healthKit, .whoop]

    /// Valeurs par défaut :
    /// - FC pendant le sommeil et au repos : bracelet d'abord (porté en continu, calibré pour la nuit) ;
    /// - FC en activité : Apple Watch d'abord (capteur au poignet plus réactif en effort), puis bracelet ;
    /// - FC repos : bracelet d'abord ;
    /// - VFC : Apple Santé uniquement par défaut — la VFC Santé est un SDNN, celle du bracelet un RMSSD :
    ///   les fusionner mélangerait deux grandeurs différentes ;
    /// - séances : Apple Watch d'abord (démarrage/arrêt explicites), puis bracelet (détection auto) ;
    /// - autres types : Apple Watch, puis autres sources Santé, puis bracelet.
    static let `default` = HealthSourcePriority(
        orders: [
            key(.heartRate, .sleep): [.whoop, .appleWatch, .healthKit],
            key(.heartRate, .rest): [.whoop, .appleWatch, .healthKit],
            key(.heartRate, .activity): [.appleWatch, .whoop, .healthKit],
            HealthSampleKind.restingHeartRate.rawValue: [.whoop, .appleWatch, .healthKit],
            HealthSampleKind.heartRateVariabilitySDNN.rawValue: [.appleWatch, .healthKit]
        ],
        workouts: [.appleWatch, .whoop, .healthKit],
        fallback: defaultFallback)

    static func key(_ kind: HealthSampleKind, _ context: HealthMeasureContext? = nil) -> String {
        guard let context else { return kind.rawValue }
        return "\(kind.rawValue).\(context.rawValue)"
    }

    /// Ordre effectif : surcharge par contexte, sinon par type, sinon `fallback`.
    func order(for kind: HealthSampleKind, context: HealthMeasureContext) -> [HealthDataSource] {
        orders[Self.key(kind, context)] ?? orders[Self.key(kind)] ?? fallback
    }
}

// MARK: - Validation

/// Plages plausibles par type. Hors plage = échantillon ignoré, sans erreur.
enum HealthPlausibility {
    static func range(for kind: HealthSampleKind) -> ClosedRange<Double> {
        switch kind {
        case .heartRate: return 25...250
        case .restingHeartRate: return 25...150
        case .heartRateVariabilitySDNN: return 1...400
        case .stepCount: return 0...100_000
        case .activeEnergyBurned, .basalEnergyBurned: return 0...10_000
        case .distanceWalkingRunning: return 0...300_000
        case .appleExerciseTime: return 0...1_440
        case .vo2Max: return 10...100
        case .bodyMass: return 20...400
        case .sleepAnalysis: return 0...10
        }
    }

    static func isValid(_ point: HealthMeasurePoint, kind: HealthSampleKind) -> Bool {
        guard point.end >= point.start, point.value.isFinite else { return false }
        return range(for: kind).contains(point.value)
    }
}

// MARK: - Séries

/// Un échantillon d'une source (instantané si `start == end`).
struct HealthMeasurePoint: Equatable, Sendable {
    let start: Date
    let end: Date
    let value: Double

    init(start: Date, end: Date, value: Double) {
        self.start = start; self.end = end; self.value = value
    }

    init(at date: Date, value: Double) {
        self.init(start: date, end: date, value: value)
    }
}

/// Toutes les mesures d'un type pour une source.
struct HealthSourceSeries: Equatable, Sendable {
    let source: HealthDataSource
    let points: [HealthMeasurePoint]
    /// Identité de l'application ayant écrit dans Santé, lorsque disponible. Ce n'est pas
    /// nécessairement l'identité du capteur physique ayant produit la mesure.
    var producerID: String? = nil
}

/// Comment agréger plusieurs échantillons d'une même source dans un intervalle.
enum HealthAggregation: Equatable, Sendable {
    /// Grandeur instantanée (FC, VFC, poids…) : moyenne.
    case average
    /// Grandeur cumulative (pas, énergie, distance…) : somme au prorata du recouvrement.
    case sum

    static func `for`(_ kind: HealthSampleKind) -> HealthAggregation {
        switch kind {
        case .stepCount, .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning, .appleExerciseTime:
            return .sum
        default:
            return .average
        }
    }
}

/// Un intervalle de la série fusionnée.
struct HealthMergedBucket: Equatable, Sendable {
    let start: Date
    let end: Date
    let context: HealthMeasureContext
    /// Valeur retenue, ou nil si aucune source prioritaire n'a de valeur valide (trou explicite).
    let value: Double?
    /// Source de `value`, nil seulement quand `value` est nil.
    let source: HealthDataSource?
    /// Valeur agrégée de chaque source présente sur l'intervalle (jamais jetée).
    let candidates: [HealthDataSource: Double]
}

/// Accord entre deux sources sur les intervalles où les deux ont une valeur.
struct HealthSourceAgreement: Equatable, Sendable {
    let first: HealthDataSource
    let second: HealthDataSource
    /// Nombre d'intervalles comparés.
    let pairCount: Int
    /// Médiane de |first − second|, dans l'unité du type.
    let medianAbsoluteDifference: Double
}

struct HealthMergedSeries: Equatable, Sendable {
    let kind: HealthSampleKind
    let buckets: [HealthMergedBucket]
    /// Une entrée par paire de sources ayant au moins un intervalle en commun.
    let agreements: [HealthSourceAgreement]
    /// Échantillons écartés (invalides ou hors plage), pour diagnostic.
    let ignoredPointCount: Int

    /// Nombre d'intervalles fournis par chaque source retenue.
    var bucketsBySource: [HealthDataSource: Int] {
        buckets.reduce(into: [:]) { acc, b in if let s = b.source { acc[s, default: 0] += 1 } }
    }

    func agreement(_ a: HealthDataSource, _ b: HealthDataSource) -> HealthSourceAgreement? {
        agreements.first { ($0.first == a && $0.second == b) || ($0.first == b && $0.second == a) }
    }
}

// MARK: - Cumulés multisources

/// Une contribution agrégée sans perdre l'identité de l'application productrice.
struct HealthCumulativeCandidate: Equatable, Sendable {
    let source: HealthDataSource
    let producerID: String?
    let value: Double
}

/// Concurrence observée ; un conflit non résolu empêche d'annoncer un total complet.
struct HealthCumulativeConflict: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case overlappingProducers
        case instantaneousOverlap
        case unknownProducer
        case tooManySamples
        case sameProducerOverlap
    }
    let start: Date
    let end: Date
    let reason: Reason
    let candidates: [HealthCumulativeCandidate]
    let isResolved: Bool
}

struct HealthCumulativeBucket: Equatable, Sendable {
    let start: Date
    let end: Date
    /// Nil lorsque le cumul est absent ou qu'une ambiguïté empêche un total fiable.
    let value: Double?
    /// Total des seules portions résolues ; ne doit pas être présenté comme un total complet.
    let partialValue: Double?
    let sources: [HealthDataSource]
    /// Producteurs ayant contribué au total complet, jamais les portions partielles.
    let selectedProducerIDs: [String]
    let candidates: [HealthCumulativeCandidate]
    let conflicts: [HealthCumulativeConflict]
    var isIncomplete: Bool { conflicts.contains { !$0.isResolved } }
}

struct HealthCumulativeSeries: Equatable, Sendable {
    let kind: HealthSampleKind
    let buckets: [HealthCumulativeBucket]
    let ignoredPointCount: Int
}

// MARK: - Séances

/// Une séance telle que vue par une source.
struct HealthSourceActivity: Equatable, Sendable {
    let id: String
    let source: HealthDataSource
    let sportType: Int?
    /// Identité de l'application productrice ; distingue les apps tierces dans HealthKit.
    let origin: String?
    let start: Date
    let end: Date
    /// Durée déclarée par la source (peut exclure les pauses) ; sinon `end − start`.
    let durationSec: Double?
    let energyKcal: Double?
    let distanceM: Double?

    init(id: String, source: HealthDataSource, sportType: Int? = nil, start: Date, end: Date,
         durationSec: Double? = nil, energyKcal: Double? = nil, distanceM: Double? = nil,
         origin: String? = nil) {
        self.id = id; self.source = source; self.sportType = sportType; self.origin = origin
        self.start = start; self.end = end; self.durationSec = durationSec
        self.energyKcal = energyKcal; self.distanceM = distanceM
    }

    var effectiveDuration: Double {
        if let d = durationSec, d.isFinite, d > 0 { return d }
        return end.timeIntervalSince(start)
    }
}

/// Une activité fusionnée : une ou plusieurs séances sources qui se recouvrent.
struct HealthMergedActivity: Equatable, Sendable {
    /// Séance de la source prioritaire : bornes, durée et sport en viennent.
    let primary: HealthSourceActivity
    /// Toutes les séances sources contributrices, triées par priorité.
    let members: [HealthSourceActivity]
    let durationSec: Double
    /// Première source (dans l'ordre de priorité) qui fournit la valeur.
    let energyKcal: Double?
    let energySource: HealthDataSource?
    let distanceM: Double?
    let distanceSource: HealthDataSource?

    var start: Date { primary.start }
    var end: Date { primary.end }
    var sources: [HealthDataSource] {
        var seen: [HealthDataSource] = []
        for m in members where !seen.contains(m.source) { seen.append(m.source) }
        return seen
    }
}

// MARK: - Moteur

enum HealthReconciliation {
    /// Deux séances sont la même activité si leur recouvrement couvre au moins cette fraction
    /// de la plus courte des deux.
    static let workoutOverlapThreshold = 0.5

    // MARK: Séances

    /// Complete-link grouping prevents a long candidate from transitively joining distinct sessions.
    static func mergeActivities(_ activities: [HealthSourceActivity],
                                priority: HealthSourcePriority = .default,
                                overlapThreshold: Double = workoutOverlapThreshold) -> [HealthMergedActivity] {
        let valid = activities.filter {
            $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        var groups: [[HealthSourceActivity]] = []
        for activity in valid {
            if let index = groups.firstIndex(where: { group in
                group.allSatisfy { isSameActivity($0, activity, threshold: overlapThreshold) }
            }) {
                groups[index].append(activity)
            } else {
                groups.append([activity])
            }
        }
        return groups.map { mergeGroup($0, order: priority.workouts) }.sorted { $0.start < $1.start }
    }

    static func isSameActivity(_ a: HealthSourceActivity, _ b: HealthSourceActivity,
                               threshold: Double = workoutOverlapThreshold) -> Bool {
        // Distinct recordings by the same producer may be intentionally separate workouts.
        if a.source == b.source {
            guard let x = a.origin?.lowercased(), let y = b.origin?.lowercased(), x != y else { return false }
        }
        if let x = a.sportType, let y = b.sportType, x != y { return false }
        let overlap = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        guard overlap > 0 else { return false }
        let aDuration = a.end.timeIntervalSince(a.start)
        let bDuration = b.end.timeIntervalSince(b.start)
        // Similar coverage of BOTH sessions avoids swallowing a run into a multi-hour detection.
        return overlap >= threshold * min(aDuration, bDuration)
            && overlap >= 0.70 * max(aDuration, bDuration)
    }

    private static func mergeGroup(_ group: [HealthSourceActivity], order: [HealthDataSource]) -> HealthMergedActivity {
        func rank(_ s: HealthDataSource) -> Int { order.firstIndex(of: s) ?? order.count }
        // Priorité, puis séance la plus longue, puis début le plus tôt, puis id (déterministe).
        let sorted = group.sorted {
            if rank($0.source) != rank($1.source) { return rank($0.source) < rank($1.source) }
            if $0.effectiveDuration != $1.effectiveDuration { return $0.effectiveDuration > $1.effectiveDuration }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
        let primary = sorted[0]
        let energy = sorted.first { usable($0.energyKcal) }
        let distance = sorted.first { usable($0.distanceM) }
        return HealthMergedActivity(
            primary: primary,
            members: sorted,
            durationSec: primary.effectiveDuration,
            energyKcal: energy?.energyKcal,
            energySource: energy?.source,
            distanceM: distance?.distanceM,
            distanceSource: distance?.source)
    }

    private static func usable(_ v: Double?) -> Bool {
        guard let v else { return false }
        return v.isFinite && v >= 0
    }

    // MARK: Séries

    /// Fusionne les séries de plusieurs sources sur `[from, to)`, découpé en intervalles de `bucket`
    /// secondes. Par intervalle : chaque source valide est agrégée ; la valeur retenue est celle de
    /// la première source de l'ordre de priorité (selon le type et le contexte) qui a une valeur.
    /// Les intervalles sans aucune valeur restent présents avec `value == nil`.
    static func mergeSeries(kind: HealthSampleKind,
                            series: [HealthSourceSeries],
                            from: Date, to: Date, bucket: TimeInterval,
                            timeline: HealthContextTimeline = .empty,
                            priority: HealthSourcePriority = .default) -> HealthMergedSeries {
        guard to > from, bucket > 0, bucket.isFinite else {
            return HealthMergedSeries(kind: kind, buckets: [], agreements: [], ignoredPointCount: 0)
        }
        let aggregation = HealthAggregation.for(kind)

        var ignored = 0
        var cleaned: [HealthDataSource: [HealthMeasurePoint]] = [:]
        for s in series {
            for p in s.points {
                if HealthPlausibility.isValid(p, kind: kind) {
                    cleaned[s.source, default: []].append(p)
                } else {
                    ignored += 1
                }
            }
        }
        for key in cleaned.keys { cleaned[key]?.sort { $0.start < $1.start } }

        let count = Int((to.timeIntervalSince(from) / bucket).rounded(.up))
        var buckets: [HealthMergedBucket] = []
        buckets.reserveCapacity(count)
        var pairDiffs: [SourcePair: [Double]] = [:]

        for i in 0..<count {
            let bStart = from.addingTimeInterval(Double(i) * bucket)
            let bEnd = min(from.addingTimeInterval(Double(i + 1) * bucket), to)
            var candidates: [HealthDataSource: Double] = [:]
            for (source, points) in cleaned {
                if let v = aggregate(points, start: bStart, end: bEnd, aggregation: aggregation) {
                    candidates[source] = v
                }
            }
            let context = timeline.context(for: bStart, end: bEnd)
            let order = priority.order(for: kind, context: context)
            let chosen = order.first { candidates[$0] != nil }

            let present = HealthDataSource.allCases.filter { candidates[$0] != nil }
            for a in 0..<present.count {
                for b in (a + 1)..<present.count {
                    let diff = abs(candidates[present[a]]! - candidates[present[b]]!)
                    pairDiffs[SourcePair(first: present[a], second: present[b]), default: []].append(diff)
                }
            }

            buckets.append(HealthMergedBucket(
                start: bStart, end: bEnd, context: context,
                value: chosen.flatMap { candidates[$0] },
                source: chosen,
                candidates: candidates))
        }

        let agreements = pairDiffs
            .map { pair, diffs in
                HealthSourceAgreement(first: pair.first, second: pair.second,
                                      pairCount: diffs.count, medianAbsoluteDifference: median(diffs))
            }
            .sorted { ($0.first.order, $0.second.order) < ($1.first.order, $1.second.order) }

        return HealthMergedSeries(kind: kind, buckets: buckets, agreements: agreements, ignoredPointCount: ignored)
    }

    /// Réconcilie les cumulés par portions réelles et conserve les conflits de provenance.
    /// Les identités absentes, les producteurs de même priorité et les instants concurrents
    /// ne permettent pas de déterminer un total complet. Les bornes sont [start, end).
    static func mergeCumulativeSeries(kind: HealthSampleKind,
                                      series: [HealthSourceSeries],
                                      from: Date, to: Date, bucket: TimeInterval,
                                      timeline: HealthContextTimeline = .empty,
                                      priority: HealthSourcePriority = .default,
                                      producerOrder: [String] = []) -> HealthCumulativeSeries {
        guard HealthAggregation.for(kind) == .sum, to > from, bucket > 0, bucket.isFinite else {
            return HealthCumulativeSeries(kind: kind, buckets: [], ignoredPointCount: 0)
        }
        struct Producer: Hashable {
            let source: HealthDataSource
            let id: String?
        }
        var producers: [Producer: [HealthMeasurePoint]] = [:]
        var ignored = 0
        for input in series {
            let key = Producer(source: input.source, id: input.producerID)
            for point in input.points {
                guard HealthPlausibility.isValid(point, kind: kind) else { ignored += 1; continue }
                producers[key, default: []].append(point)
            }
        }
        // A ponctual sample has no accumulation window: it may overlap another producer
        // anywhere in the loaded period, including across bucket boundaries. This cannot
        // detect duplication against data outside [from, to).
        let periodPoints = producers.compactMapValues { points -> [HealthMeasurePoint]? in
            let filtered = points.filter {
                $0.start == $0.end ? $0.start >= from && $0.start < to : $0.start < to && $0.end > from
            }
            return filtered.isEmpty ? nil : filtered
        }
        let periodPointProducers = Set(periodPoints.compactMap { key, points in
            points.contains { $0.start == $0.end } ? key : nil
        })
        let periodCandidates: [HealthCumulativeCandidate] = periodPoints.compactMap { key, points in
            guard let value = aggregate(points.sorted { $0.start < $1.start }, start: from, end: to, aggregation: .sum) else { return nil }
            return HealthCumulativeCandidate(source: key.source, producerID: key.id, value: value)
        }.sorted {
            if $0.source.order != $1.source.order { return $0.source.order < $1.source.order }
            return ($0.producerID ?? "") < ($1.producerID ?? "")
        }
        let count = Int((to.timeIntervalSince(from) / bucket).rounded(.up))
        var result: [HealthCumulativeBucket] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let start = from.addingTimeInterval(Double(index) * bucket)
            let end = min(from.addingTimeInterval(Double(index + 1) * bucket), to)
            let order = priority.order(for: kind, context: timeline.context(for: start, end: end))
            func rank(_ producer: Producer) -> Int { order.firstIndex(of: producer.source) ?? order.count }
            // Explicit app choices precede category defaults, but never enable an excluded category.
            // Names are not stable identities; only bundle IDs can resolve a producer conflict.
            func explicitRank(_ producer: Producer) -> Int? {
                guard let id = producer.id, id.hasPrefix("bundle:"), id.count > "bundle:".count else { return nil }
                return producerOrder.firstIndex(of: id)
            }
            func preferred(_ keys: [Producer]) -> [Producer] {
                let explicitlyRanked = keys.compactMap(explicitRank)
                if let best = explicitlyRanked.min() { return keys.filter { explicitRank($0) == best } }
                guard let best = keys.map(rank).min() else { return [] }
                return keys.filter { rank($0) == best }
            }
            func sorted(_ keys: [Producer]) -> [Producer] {
                keys.sorted { a, b in
                    if rank(a) != rank(b) { return rank(a) < rank(b) }
                    if a.source.order != b.source.order { return a.source.order < b.source.order }
                    return (a.id ?? "") < (b.id ?? "")
                }
            }
            let local = producers.compactMapValues { points -> [HealthMeasurePoint]? in
                let matches = points.filter { point in
                    point.start == point.end ? point.start >= start && point.start < end
                        : point.start < end && point.end > start
                }
                return matches.isEmpty ? nil : matches
            }
            let allKeys = sorted(Array(local.keys))
            // Excluded categories stay visible as candidates but cannot invalidate a selected total.
            let keys = allKeys.filter { rank($0) < order.count }
            let periodHasAmbiguousInstant = periodPointProducers.contains { pointKey in
                rank(pointKey) < order.count && periodPoints.keys.contains {
                    $0 != pointKey && rank($0) < order.count
                }
            }
            func values(_ keys: [Producer], start: Date, end: Date) -> [HealthCumulativeCandidate] {
                keys.compactMap { key in
                    guard let points = local[key], let value = aggregate(points.sorted { $0.start < $1.start },
                        start: start, end: end, aggregation: .sum) else { return nil }
                    return HealthCumulativeCandidate(source: key.source, producerID: key.id, value: value)
                }
            }
            let candidates = values(allKeys, start: start, end: end)
            var globalConflicts: [HealthCumulativeConflict] = []
            if periodHasAmbiguousInstant && !keys.isEmpty {
                globalConflicts.append(HealthCumulativeConflict(start: from, end: to,
                    reason: .instantaneousOverlap,
                    candidates: periodCandidates.filter { order.contains($0.source) }, isResolved: false))
            }
            // A bundle names an app, not a physical device. Overlapping samples from the
            // same writer can therefore be duplicate measurements from separate devices.
            var stepIntervalOverlap = false
            for key in keys {
                let intervals = local[key]!.filter { $0.start < $0.end }.sorted { $0.start < $1.start }
                var latestEnd: Date?
                var overlaps = false
                for point in intervals {
                    if let previousEnd = latestEnd, point.start < previousEnd { overlaps = true; break }
                    latestEnd = max(latestEnd ?? point.end, point.end)
                }
                let hasInstant = local[key]!.contains { $0.start == $0.end }
                if kind == .stepCount && overlaps && !hasInstant { stepIntervalOverlap = true }
                if (overlaps && keys.count == 1 && (kind != .stepCount || hasInstant)) || (hasInstant && !intervals.isEmpty) {
                    let own = candidates.filter { $0.source == key.source && $0.producerID == key.id }
                    globalConflicts.append(HealthCumulativeConflict(start: start, end: end,
                        reason: .sameProducerOverlap, candidates: own, isResolved: false))
                }
            }
            if keys.count == 1, !stepIntervalOverlap, let key = keys.first,
               let candidate = candidates.first(where: { $0.source == key.source && $0.producerID == key.id }) {
                let unknown = key.id == nil
                let eligible = rank(key) < order.count
                if unknown {
                    globalConflicts.append(HealthCumulativeConflict(start: start, end: end, reason: .unknownProducer,
                        candidates: candidates, isResolved: false))
                }
                let complete = globalConflicts.isEmpty && eligible
                result.append(HealthCumulativeBucket(start: start, end: end,
                    value: complete ? candidate.value : nil,
                    partialValue: complete ? candidate.value : nil,
                    sources: complete ? [key.source] : [],
                    selectedProducerIDs: complete ? key.id.map { [$0] } ?? [] : [], candidates: candidates,
                    conflicts: globalConflicts))
                continue
            }
            // Éviter un coût quadratique sur un historique dense : mieux vaut signaler
            // l'incertitude que figer l'application ou annoncer un total non vérifié.
            if (keys.count > 1 || stepIntervalOverlap) && keys.reduce(0, { $0 + local[$1]!.count }) > 256 {
                let conflict = HealthCumulativeConflict(start: start, end: end,
                    reason: .tooManySamples, candidates: candidates, isResolved: false)
                result.append(HealthCumulativeBucket(start: start, end: end, value: nil,
                    partialValue: nil, sources: [], selectedProducerIDs: [], candidates: candidates, conflicts: [conflict]))
                continue
            }
            var boundaries = Set([start, end])
            for key in keys {
                for point in local[key]! where point.start < point.end {
                    boundaries.insert(max(start, point.start)); boundaries.insert(min(end, point.end))
                }
            }
            let boundariesSorted = boundaries.sorted()
            var partial = 0.0
            var hasPartial = false
            var chosenSources: Set<HealthDataSource> = []
            var chosenProducerIDs: Set<String> = []
            var conflicts: [HealthCumulativeConflict] = globalConflicts
            for (left, right) in zip(boundariesSorted, boundariesSorted.dropFirst()) where left < right {
                let active = keys.filter { key in
                    local[key]!.contains { $0.start < $0.end && $0.start < right && $0.end > left }
                }
                guard !active.isEmpty else { continue }
                let candidateValues = active.compactMap { key -> HealthCumulativeCandidate? in
                    let intervals = local[key]!.filter { $0.start < $0.end }.sorted { $0.start < $1.start }
                    guard let value = aggregate(intervals, start: left, end: right, aggregation: .sum) else { return nil }
                    return HealthCumulativeCandidate(source: key.source, producerID: key.id, value: value)
                }
                let eligible = active.filter { rank($0) < order.count }
                let chosen = preferred(eligible)
                let unknown = active.contains { $0.id == nil }
                let fragileIdentity = !producerOrder.isEmpty && active.count > 1 && active.contains { $0.id?.hasPrefix("name:") == true }
                // Overlaps inside a producer only affect the portions where that producer
                // would actually contribute. A lower-priority source covered by a selected
                // source cannot make that selected measurement ambiguous.
                let selectedOverlap = chosen.contains { key in
                    local[key]!.filter { $0.start < $0.end && $0.start < right && $0.end > left }.count > 1
                }
                let unresolved = unknown || fragileIdentity || chosen.count > 1 || selectedOverlap
                if selectedOverlap {
                    conflicts.append(HealthCumulativeConflict(start: left, end: right,
                        reason: .sameProducerOverlap,
                        candidates: candidateValues.filter { candidate in chosen.contains { $0.source == candidate.source && $0.id == candidate.producerID } },
                        isResolved: false))
                }
                if active.count > 1 || unknown {
                    conflicts.append(HealthCumulativeConflict(start: left, end: right,
                        reason: unknown ? .unknownProducer : .overlappingProducers,
                        candidates: candidateValues, isResolved: !unresolved))
                }
                if !unresolved, let key = chosen.first,
                   let candidate = candidateValues.first(where: { $0.source == key.source && $0.producerID == key.id }) {
                    partial += candidate.value; hasPartial = true; chosenSources.insert(key.source)
                    if let id = key.id { chosenProducerIDs.insert(id) }
                }
            }
            let instantTimes = Set(keys.flatMap { local[$0]!.filter { $0.start == $0.end }.map(\.start) }).sorted()
            for time in instantTimes {
                let instantKeys = keys.filter { key in local[key]!.contains { $0.start == time && $0.end == time } }
                let covering = keys.filter { key in local[key]!.contains { $0.start < $0.end && $0.start <= time && time < $0.end } }
                let competing = covering.contains { !instantKeys.contains($0) }
                let eligible = instantKeys.filter { rank($0) < order.count }
                let chosen = preferred(eligible)
                let unknown = (instantKeys + covering).contains { $0.id == nil }
                let unresolved = unknown || competing || chosen.count > 1
                let instantCandidates = instantKeys.map { key in
                    HealthCumulativeCandidate(source: key.source, producerID: key.id,
                        value: local[key]!.filter { $0.start == time && $0.end == time }.reduce(0) { $0 + $1.value })
                }
                if unresolved || instantKeys.count > 1 {
                    let coveringCandidates = covering.compactMap { key in candidates.first { $0.source == key.source && $0.producerID == key.id } }
                    conflicts.append(HealthCumulativeConflict(start: time, end: time,
                        reason: unknown ? .unknownProducer : .instantaneousOverlap,
                        candidates: instantCandidates + coveringCandidates, isResolved: !unresolved))
                }
                if !unresolved, let key = chosen.first,
                   let candidate = instantCandidates.first(where: { $0.source == key.source && $0.producerID == key.id }) {
                    partial += candidate.value; hasPartial = true; chosenSources.insert(key.source)
                    if let id = key.id { chosenProducerIDs.insert(id) }
                }
            }
            // Un point ne décrit pas sa fenêtre d'accumulation. Même éloigné d'un autre
            // échantillon dans le créneau, il peut représenter la même activité.
            let pointProducers = keys.filter { key in local[key]!.contains { $0.start == $0.end } }
            if pointProducers.contains(where: { pointKey in keys.contains { $0 != pointKey } }) {
                conflicts.append(HealthCumulativeConflict(start: start, end: end,
                    reason: .instantaneousOverlap, candidates: candidates, isResolved: false))
            }
            let incomplete = conflicts.contains { !$0.isResolved }
            result.append(HealthCumulativeBucket(start: start, end: end,
                value: hasPartial && !incomplete ? partial : nil,
                partialValue: hasPartial ? partial : nil,
                sources: HealthDataSource.allCases.filter { chosenSources.contains($0) },
                selectedProducerIDs: incomplete ? [] : chosenProducerIDs.sorted(),
                candidates: candidates, conflicts: conflicts))
        }
        return HealthCumulativeSeries(kind: kind, buckets: result, ignoredPointCount: ignored)
    }

    /// Accord entre deux séries déjà alignées (mêmes intervalles), hors fusion.
    static func agreement(_ a: [Double?], _ b: [Double?]) -> (pairCount: Int, medianAbsoluteDifference: Double)? {
        let diffs = zip(a, b).compactMap { x, y -> Double? in
            guard let x, let y, x.isFinite, y.isFinite else { return nil }
            return abs(x - y)
        }
        guard !diffs.isEmpty else { return nil }
        return (diffs.count, median(diffs))
    }

    // MARK: Helpers

    private struct SourcePair: Hashable {
        let first: HealthDataSource
        let second: HealthDataSource
    }

    private static func aggregate(_ points: [HealthMeasurePoint], start: Date, end: Date,
                                  aggregation: HealthAggregation) -> Double? {
        var sum = 0.0
        var count = 0
        for p in points {
            if p.start >= end { break }
            let isInstant = p.end == p.start
            if isInstant {
                guard p.start >= start, p.start < end else { continue }
                sum += p.value
                count += 1
                continue
            }
            let overlap = min(p.end, end).timeIntervalSince(max(p.start, start))
            guard overlap > 0 else { continue }
            switch aggregation {
            case .average:
                sum += p.value
            case .sum:
                sum += p.value * overlap / p.end.timeIntervalSince(p.start)
            }
            count += 1
        }
        guard count > 0 else { return nil }
        return aggregation == .average ? sum / Double(count) : sum
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}

private extension HealthDataSource {
    var order: Int { HealthDataSource.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - Adaptateurs depuis le stockage

extension HealthDataSource {
    /// Classement unique d'une séance Santé, partagé par le rapport (`HealthSourceActivity`) et la
    /// projection canonique (`HealthWorkoutCanonicalizer`) pour qu'ils retiennent la même séance.
    /// Une saisie manuelle (`ManualWorkout.sourceBundle`) est toujours « autre source » : ni
    /// Apple Watch, ni bracelet, quel que soit son nom.
    static func classify(_ w: ExternalWorkout) -> HealthDataSource {
        if ManualWorkout.isManual(w) { return .healthKit }
        return classify(sourceName: w.sourceName, metadataOrigin: nil, sourceBundle: w.sourceBundle,
                 productType: w.productType, deviceModel: w.deviceModel)
    }
}

extension WorkoutSourcePriority {
    /// Équivalent de `classify(sourceName:recorded:)` fondé sur la même identité que
    /// `HealthDataSource.classify(_:)` : Apple Watch seulement si la catégorie Santé l'est, puis
    /// Strava d'après le nom, sinon autre source Santé. Sans identité stockée, résultat inchangé.
    /// Saisie manuelle : `.otherHealth`. Une séance montre ou Strava qui la recoupe (même sport,
    /// règle 50 % / 70 %) reste primaire — bornes et FC plus fiables — et l'absorbe ; face à une
    /// détection bracelet, la saisie l'emporte (le bracelet est toujours dernier).
    static func classify(_ w: ExternalWorkout) -> WorkoutSource {
        if ManualWorkout.isManual(w) { return .otherHealth }
        if HealthDataSource.classify(w) == .appleWatch { return .appleWatch }
        if (w.sourceName?.lowercased() ?? "").contains("strava") { return .strava }
        return .otherHealth
    }
}

extension HevyImport {
    /// Producteur d'une séance pour la fusion. Une ligne importée d'un export CSV Hevy porte
    /// l'origine `HevyImport.sourceBundle`, distincte du nom « Hevy » qu'écrit l'app Hevy dans
    /// Apple Santé : la même séance vue par les deux chemins est alors fusionnée par la règle
    /// 50 % / 70 % (la plus longue retenue, les deux étant « autre source »), alors que deux
    /// séances du même chemin restent deux séances voulues.
    static func canonicalOrigin(_ w: ExternalWorkout) -> String? {
        isHevy(w) ? sourceBundle : w.sourceName
    }
}

extension HealthSourceActivity {
    /// Séance importée d'Apple Santé (`external_workout`).
    init(_ w: ExternalWorkout) {
        self.init(id: w.id,
                  source: HealthDataSource.classify(w),
                  sportType: w.sportType,
                  start: Date(timeIntervalSince1970: w.startDate),
                  end: Date(timeIntervalSince1970: w.endDate),
                  durationSec: w.durationSec,
                  energyKcal: w.energyKcal,
                  distanceM: w.distanceM,
                  origin: HevyImport.canonicalOrigin(w))
    }
}

extension HealthSourceSeries {
    /// Regroupement historique par catégorie : les appelants existants, notamment le calcul de
    /// FC, doivent conserver leurs règles de priorité tant que l'arbitrage producteur n'existe pas.
    static func grouped(_ samples: [HealthSample]) -> [HealthSourceSeries] {
        var bySource: [HealthDataSource: [HealthMeasurePoint]] = [:]
        for sample in samples {
            guard let value = sample.value else { continue }
            let source = HealthDataSource.classify(sourceName: sample.sourceName, metadataOrigin: sample.metadataOrigin,
                                                   sourceBundle: sample.sourceBundle,
                                                   productType: sample.productType, deviceModel: sample.deviceModel)
            bySource[source, default: []].append(HealthMeasurePoint(
                start: Date(timeIntervalSince1970: sample.startDate),
                end: Date(timeIntervalSince1970: sample.endDate), value: value))
        }
        return HealthDataSource.allCases.compactMap { source in
            bySource[source].map { HealthSourceSeries(source: source, points: $0) }
        }
    }

    /// Conserve séparément les producteurs d'une même catégorie. La fusion actuelle continue
    /// d'agréger par catégorie : l'identité seule ne permet pas de résoudre les chevauchements.
    static func groupedByProducer(_ samples: [HealthSample], stepsOnly: Bool = false) -> [HealthSourceSeries] {
        struct Key: Hashable {
            let source: HealthDataSource
            let producerID: String?
        }
        var bySource: [Key: [HealthMeasurePoint]] = [:]
        for s in samples {
            guard let v = s.value else { continue }
            let stepSource = stepsOnly ? HealthDataSource.classifySteps(sourceName: s.sourceName, metadataOrigin: s.metadataOrigin, sourceBundle: s.sourceBundle,
                                                                        productType: s.productType, deviceModel: s.deviceModel) : nil
            let source = stepsOnly ? (stepSource ?? .healthKit) : HealthDataSource.classify(sourceName: s.sourceName, metadataOrigin: s.metadataOrigin,
                                                   sourceBundle: s.sourceBundle,
                                                   productType: s.productType, deviceModel: s.deviceModel)
            let bundle = s.sourceBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = s.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let producerID: String?
            if stepsOnly && stepSource == nil {
                producerID = nil
            } else if let bundle, !bundle.isEmpty {
                producerID = "bundle:" + bundle.lowercased()
            } else if let name, !name.isEmpty {
                producerID = "name:" + name.lowercased()
            } else if stepsOnly, let stepSource, stepSource != .whoop {
                producerID = "device:" + stepSource.rawValue
            } else {
                producerID = nil
            }
            let key = Key(source: source, producerID: producerID)
            bySource[key, default: []].append(HealthMeasurePoint(
                start: Date(timeIntervalSince1970: s.startDate),
                end: Date(timeIntervalSince1970: s.endDate),
                value: v))
        }
        return bySource.keys.sorted {
            if $0.source != $1.source { return $0.source.order < $1.source.order }
            return ($0.producerID ?? "") < ($1.producerID ?? "")
        }.compactMap { key in
            bySource[key].map { HealthSourceSeries(source: key.source, points: $0, producerID: key.producerID) }
        }
    }
}

/// Projection canonique utilisée par la timeline et le calcul. La règle (doublons Santé, faux
/// départs, détection bracelet absorbée) et la priorité unique des sources vivent dans
/// `WorkoutCanonicalization` / `WorkoutSourcePriority` (LoopStrapEngine, testées). Les lignes
/// d'origine restent intactes dans le store : seule la vue dérivée est fusionnée.
enum HealthWorkoutCanonicalizer {
    static func merge(band: [WorkoutSession], external: [ExternalWorkout]) -> [WorkoutSession] {
        let externalByID = Dictionary(external.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bandByID = Dictionary(band.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = external.map { w in
            WorkoutCandidate(id: w.id, source: WorkoutSourcePriority.classify(w),
                             origin: HevyImport.canonicalOrigin(w), sportType: w.sportType,
                             start: w.startDate, end: w.endDate)
        } + band.map { w in
            WorkoutCandidate(id: w.id, source: .band, start: Double(w.startTs), end: Double(w.endTs))
        }
        var result: [WorkoutSession] = []
        for group in WorkoutCanonicalization.canonicalize(candidates) {
            guard group.primary.source != .band else {
                if let w = bandByID[group.primary.id] { result.append(w) }
                continue
            }
            guard let w = externalByID[group.primary.id] else { continue }
            let recorded = group.members.compactMap { externalByID[$0.id] }
            func usable(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
            let sportType = group.sportType ?? w.sportType
            result.append(WorkoutSession(deviceId: "healthkit", startTs: Int(w.startDate), endTs: Int(w.endDate),
                                         avgHr: nil, peakHr: nil, strain: nil,
                                         kind: kind(for: sportType), durationS: Int(w.durationSec.rounded()),
                                         caloriesKcal: recorded.lazy.compactMap { usable($0.energyKcal) }.first,
                                         sportType: sportType,
                                         distanceM: recorded.lazy.compactMap { usable($0.distanceM) }.first,
                                         sourceName: w.sourceName, externalID: w.id))
        }
        return result.sorted { $0.startTs == $1.startTs ? $0.id < $1.id : $0.startTs < $1.startTs }
    }

    static func kind(for type: Int) -> String {
        switch type {
        case 6: return "basketball"
        case 8: return "boxing"
        case 9: return "climbing"
        case 11: return "crossfit"
        case 13: return "cycling"
        case 16: return "elliptical"
        case 20: return "functionalfitness"
        case 24: return "hiking"
        case 28: return "martial arts"
        case 35: return "rowing"
        case 37: return "running"
        case 41: return "football"
        case 46: return "swimming"
        case 48: return "tennis"
        case 50: return "strength"
        case 52: return "walking"
        case 57: return "yoga"
        case 59: return "core training"
        case 63: return "hiit"
        case 64: return "jump rope"
        case 66: return "pilates"
        case 73: return "mixed cardio"
        case 79: return "pickleball"
        default: return "Séance Apple Santé"
        }
    }
}

/// Résumé de repli pour une nuit Santé catégorisée. Ne mélange jamais plusieurs sources,
/// n'invente aucun stade pour les segments « au lit » ou « sommeil non spécifié », et ne
/// convertit pas le SDNN HealthKit en RMSSD bracelet.
enum HealthSleepAdapter {
    struct Result {
        let summary: DailySleepSummary
        let session: SleepSession
        let stagesComplete: Bool
        /// Source classée une fois à partir de l'identité stockée (productType, bundle, nom) ;
        /// les appelants l'utilisent au lieu de reclasser par le seul nom de la session.
        let source: HealthDataSource
    }
    private struct Segment: Codable {
        let start: Double
        let end: Double
        let stage: String
    }

    /// `endWindow` = exact `[from, to)` bounds of the local day (app policy). Without it the
    /// night is attributed by its UTC end date (legacy callers and fixtures only).
    static func summaries(samples: [HealthSample], date: String,
                          priority: HealthSourcePriority = .default,
                          endWindow: (from: Double, to: Double)? = nil) -> Result? {
        let eligible = samples.filter {
            $0.type == HealthSampleKind.sleepAnalysis.rawValue && $0.metadataOrigin != HealthSampleMapping.loopOrigin
                && $0.startDate.isFinite && $0.endDate.isFinite && $0.endDate > $0.startDate
                && $0.value.map { [1.0, 2.0, 3.0, 4.0, 5.0].contains($0) } == true
        }
        let sources = Dictionary(grouping: eligible) { ($0.sourceBundle ?? "") + "|" + ($0.sourceName ?? "") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        let order = priority.order(for: .sleepAnalysis, context: .sleep)
        var candidates: [(source: String, rank: Int, segments: [HealthSample], sleep: Double,
                          kind: HealthDataSource)] = []
        for (source, rows) in sources {
            let sorted = rows.sorted { $0.startDate == $1.startDate ? $0.endDate < $1.endDate : $0.startDate < $1.startDate }
            var clusters: [[HealthSample]] = []
            for sample in sorted {
                var row = sample
                if let last = clusters.last?.last, row.startDate < last.endDate {
                    // HealthKit timestamps can differ by a floating-point ULP at a shared
                    // boundary. Keep the non-overlapping tail instead of losing the entire
                    // next stage, while still counting genuinely overlapping time only once.
                    guard row.endDate > last.endDate else { continue }
                    row = HealthSample(uuid: row.uuid, type: row.type, startDate: last.endDate,
                                       endDate: row.endDate, value: row.value, unit: row.unit,
                                       sourceName: row.sourceName, sourceBundle: row.sourceBundle,
                                       metadataOrigin: row.metadataOrigin, importedAt: row.importedAt,
                                       productType: row.productType, deviceModel: row.deviceModel)
                }
                if let last = clusters.last?.last, row.startDate - last.endDate <= 3 * 3600 {
                    clusters[clusters.count - 1].append(row)
                } else { clusters.append([row]) }
            }
            for cluster in clusters {
                guard let first = cluster.first else { continue }
                let kind = HealthDataSource.classify(sourceName: first.sourceName, metadataOrigin: nil,
                                                     sourceBundle: first.sourceBundle,
                                                     productType: first.productType,
                                                     deviceModel: first.deviceModel)
                guard let rank = order.firstIndex(of: kind),
                      let last = cluster.last,
                      endWindow.map({ last.endDate >= $0.from && last.endDate < $0.to })
                        ?? (formatter.string(from: Date(timeIntervalSince1970: last.endDate)) == date) else { continue }
                let asleep = cluster.filter { $0.value != 2 }.reduce(0.0) { $0 + $1.endDate - $1.startDate }
                if asleep > 0 { candidates.append((source, rank, cluster, asleep, kind)) }
            }
        }
        guard let chosen = candidates.sorted(by: {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.sleep == $1.sleep ? $0.source < $1.source : $0.sleep > $1.sleep
        }).first, let first = chosen.segments.first, let last = chosen.segments.last else { return nil }
        var deep = 0.0, light = 0.0, rem = 0.0, wake = 0.0, unspecified = 0.0, disturbances = 0
        var stages: [Segment] = []
        for row in chosen.segments {
            let duration = row.endDate - row.startDate
            let name: String
            switch Int(row.value ?? -1) {
            case 1: unspecified += duration; continue
            case 2: wake += duration; disturbances += 1; name = "wake"
            case 3: light += duration; name = "light"
            case 4: deep += duration; name = "deep"
            case 5: rem += duration; name = "rem"
            default: continue
            }
            stages.append(Segment(start: row.startDate, end: row.endDate, stage: name))
        }
        let measured = light + deep + rem + unspecified + wake
        guard measured > 0, let data = try? JSONEncoder().encode(stages) else { return nil }
        // Only calculate TST / observed sleep-period span when classified epochs actually cover
        // the interval. Gaps and unspecified stages do not establish time in bed or efficiency.
        let unknownGap = max(0, (last.endDate - first.startDate) - measured)
        let efficiencyKnown = unspecified == 0 && unknownGap <= 30
        let efficiency = efficiencyKnown ? chosen.sleep / measured : 0
        let summary = DailySleepSummary(date: date, totalSleepMin: chosen.sleep / 60,
            efficiency: efficiency, deepMin: deep / 60, remMin: rem / 60, lightMin: light / 60,
            disturbances: disturbances, restingHR: nil, avgRmssd: nil,
            sleepStart: first.startDate, sleepEnd: last.endDate)
        let session = SleepSession(startTs: Int(first.startDate), endTs: Int(last.endDate),
                                   efficiency: efficiencyKnown ? efficiency : nil, restingHr: nil, avgHrv: nil,
                                   stages: unspecified > 0 ? nil : data, sourceName: first.sourceName ?? "Apple Santé",
                                   healthSource: chosen.kind)
        return Result(summary: summary, session: session, stagesComplete: unspecified == 0, source: chosen.kind)
    }
}
