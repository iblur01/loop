import Foundation
import LoopStrapEngine

// MARK: - Source

/// Source d'un événement de la journée, avec un rang de fiabilité pour les bornes d'une séance :
/// séance enregistrée sur Apple Watch > appli de sport (Strava…) > autre source Santé >
/// détection automatique du bracelet.
enum DayTimelineSource: Equatable, Hashable {
    case appleWatch
    case strava
    case otherHealth(name: String?)
    case bracelet

    var label: String {
        switch self {
        case .appleWatch: return "Apple Watch"
        case .strava: return "Strava"
        case .otherHealth(let name): return name ?? String(localized: "health.source.apple", table: "Core")
        case .bracelet: return String(localized: "health.source.band", table: "Core")
        }
    }

    /// Catégorie de source, sans valeur associée, pour l'ordre de priorité.
    enum Category: CaseIterable {
        case appleWatch, strava, otherHealth, bracelet
    }

    /// Priorité des sources d'une séance, de la plus fiable à la moins fiable. Projection de la
    /// règle unique du moteur `WorkoutSourcePriority.order` (fusion du cache dérivé), pour que
    /// l'affichage et le calcul ne puissent pas diverger.
    static let priority: [Category] = WorkoutSourcePriority.order.map { source in
        switch source {
        case .appleWatch: return .appleWatch
        case .strava: return .strava
        case .otherHealth: return .otherHealth
        case .band: return .bracelet
        }
    }

    var category: Category {
        switch self {
        case .appleWatch: return .appleWatch
        case .strava: return .strava
        case .otherHealth: return .otherHealth
        case .bracelet: return .bracelet
        }
    }

    /// Plus grand = plus fiable, dérivé de `priority`.
    var reliability: Int {
        Self.priority.count - (Self.priority.firstIndex(of: category) ?? Self.priority.count)
    }

    /// Trie des sources selon `priority`.
    static func ordered(_ sources: [DayTimelineSource]) -> [DayTimelineSource] {
        sources.sorted { $0.reliability > $1.reliability }
    }

    static func of(_ w: WorkoutSession) -> DayTimelineSource {
        guard w.externalID != nil else { return .bracelet }
        let name = w.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name?.lowercased() ?? ""
        if lower.contains("watch") { return .appleWatch }
        if lower.contains("strava") { return .strava }
        return .otherHealth(name: (name?.isEmpty ?? true) ? nil : name)
    }

    static func of(_ s: SleepSession) -> DayTimelineSource {
        guard let name = s.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return .bracelet }
        if name.lowercased().contains("watch") { return .appleWatch }
        return .otherHealth(name: name)
    }
}

// MARK: - Entry

/// Un événement affiché de la journée (déjà fusionné / filtré). Valeur pure.
struct DayTimelineEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case sleep
        case nap
        case workout(WorkoutSport.Kind)
    }

    let id: String
    let kind: Kind
    let start: Int
    let end: Int
    let avgHr: Double?
    let peakHr: Int?
    let source: DayTimelineSource
    /// Sources écartées par la fusion (doublons du même événement).
    let mergedSources: [DayTimelineSource]
    /// Séance qui recouvre une fenêtre de sommeil : présentée comme incohérente, pas comme un effort.
    let overlapsSleep: Bool
    /// Séance d'origine retenue (navigation vers le détail).
    let workoutID: String?
    /// Libellé brut d'origine pour un type non reconnu.
    let rawKind: String?
    let sportType: Int?

    var durationMinutes: Int { max(0, (end - start) / 60) }
    var isWorkout: Bool { if case .workout = kind { return true } else { return false } }
}

// MARK: - Builder

/// Fusion et filtrage purs des événements d'une journée (testés dans `DayTimelineBuilderTests`).
/// Rien n'est écrit en base : on ne fait que préparer l'affichage.
enum DayTimelineBuilder {
    struct Result: Equatable {
        /// Événements affichés, ordre chronologique.
        let entries: [DayTimelineEntry]
        /// Événements de moins de `minimumMinutes`, masqués en ligne et comptés à part.
        let fragments: [DayTimelineEntry]
    }

    /// Écart maximal entre deux séances du même sport pour les fusionner.
    static let mergeGapSeconds = 10 * 60
    /// Durée minimale d'un événement affiché en ligne.
    static let minimumMinutes = 5
    /// Recouvrement minimal d'une séance avec le sommeil pour la signaler.
    static let sleepOverlapSeconds = 10 * 60
    /// Une nuit principale fait au moins 3 h ; les autres sommeils du jour sont des siestes.
    static let mainSleepMinSeconds = 3 * 3600

