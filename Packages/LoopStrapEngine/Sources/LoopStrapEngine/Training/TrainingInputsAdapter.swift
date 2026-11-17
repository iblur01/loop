import Foundation

// MARK: - Training inputs adapter
//
// Pure mapping from facts the engine already produced (daily results / snapshots, sessions,
// sleep, session RPE) to `TrainingInputs`. No I/O, no clock, no time zone: the caller supplies
// every day as an ordinal (e.g. local days since 1970-01-01). A missing value stays nil.

/// One computed day: cardio load and recovery. Built from a `DailyResult` or an app snapshot.
public struct TrainingDayRecord: Equatable, Sendable {
    public var day: Int
    public var strain: Double?
    /// Engine confidence string for the load ("low" | "medium" | "high"), when known.
    public var strainConfidence: String?
    public var recovery: Double?
    /// `RecoveryResult.confidence` / `recoveryStatus`.
    public var recoveryConfidence: String?
    public var recoveryExperimentalLabel: String?
    public var source: String?

    public init(day: Int, strain: Double?, strainConfidence: String? = nil, recovery: Double? = nil,
                recoveryConfidence: String? = nil, recoveryExperimentalLabel: String? = nil,
                source: String? = nil) {
        self.day = day
        self.strain = strain
        self.strainConfidence = strainConfidence
        self.recovery = recovery
        self.recoveryConfidence = recoveryConfidence
        self.recoveryExperimentalLabel = recoveryExperimentalLabel
        self.source = source
    }

    public init(day: Int, result: DailyResult, source: String? = nil) {
        self.init(day: day, strain: result.strain, recovery: result.recovery,
                  recoveryConfidence: result.recoveryStatus, source: source)
    }
}

/// One night, attributed by the caller to the day of waking.
public struct TrainingSleepRecord: Equatable, Sendable {
    public var day: Int
    public var totalSleepMin: Double?
    /// Fraction 0...1.
    public var efficiency: Double?
    public var disturbances: Int?
    public var coverage: Double?
    public var source: String?

    public init(day: Int, totalSleepMin: Double?, efficiency: Double? = nil, disturbances: Int? = nil,
                coverage: Double? = nil, source: String? = nil) {
        self.day = day
        self.totalSleepMin = totalSleepMin
        self.efficiency = efficiency
        self.disturbances = disturbances
        self.coverage = coverage
        self.source = source
    }

    public init(day: Int, summary: DailySleepSummary, source: String? = nil) {
        self.init(day: day, totalSleepMin: summary.totalSleepMin, efficiency: summary.efficiency,
                  disturbances: summary.disturbances, source: source)
    }

    /// Sleep fields of a daily result; nil when the day has no sleep summary.
    public init?(day: Int, result: DailyResult, source: String? = nil) {
        guard result.totalSleepMin != nil || result.efficiency != nil else { return nil }
        self.init(day: day, totalSleepMin: result.totalSleepMin, efficiency: result.efficiency,
                  disturbances: result.disturbances, source: source)
    }
}

/// One session (band-detected or imported). `id` must be stable: two records with the same id
/// are the same session. `perceivedEffort` is the stored session RPE (1...10), if any.
public struct TrainingWorkoutRecord: Equatable, Sendable {
    public var id: String
    public var day: Int
    public var kind: String?
    /// HealthKit activity type raw value, when imported.
    public var sportType: Int?
    public var startTs: Int
    public var endTs: Int
    public var durationS: Int?
    /// Session cardio load (same scale as the daily strain).
    public var strain: Double?
    public var perceivedEffort: Int?
    public var source: String?

    public init(id: String, day: Int, kind: String?, sportType: Int? = nil, startTs: Int, endTs: Int,
                durationS: Int? = nil, strain: Double? = nil, perceivedEffort: Int? = nil,
                source: String? = nil) {
        self.id = id
        self.day = day
        self.kind = kind
        self.sportType = sportType
        self.startTs = startTs
        self.endTs = endTs
        self.durationS = durationS
        self.strain = strain
        self.perceivedEffort = perceivedEffort
        self.source = source
    }
}

