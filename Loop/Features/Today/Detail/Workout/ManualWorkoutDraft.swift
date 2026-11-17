import Foundation
import LoopStrapEngine
import WhoopStore

/// État et règles de la feuille « Ajouter une séance ». Pur (horloge et fuseau injectés) pour
/// être testé sans UI. Aucun calcul de charge ici : le moteur lit la séance une fois enregistrée.
struct ManualWorkoutDraft: Equatable {
    static let durationRange = ManualWorkout.durationMinutesRange
    static let durationStep = ManualWorkout.durationStepMinutes
    static let defaultDuration = 60
    static let defaultRPE = 5
    /// Granularité de l'heure de début proposée.
    static let roundingSeconds: Double = 5 * 60

    var sport: ManualWorkoutSport = .strength
    var start: Date
    var durationMinutes: Int = defaultDuration
    var rpe: Int = defaultRPE
    var note: String = ""

    var isDurationValid: Bool { ManualWorkout.isValidDuration(durationMinutes) }
    var end: Date { start.addingTimeInterval(Double(durationMinutes * 60)) }

    /// Même règle que le store : durée multiple de 5 entre 5 et 300 min, séance terminée.
    func validationError(now: Date) -> ManualWorkoutStore.StoreError? {
        if let error = ManualWorkout.validationError(start: start, durationMinutes: durationMinutes, now: now) {
            return error
        }
        return WorkoutPerceivedEffort.rpeRange.contains(rpe) ? nil : .invalidRPE
    }

    func isValid(now: Date) -> Bool { validationError(now: now) == nil }

    /// Début proposé : une séance de `duration` minutes qui vient de se terminer, soit
    /// maintenant arrondi aux 5 minutes inférieures moins la durée. Pour un autre jour (`day`,
    /// clé locale), la même heure ce jour-là, sans jamais finir après `now`.
    static func defaultStart(day: String?, now: Date, zone: TimeZone, duration: Int = defaultDuration) -> Date {
        let rounded = (now.timeIntervalSince1970 / roundingSeconds).rounded(.down) * roundingSeconds
        let latest = rounded - Double(duration * 60)
        let today = LocalDay.key(now.timeIntervalSince1970, in: zone)
        guard let day, day != today,
              let todayStart = LocalDay.start(today, in: zone),
              let dayStart = LocalDay.start(day, in: zone) else {
            return Date(timeIntervalSince1970: latest)
        }
        let candidate = Double(dayStart) + (latest - Double(todayStart))
        return Date(timeIntervalSince1970: min(candidate, latest))
    }

    // MARK: - Séance déjà enregistrée

    /// Ce que l'enregistrement fera de la saisie.
    enum Plan: Equatable {
        /// Aucune séance enregistrée ne la recouvre : nouvelle ligne manuelle.
        case create
        /// Une séance enregistrée (montre, Strava, app Santé) de sport compatible la recouvre :
        /// pas de nouvelle ligne (pas de doublon ni de double charge) ; RPE et note vont sur elle.
        case attachEffort(to: WorkoutSession, reason: AttachReason)
    }

    enum AttachReason: Equatable {
        /// La fusion multisource (règle 50 % / 70 %) l'absorberait.
        case merge
        /// Recouvrement partiel, sous le seuil de fusion : deux séances seraient comptées.
        case overlap
    }

    /// Part minimale de la saisie recouverte par une séance enregistrée pour lui rattacher
    /// l'effort quand la fusion ne l'absorbe pas (évite qu'un recouvrement de quelques minutes
    /// détourne la saisie vers une séance voisine).
    static let attachOverlapFraction = 0.5

    /// Seules les séances enregistrées (montre, Strava, app Santé) peuvent recevoir l'effort :
    /// - jamais une détection bracelet — la saisie l'absorbe et le moteur coupe le signal
    ///   bracelet sur son créneau ;
    /// - jamais une autre saisie manuelle — deux saisies voulues restent distinctes, et une
    ///   saisie n'écrase pas le RPE ou la note d'une autre ;
    /// - toujours avec un recouvrement réel : `.merge` si la fusion (50 % / 70 %) l'absorberait,
    ///   `.overlap` si au moins `attachOverlapFraction` de la saisie est couverte ; sinon `.create`.
    func plan(existing sessions: [WorkoutSession]) -> Plan {
        if let target = absorbingSession(in: sessions) { return .attachEffort(to: target, reason: .merge) }
        let duration = end.timeIntervalSince(start)
        let overlapping = Self.recorded(sessions)
            .filter { WorkoutCanonicalization.compatibleSports($0.sportType, sport.rawValue) }
            .map { (session: $0, overlap: overlap(with: $0)) }
            .filter { duration > 0 && $0.overlap >= Self.attachOverlapFraction * duration }
            .max { $0.overlap < $1.overlap }
        if let overlapping { return .attachEffort(to: overlapping.session, reason: .overlap) }
        return .create
    }

    /// Séance enregistrée (non manuelle) qui recouvre réellement la saisie et qui l'absorberait
    /// selon la règle unique de fusion (`WorkoutCanonicalization`). Une absorption sans
    /// recouvrement (règle des faux départs) ne désigne aucune cible.
    func absorbingSession(in sessions: [WorkoutSession]) -> WorkoutSession? {
        let draftID = "manual-draft"
        let draft = WorkoutCandidate(id: draftID, source: .otherHealth, origin: ManualWorkout.sourceName,
                                     sportType: sport.rawValue, start: start.timeIntervalSince1970,
                                     end: end.timeIntervalSince1970)
        let existing = sessions.map { s in
            WorkoutCandidate(id: s.id,
                             source: WorkoutSourcePriority.classify(sourceName: s.sourceName, recorded: s.externalID != nil),
                             origin: s.externalID == nil ? nil : s.sourceName,
                             sportType: s.externalID == nil ? nil : s.sportType,
                             start: Double(s.startTs), end: Double(s.endTs))
        }
        guard let group = WorkoutCanonicalization.canonicalize(existing + [draft])
            .first(where: { $0.members.contains { $0.id == draftID } }),
              group.primary.id != draftID,
              let primary = Self.recorded(sessions).first(where: { $0.id == group.primary.id }),
              overlap(with: primary) > 0 else { return nil }
        return primary
    }

    private static func recorded(_ sessions: [WorkoutSession]) -> [WorkoutSession] {
        sessions.filter { $0.externalID != nil && $0.sourceName != ManualWorkout.sourceName }
    }

    private func overlap(with s: WorkoutSession) -> Double {
        min(end.timeIntervalSince1970, Double(s.endTs)) - max(start.timeIntervalSince1970, Double(s.startTs))
    }
}