    /// - Parameters:
    ///   - day: jour local "yyyy-MM-dd" ; sommeil rattaché par sa fin, séance par son début.
    ///   - sleep: toutes les sessions de sommeil connues (le recouvrement est testé sur toutes).
    static func build(day: String, sleep: [SleepSession], workouts: [WorkoutSession],
                      timeZone: TimeZone = .autoupdatingCurrent) -> Result {
        let dayOf = dayFormatter(timeZone)

        // Sommeil du jour.
        let daySleep = sleep.filter { dayOf($0.endTs) == day }.sorted { $0.startTs < $1.startTs }
        let mainID = daySleep
            .filter { $0.endTs - $0.startTs >= mainSleepMinSeconds }
            .max { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) }?.id
        let sleepEntries = daySleep.map { s in
            DayTimelineEntry(id: "sleep-\(s.id)", kind: s.id == mainID ? .sleep : .nap,
                             start: s.startTs, end: s.endTs, avgHr: nil, peakHr: nil,
                             source: .of(s), mergedSources: [], overlapsSleep: false,
                             workoutID: nil, rawKind: nil, sportType: nil)
        }

        // Séances du jour, fusionnées.
        let dayWorkouts = workouts.filter { dayOf($0.startTs) == day }
        let merged = mergeWorkouts(dayWorkouts).map { entry -> DayTimelineEntry in
            let overlap = sleep.contains { overlapSeconds(entry.start, entry.end, $0.startTs, $0.endTs) >= sleepOverlapSeconds }
            return entry.with(overlapsSleep: overlap)
        }

        let all = (sleepEntries + merged).sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        let isFragment: (DayTimelineEntry) -> Bool = { $0.durationMinutes < minimumMinutes }
        return Result(entries: all.filter { !isFragment($0) }, fragments: all.filter(isFragment))
    }

    /// Fusionne les séances qui se chevauchent ou se touchent (< 10 min) quand elles sont du même
    /// sport, ou quand l'une est un cardio détecté par le bracelet (doublon d'une séance nommée).
    /// La source la plus fiable donne les bornes de référence, le type et la FC ; les autres sont
    /// listées dans `mergedSources`.
    static func mergeWorkouts(_ workouts: [WorkoutSession]) -> [DayTimelineEntry] {
        struct Group { var items: [WorkoutSession]; var start: Int; var end: Int }

        func sport(_ w: WorkoutSession) -> WorkoutSport.Kind { WorkoutSport(kind: w.kind, sportType: w.sportType).kind }
        func compatible(_ a: WorkoutSport.Kind, _ b: WorkoutSport.Kind) -> Bool {
            a == b || a == .detectedCardio || b == .detectedCardio
        }

        var groups: [Group] = []
        for w in workouts.sorted(by: { $0.startTs < $1.startTs }) {
            let k = sport(w)
            if let idx = groups.lastIndex(where: { g in
                w.startTs - g.end < mergeGapSeconds && g.items.contains { compatible(sport($0), k) }
            }) {
                groups[idx].items.append(w)
                groups[idx].end = max(groups[idx].end, w.endTs)
                groups[idx].start = min(groups[idx].start, w.startTs)
            } else {
                groups.append(Group(items: [w], start: w.startTs, end: w.endTs))
            }
        }

        return groups.map { g in
            // Priorité : source la plus fiable, puis type nommé plutôt que cardio détecté, puis la plus longue.
            let ranked = g.items.sorted { a, b in
                let ra = DayTimelineSource.of(a).reliability, rb = DayTimelineSource.of(b).reliability
                if ra != rb { return ra > rb }
                let da = sport(a) == .detectedCardio, db = sport(b) == .detectedCardio
                if da != db { return !da }
                return (a.endTs - a.startTs) > (b.endTs - b.startTs)
            }
            let primary = ranked[0]
            let others = ranked.dropFirst().map { DayTimelineSource.of($0) }
            var seen = Set<DayTimelineSource>([DayTimelineSource.of(primary)])
            let mergedSources = DayTimelineSource.ordered(others.filter { seen.insert($0).inserted })
            return DayTimelineEntry(
                id: "workout-\(primary.id)",
                kind: .workout(sport(primary)),
                start: g.start, end: g.end,
                avgHr: primary.avgHr ?? ranked.lazy.compactMap(\.avgHr).first,
                peakHr: ranked.compactMap(\.peakHr).max(),
                source: DayTimelineSource.of(primary),
                mergedSources: mergedSources,
                overlapsSleep: false,
                workoutID: primary.id,
                rawKind: primary.kind,
                sportType: primary.sportType
            )
        }
    }

    static func overlapSeconds(_ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Int {
        max(0, min(a1, b1) - max(a0, b0))
    }

    private static func dayFormatter(_ tz: TimeZone) -> (Int) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        return { f.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }
    }
}

private extension DayTimelineEntry {
    func with(overlapsSleep: Bool) -> DayTimelineEntry {
        DayTimelineEntry(id: id, kind: kind, start: start, end: end, avgHr: avgHr, peakHr: peakHr,
                         source: source, mergedSources: mergedSources, overlapsSleep: overlapsSleep,
                         workoutID: workoutID, rawKind: rawKind, sportType: sportType)
    }
}