public enum TrainingInputsAdapter {
    /// Builds `TrainingInputs` for analysis up to `asOfDay`. Returns nil when no day, night or
    /// session up to `asOfDay` carries a usable value. Output arrays are sorted (day, then id or
    /// source) so the result does not depend on input order; sessions sharing an id are merged
    /// (first non-nil field wins, in sorted order). `perceivedEfforts` (keyed by session id)
    /// overrides the record's RPE. RPE stays a separate field: it is never folded into loads.
    public static func makeInputs(asOfDay: Int,
                                  days: [TrainingDayRecord],
                                  sleep: [TrainingSleepRecord] = [],
                                  workouts: [TrainingWorkoutRecord] = [],
                                  perceivedEfforts: [String: Int] = [:],
                                  references: TrainingReferences = TrainingReferences()) -> TrainingInputs? {
        let dayRows = days.filter { $0.day <= asOfDay }
            .sorted { ($0.day, $0.source ?? "") < ($1.day, $1.source ?? "") }

        let loads: [TrainingDailyLoad] = dayRows.compactMap { r in
            guard let v = finite(r.strain), v >= 0 else { return nil }
            return TrainingDailyLoad(day: r.day, value: v,
                                     confidence: r.strainConfidence.map { TrainingConfidence(engineString: $0) },
                                     source: r.source)
        }
        let recovery: [TrainingRecoveryDay] = dayRows.compactMap { r in
            guard let s = finite(r.recovery), (0...100).contains(s) else { return nil }
            return TrainingRecoveryDay(day: r.day, score: s,
                                       confidence: TrainingConfidence(engineString: r.recoveryConfidence),
                                       experimentalLabel: r.recoveryExperimentalLabel)
        }
        let nights: [TrainingSleepNight] = sleep.filter { $0.day <= asOfDay }
            .sorted { ($0.day, $0.source ?? "") < ($1.day, $1.source ?? "") }
            .compactMap { r in
                let duration = finite(r.totalSleepMin).flatMap { $0 > 0 ? $0 : nil }
                let efficiency = finite(r.efficiency).flatMap { (0...1).contains($0) ? $0 : nil }
                let awakenings = r.disturbances.flatMap { $0 >= 0 ? $0 : nil }
                guard duration != nil || efficiency != nil else { return nil }
                return TrainingSleepNight(day: r.day, durationMinutes: duration, efficiency: efficiency,
                                          awakenings: awakenings, coverage: finite(r.coverage), source: r.source)
            }

        var sessionsByID: [String: TrainingSession] = [:]
        let sortedWorkouts = workouts.filter { $0.day <= asOfDay && !$0.id.isEmpty }
            .sorted { ($0.day, $0.startTs, $0.id, $0.source ?? "") < ($1.day, $1.startTs, $1.id, $1.source ?? "") }
        for w in sortedWorkouts {
            let seconds = w.durationS ?? (w.endTs - w.startTs)
            let rpe = (perceivedEfforts[w.id] ?? w.perceivedEffort).flatMap { (1...10).contains($0) ? Double($0) : nil }
            let session = TrainingSession(
                id: w.id, day: w.day, sport: sport(kind: w.kind, sportType: w.sportType),
                startTime: Double(w.startTs),
                durationMinutes: seconds > 0 ? Double(seconds) / 60 : nil,
                cardioLoad: finite(w.strain).flatMap { $0 >= 0 ? $0 : nil },
                perceivedExertion: rpe, source: w.source)
            if var existing = sessionsByID[w.id] {
                existing.durationMinutes = existing.durationMinutes ?? session.durationMinutes
                existing.cardioLoad = existing.cardioLoad ?? session.cardioLoad
                existing.perceivedExertion = existing.perceivedExertion ?? session.perceivedExertion
                sessionsByID[w.id] = existing
            } else {
                sessionsByID[w.id] = session
            }
        }
        let sessions = sessionsByID.values.sorted {
            ($0.day, $0.startTime ?? 0, $0.id) < ($1.day, $1.startTime ?? 0, $1.id)
        }

        guard !loads.isEmpty || !recovery.isEmpty || !nights.isEmpty || !sessions.isEmpty else { return nil }
        return TrainingInputs(asOfDay: asOfDay, dailyLoads: loads, sessions: sessions, sleep: nights,
                              recovery: recovery, references: references)
    }

    /// Sport category from a HealthKit activity raw value first, then the stored kind label.
    public static func sport(kind: String?, sportType: Int?) -> TrainingSport {
        switch sportType {
        case 37: return .run
        case 46: return .swim
        case 20, 50: return .strength
        case .some: return .other
        case nil: break
        }
        switch kind?.lowercased() {
        case "running", "run": return .run
        case "swimming", "swim": return .swim
        case "strength", "functionalfitness": return .strength
        default: return .other
        }
    }

    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
}
