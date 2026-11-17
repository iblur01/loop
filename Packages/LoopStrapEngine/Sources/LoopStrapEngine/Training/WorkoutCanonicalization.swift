import Foundation

// MARK: - Fusion des séances multisources (pur)
//
// Une même séance peut arriver plusieurs fois : Apple Watch, Strava (qui recopie souvent la
// séance de la montre ou d'une autre app), une autre app Santé (Hevy…) et la détection du
// bracelet. La fusion se fait à la lecture / dans le cache dérivé : aucune donnée brute n'est
// supprimée. Une seule règle de priorité, `WorkoutSourcePriority.order`, sert partout.

/// Producteur d'une séance, du plus fiable au moins fiable pour les bornes et le type.
public enum WorkoutSource: String, CaseIterable, Sendable {
    /// Séance démarrée et arrêtée sur l'Apple Watch.
    case appleWatch
    /// Séance Strava importée dans Apple Santé.
    case strava
    /// Toute autre app ou source Apple Santé.
    case otherHealth
    /// Détection automatique sur la FC du bracelet.
    case band
}

public enum WorkoutSourcePriority {
    /// Règle unique : Apple Watch, puis Strava, puis autre source Santé, puis bracelet.
    public static let order: [WorkoutSource] = [.appleWatch, .strava, .otherHealth, .band]

    public static func rank(_ source: WorkoutSource) -> Int {
        order.firstIndex(of: source) ?? order.count
    }

    /// Classe une séance d'après le nom de la source Santé. `recorded == false` : bracelet.
    public static func classify(sourceName: String?, recorded: Bool) -> WorkoutSource {
        guard recorded else { return .band }
        let name = sourceName?.lowercased() ?? ""
        if name.contains("watch") { return .appleWatch }
        if name.contains("strava") { return .strava }
        return .otherHealth
    }
}

/// Une séance vue par une source, réduite à ce que la fusion compare.
public struct WorkoutCandidate: Equatable, Sendable {
    public let id: String
    public let source: WorkoutSource
    /// Nom de l'app productrice ; deux séances du même producteur restent distinctes.
    public let origin: String?
    /// `HKWorkoutActivityType` ; nil pour une détection bracelet.
    public let sportType: Int?
    public let start: Double
    public let end: Double

    public init(id: String, source: WorkoutSource, origin: String? = nil, sportType: Int? = nil,
                start: Double, end: Double) {
        self.id = id; self.source = source; self.origin = origin; self.sportType = sportType
        self.start = start; self.end = end
    }

    public var interval: WorkoutInterval { WorkoutInterval(start: start, end: end) }
    public var duration: Double { end - start }
}

/// Une séance canonique : la séance retenue et toutes celles qu'elle absorbe.
public struct WorkoutCanonicalGroup: Equatable, Sendable {
    /// Source prioritaire : ses bornes font foi.
    public let primary: WorkoutCandidate
    /// Tous les membres, primaire en tête : d'abord les doublons de la même séance (par priorité),
    /// puis les faux départs et détections bracelet absorbés.
    public let members: [WorkoutCandidate]
    /// Type de sport retenu : celui du primaire, sinon le premier type précis d'un membre
    /// (Strava écrit souvent « Autre » pour une séance que Hevy nomme « Musculation »).
    public let sportType: Int?
}

public enum WorkoutCanonicalization {
    /// `HKWorkoutActivityType.other` : compatible avec n'importe quel sport.
    public static let genericSportTypes: Set<Int> = [3000]
    /// Deux enregistrements sont la même séance si le recouvrement couvre au moins 50 % de la
    /// plus courte ET 70 % de la plus longue (une longue séance n'avale pas deux séances voisines).
    public static let sameSessionShorterFraction = 0.5
    public static let sameSessionLongerFraction = 0.7
    /// Une détection bracelet est absorbée par une séance enregistrée dès que leur recouvrement
    /// couvre la moitié de la plus courte des deux : c'est la même période d'effort.
    public static let bandAbsorbFraction = 0.5
    /// Une détection bracelet qui commence ou finit à moins de cet écart d'une séance enregistrée
    /// est la vue bracelet du même effort continu : c'est l'écart que le détecteur comble
    /// lui-même (`WorkoutDetectionPolicy.maximumGapSeconds`).
    public static let bandContinuationSeconds = WorkoutDetectionPolicy.maximumGapSeconds
    /// Règle de fragment : en dessous de cette durée, une séance enregistrée collée (écart
    /// < `fragmentAdjacencySeconds`) à une séance compatible plus longue est un faux départ
    /// absorbé par celle-ci. Même seuil que la durée minimale de détection bracelet.
    public static let minimumSessionSeconds = WorkoutDetectionPolicy.minimumDurationSeconds
    public static let fragmentAdjacencySeconds: Double = 10 * 60

    public static func compatibleSports(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b, !genericSportTypes.contains(a), !genericSportTypes.contains(b) else { return true }
        return a == b
    }

