import Foundation

// MARK: - Détection des séances bracelet (pur)
//
// Une séance « cardio détecté » est une période où la FC du bracelet reste au-dessus d'un seuil
// d'effort. Les seuils ci-dessous sont des hypothèses Loop documentées, pas des valeurs validées
// contre une référence (voir docs/audit-calculs/IMPLEMENTATION-SEANCES.md).

/// Intervalle `[start, end)` en secondes Unix.
public struct WorkoutInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }

    public func overlap(_ other: WorkoutInterval) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    /// Écart entre deux intervalles disjoints, 0 s'ils se touchent ou se recouvrent.
    public func gap(_ other: WorkoutInterval) -> Double {
        max(0, max(other.start - end, start - other.end))
    }
}

public enum WorkoutDetectionPolicy {
    /// Durée minimale (première → dernière seconde active) d'une séance créée. Même valeur que la
    /// règle de fragment de la fusion (`WorkoutCanonicalization.minimumSessionSeconds`) : une
    /// séance plus courte n'est jamais créée, elle n'est pas seulement masquée à l'affichage.
    public static let minimumDurationSeconds: Double = 10 * 60
    /// Minutes réellement au-dessus du seuil (médiane de la minute) exigées : la moitié de la
    /// durée minimale. Sans cela, deux pics isolés espacés de 10 min formaient une « séance ».
    /// La médiane par minute neutralise les pics d'une ou deux secondes (artefact optique, lever).
    public static let minimumActiveMinutes = 5
    /// Repos toléré entre deux passages au-dessus du seuil (repos inter-séries en musculation,
    /// souvent 3 à 10 min). Au-delà, ce sont deux séances distinctes.
    public static let maximumGapSeconds: Double = 12 * 60
    /// Garde autour d'une fenêtre de sommeil retenue. Une détection qui recoupe
    /// `[début − garde, fin + garde]` n'est pas « nettement séparée » du sommeil : FC élevée
    /// de la soirée qui se prolonge jusqu'à l'endormissement, réveil agité. 30 min couvrent la
    /// latence d'endormissement habituelle (10 à 20 min) et l'incertitude sur les bornes de
    /// sommeil entre sources (bracelet et Apple Watch ne datent pas l'endormissement pareil).
    public static let sleepGuardSeconds: Double = 30 * 60
    /// Seuil d'effort = max(FC basse du jour + 35, 110) bpm. Inchangé : seuil absolu historique.
    public static let thresholdAboveRestingBPM: Double = 35
    public static let thresholdFloorBPM: Double = 110
    /// FC basse du jour : 10ᵉ centile des FC de la journée locale.
    public static let restingPercentile = 0.10
    public static let minimumThresholdSamples = 20
}

/// Une séance détectée sur la FC du bracelet.
public struct DetectedWorkout: Equatable, Sendable {
    public let start: Double
    public let end: Double
    /// Moyenne et pic des seuls échantillons au-dessus du seuil (non dilués par les repos).
    public let averageBPM: Double
    public let peakBPM: Double
    public let activeMinutes: Int

    public var duration: Double { end - start }
}

public enum WorkoutDetector {
    /// Seuil d'effort tiré de la journée seule, ou nil si trop peu d'échantillons.
    public static func threshold(daySeries: [Double]) -> Double? {
        let sorted = daySeries.filter { $0.isFinite }.sorted()
        guard sorted.count >= WorkoutDetectionPolicy.minimumThresholdSamples else { return nil }
        let index = min(sorted.count - 1,
                        Int((Double(sorted.count - 1) * WorkoutDetectionPolicy.restingPercentile).rounded(.down)))
        return max(sorted[index] + WorkoutDetectionPolicy.thresholdAboveRestingBPM,
                   WorkoutDetectionPolicy.thresholdFloorBPM)
    }

    /// - Parameters:
    ///   - hrSeries: FC du bracelet sur le jour et ses marges.
    ///   - thresholdSeries: FC du jour seul ; le seuil n'en dépend que.
    ///   - startWindow: une séance qui commence hors `[from, to)` appartient à un jour voisin.
    ///   - sleep: fenêtres de sommeil retenues (nuits et siestes, toutes sources).
    ///   - recorded: séances enregistrées (Apple Santé). Leurs échantillons coupent la détection :
    ///     la séance enregistrée fait foi, seul ce qui la déborde peut encore devenir une détection.
    public static func detect(hrSeries: [(ts: Double, bpm: Double)],
                              thresholdSeries: [(ts: Double, bpm: Double)],
                              startWindow: (from: Double, to: Double),
                              sleep: [WorkoutInterval] = [],
                              recorded: [WorkoutInterval] = []) -> [DetectedWorkout] {
        guard let threshold = threshold(daySeries: thresholdSeries.map(\.bpm)) else { return [] }
        let samples = hrSeries.filter { $0.ts.isFinite && $0.bpm.isFinite }.sorted { $0.ts < $1.ts }
        let recordedSorted = recorded.filter { $0.end > $0.start }
        let guardS = WorkoutDetectionPolicy.sleepGuardSeconds
        let sleepGuarded = sleep.filter { $0.end > $0.start }
            .map { WorkoutInterval(start: $0.start - guardS, end: $0.end + guardS) }

        var result: [DetectedWorkout] = []
        var current: [(ts: Double, bpm: Double)] = []
        var lastActive: Double?
        var segmentStartIndex = 0
        var segmentEndIndex = 0

        func flush() {
            defer { current.removeAll(); lastActive = nil }
            guard let first = current.first, let last = current.last else { return }
            let span = WorkoutInterval(start: first.ts, end: last.ts)
            guard span.duration >= WorkoutDetectionPolicy.minimumDurationSeconds else { return }
            guard !sleepGuarded.contains(where: { $0.start <= span.end && span.start <= $0.end }) else { return }
            // Minutes actives : médiane de tous les échantillons de la minute (actifs ou non).
            var byMinute: [Double: [Double]] = [:]
            for s in samples[segmentStartIndex..<segmentEndIndex] where s.ts >= first.ts && s.ts <= last.ts {
                byMinute[floor(s.ts / 60), default: []].append(s.bpm)
            }
            let activeMinutes = byMinute.values.filter { median($0) >= threshold }.count
            guard activeMinutes >= WorkoutDetectionPolicy.minimumActiveMinutes else { return }
            let bpms = current.map(\.bpm)
            result.append(DetectedWorkout(start: first.ts, end: last.ts,
                                          averageBPM: bpms.reduce(0, +) / Double(bpms.count),
                                          peakBPM: bpms.max() ?? 0, activeMinutes: activeMinutes))
        }

        for (index, sample) in samples.enumerated() {
            if recordedSorted.contains(where: { sample.ts >= $0.start && sample.ts < $0.end }) {
                flush()
                continue
            }
            if let lastActive, sample.ts - lastActive > WorkoutDetectionPolicy.maximumGapSeconds {
                flush()
            }
            if sample.bpm >= threshold {
                if current.isEmpty { segmentStartIndex = index }
                current.append(sample)
                lastActive = sample.ts
                segmentEndIndex = index + 1
            }
        }
        flush()
        return result.filter { $0.start >= startWindow.from && $0.start < startWindow.to }
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}