    public static func canonicalize(_ candidates: [WorkoutCandidate]) -> [WorkoutCanonicalGroup] {
        let valid = candidates.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let recorded = valid.filter { $0.source != .band }
        let band = valid.filter { $0.source == .band }

        // 1. Enregistrements Santé du même effort (complete-link : tous les membres se recoupent).
        var groups: [[WorkoutCandidate]] = []
        for c in recorded {
            if let i = groups.firstIndex(where: { $0.allSatisfy { sameSession($0, c) } }) {
                groups[i].append(c)
            } else {
                groups.append([c])
            }
        }

        // 2. Faux départs : un groupe court collé à un groupe compatible plus long s'y fond.
        var spans = groups.map(primaryOf)
        var absorbedInto: [Int: Int] = [:]
        for (i, p) in spans.enumerated() where p.duration < minimumSessionSeconds {
            let sport = sportType(of: groups[i])
            let host = spans.indices.filter { j in
                j != i && spans[j].duration >= minimumSessionSeconds
                    && p.interval.gap(spans[j].interval) < fragmentAdjacencySeconds
                    && compatibleSports(sport, sportType(of: groups[j]))
            }.min { p.interval.gap(spans[$0].interval) < p.interval.gap(spans[$1].interval) }
            if let host { absorbedInto[i] = host }
        }
        // Les membres absorbés ne deviennent jamais primaires : les bornes restent celles de l'hôte.
        var absorbed = groups.map { _ in [WorkoutCandidate]() }
        for (i, host) in absorbedInto { absorbed[host].append(contentsOf: groups[i]) }
        let kept = groups.indices.filter { absorbedInto[$0] == nil }
        groups = kept.map { groups[$0] }
        absorbed = kept.map { absorbed[$0] }
        spans = groups.map(primaryOf)

        // 3. Détections bracelet : absorbées par la séance enregistrée qu'elles doublent
        //    (recouvrement), ou qu'elles prolongent sans interruption (échauffement, retour au
        //    calme : écart ≤ celui que le détecteur comble lui-même entre deux passages actifs).
        var standalone: [[WorkoutCandidate]] = []
        for b in band {
            let overlapping = spans.indices
                .map { (index: $0, overlap: b.interval.overlap(spans[$0].interval)) }
                .filter { $0.overlap > 0 && $0.overlap >= bandAbsorbFraction * min(b.duration, spans[$0.index].duration) }
                .max { $0.overlap < $1.overlap }?.index
            let adjacent = spans.indices
                .filter { b.interval.gap(spans[$0].interval) <= bandContinuationSeconds }
                .min { b.interval.gap(spans[$0].interval) < b.interval.gap(spans[$1].interval) }
            if let host = overlapping ?? adjacent { absorbed[host].append(b) } else { standalone.append([b]) }
        }

        let all = zip(groups, absorbed).map { ($0, $1) } + standalone.map { ($0, [WorkoutCandidate]()) }
        return all.map { core, extra in
            let sortedCore = core.sorted(by: priorityOrder)
            return WorkoutCanonicalGroup(primary: sortedCore[0],
                                         members: sortedCore + extra.sorted(by: priorityOrder),
                                         sportType: sportType(of: core))
        }.sorted { $0.primary.start == $1.primary.start ? $0.primary.id < $1.primary.id : $0.primary.start < $1.primary.start }
    }

    /// Priorité de source, puis séance la plus longue, puis début le plus tôt, puis id.
    public static func priorityOrder(_ a: WorkoutCandidate, _ b: WorkoutCandidate) -> Bool {
        let ra = WorkoutSourcePriority.rank(a.source), rb = WorkoutSourcePriority.rank(b.source)
        if ra != rb { return ra < rb }
        if a.duration != b.duration { return a.duration > b.duration }
        if a.start != b.start { return a.start < b.start }
        return a.id < b.id
    }

    static func sameSession(_ a: WorkoutCandidate, _ b: WorkoutCandidate) -> Bool {
        // Deux séances du même producteur peuvent être deux séances voulues.
        if let x = a.origin?.lowercased(), let y = b.origin?.lowercased(), x == y { return false }
        if a.origin == nil && b.origin == nil && a.source == b.source { return false }
        guard compatibleSports(a.sportType, b.sportType) else { return false }
        let overlap = a.interval.overlap(b.interval)
        guard overlap > 0 else { return false }
        return overlap >= sameSessionShorterFraction * min(a.duration, b.duration)
            && overlap >= sameSessionLongerFraction * max(a.duration, b.duration)
    }

    private static func primaryOf(_ group: [WorkoutCandidate]) -> WorkoutCandidate {
        group.sorted(by: priorityOrder)[0]
    }

    private static func sportType(of group: [WorkoutCandidate]) -> Int? {
        let sorted = group.sorted(by: priorityOrder)
        if let t = sorted[0].sportType, !genericSportTypes.contains(t) { return t }
        return sorted.lazy.compactMap(\.sportType).first { !genericSportTypes.contains($0) } ?? sorted[0].sportType
    }
}
