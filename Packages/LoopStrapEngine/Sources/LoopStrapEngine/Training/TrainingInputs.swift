import Foundation

// MARK: - Training inputs
//
// Pure value types describing, per day, the structured facts Loop has already
// computed. No UI, no I/O, no HealthKit. A missing value is always `nil`, never 0.
//
// Day convention: every `day` is an integer day ordinal chosen by the caller
// (typically the number of local calendar days since 1970-01-01). Only
// differences between days and the Monday-based week bucketing in
// `TrainingCalendar` depend on it, so the module stays independent of any
// time zone handling.

/// Sport categories handled by the training module.
public enum TrainingSport: String, Codable, Sendable, CaseIterable, Hashable {
    case run
    case swim
    case strength
    case other

    /// Whether a heart-rate based intensity (cardio load per hour) is meaningful.
    /// Swimming (unreliable optical HR in water) and strength (HR does not reflect
    /// muscular load) deliberately do not claim it.
    public var usesHeartRateIntensity: Bool {
        switch self {
        case .run, .other: return true
        case .swim, .strength: return false
        }
    }
}

/// Confidence tier, mirroring the `"low" | "medium" | "high"` strings used by the engine.
public enum TrainingConfidence: String, Codable, Sendable, Comparable, Hashable, CaseIterable {
    case low
    case medium
    case high

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: TrainingConfidence, rhs: TrainingConfidence) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Converts the engine's string confidence (`RecoveryResult.confidence`,
    /// `AdviceSignal.confidence`). Unknown or absent strings map to `.low`.
    public init(engineString: String?) {
        self = engineString.flatMap { TrainingConfidence(rawValue: $0) } ?? .low
    }

    static func capped(_ value: TrainingConfidence, at limit: TrainingConfidence) -> TrainingConfidence {
        value < limit ? value : limit
    }
}

/// Daily cardio load (Loop strain-like value) with its confidence and source.
public struct TrainingDailyLoad: Codable, Equatable, Sendable {
    public var day: Int
    public var value: Double?
    public var confidence: TrainingConfidence?
    public var source: String?

    public init(day: Int, value: Double?, confidence: TrainingConfidence? = nil, source: String? = nil) {
        self.day = day
        self.value = value
        self.confidence = confidence
        self.source = source
    }
}

/// One training session. `id` identifies the effort across sources: two entries
/// with the same `id` are one session.
public struct TrainingSession: Codable, Equatable, Sendable {
    public var id: String
    public var day: Int
    public var sport: TrainingSport
    /// Start as Unix seconds. Optional; used to recognise the same effort recorded by two sources.
    public var startTime: Double?
    public var durationMinutes: Double?
    /// Session cardio load. Ignored for strength and swim aggregates.
    public var cardioLoad: Double?
    /// Perceived exertion on a 0...10 scale (session RPE), not a duration-weighted load.
    public var perceivedExertion: Double?
    public var source: String?

    public init(id: String, day: Int, sport: TrainingSport, startTime: Double? = nil,
                durationMinutes: Double? = nil, cardioLoad: Double? = nil,
                perceivedExertion: Double? = nil, source: String? = nil) {
        self.id = id
        self.day = day
        self.sport = sport
        self.startTime = startTime
        self.durationMinutes = durationMinutes
        self.cardioLoad = cardioLoad
        self.perceivedExertion = perceivedExertion
        self.source = source
    }

    /// sRPE x duration, via the engine's `sessionRPELoad`. `nil` when either input is missing.
    public var srpeLoad: Double? {
        guard let durationMinutes else { return nil }
        return sessionRPELoad(perceivedExertion: perceivedExertion, durationMinutes: durationMinutes)
    }
}

/// One night of sleep, attributed to the day of waking.
public struct TrainingSleepNight: Codable, Equatable, Sendable {
    public var day: Int
    public var durationMinutes: Double?
    /// Fraction in 0...1.
    public var efficiency: Double?
    public var awakenings: Int?
    /// Fraction of the night covered by data, 0...1.
    public var coverage: Double?
    public var source: String?

    public init(day: Int, durationMinutes: Double? = nil, efficiency: Double? = nil,
                awakenings: Int? = nil, coverage: Double? = nil, source: String? = nil) {
        self.day = day
        self.durationMinutes = durationMinutes
        self.efficiency = efficiency
        self.awakenings = awakenings
        self.coverage = coverage
        self.source = source
    }
}

/// Recovery score for a day (0...100). Experimental when `experimentalLabel` is set.
public struct TrainingRecoveryDay: Codable, Equatable, Sendable {
    public var day: Int
    public var score: Double?
    public var confidence: TrainingConfidence?
    /// Non-nil when the score comes from an experimental model (e.g. Watch SDNN relay).
    public var experimentalLabel: String?

    public init(day: Int, score: Double?, confidence: TrainingConfidence? = nil,
                experimentalLabel: String? = nil) {
        self.day = day
        self.score = score
        self.confidence = confidence
        self.experimentalLabel = experimentalLabel
    }

    public var isExperimental: Bool { experimentalLabel != nil }
}

/// Optional self-reported feeling, 1 (very bad) ... 5 (very good).
public struct TrainingFeelingDay: Codable, Equatable, Sendable {
    public var day: Int
    public var value: Double?

    public init(day: Int, value: Double?) {
        self.day = day
        self.value = value
    }
}

/// Personal reference expressed in MAD units, optionally taken from an existing `BaselineState`.
public struct TrainingReference: Codable, Equatable, Sendable {
    public var center: Double
    /// Scale equivalent to a raw median absolute deviation (> 0).
    public var madEquivalent: Double
    public var nValid: Int
    public var isTrusted: Bool

    public init(center: Double, madEquivalent: Double, nValid: Int, isTrusted: Bool) {
        self.center = center
        self.madEquivalent = madEquivalent
        self.nValid = nValid
        self.isTrusted = isTrusted
    }

    /// Reuses an existing Loop baseline. Returns `nil` when the baseline is not usable.
    public init?(baseline: BaselineState) {
        guard baseline.usable else { return nil }
        let scale = baseline.standardDeviation / 1.4826
        guard scale.isFinite, scale > 0 else { return nil }
        self.init(center: baseline.baseline, madEquivalent: scale,
                  nValid: baseline.nValid, isTrusted: baseline.trusted)
    }
}

/// Existing personal references to reuse instead of recomputing them from the window.
public struct TrainingReferences: Codable, Equatable, Sendable {
    /// Sleep duration reference, in minutes.
    public var sleepDuration: TrainingReference?
    /// Daily cardio load reference.
    public var cardioLoad: TrainingReference?

    public init(sleepDuration: TrainingReference? = nil, cardioLoad: TrainingReference? = nil) {
        self.sleepDuration = sleepDuration
        self.cardioLoad = cardioLoad
    }
}

/// Everything the training module needs. Order of the arrays is irrelevant.
public struct TrainingInputs: Codable, Equatable, Sendable {
    /// Last day included in the analysis ("today"). Entries after it are ignored.
    public var asOfDay: Int
    public var dailyLoads: [TrainingDailyLoad]
    public var sessions: [TrainingSession]
    public var sleep: [TrainingSleepNight]
    public var recovery: [TrainingRecoveryDay]
    public var feelings: [TrainingFeelingDay]
    public var references: TrainingReferences

    public init(asOfDay: Int, dailyLoads: [TrainingDailyLoad] = [], sessions: [TrainingSession] = [],
                sleep: [TrainingSleepNight] = [], recovery: [TrainingRecoveryDay] = [],
                feelings: [TrainingFeelingDay] = [], references: TrainingReferences = TrainingReferences()) {
        self.asOfDay = asOfDay
        self.dailyLoads = dailyLoads
        self.sessions = sessions
        self.sleep = sleep
        self.recovery = recovery
        self.feelings = feelings
        self.references = references
    }
}

// MARK: - Calendar

/// Monday-based week bucketing for day ordinals counted from 1970-01-01 (a Thursday).
public enum TrainingCalendar {
    public static func weekIndex(forDay day: Int) -> Int {
        TrainingMath.floorDiv(day + 3, 7)
    }

    public static func weekStartDay(forWeek week: Int) -> Int {
        week * 7 - 3
    }
}

// MARK: - Normalised dataset

/// Sanitised, de-duplicated, order-independent view of `TrainingInputs`.
struct TrainingDataset {
    struct LoadPoint: Equatable {
        var value: Double
        var confidence: TrainingConfidence?
        var source: String?
    }

    let asOfDay: Int
    var loads: [Int: LoadPoint] = [:]
    var sessions: [TrainingSession] = []
    var sleep: [Int: TrainingSleepNight] = [:]
    var recovery: [Int: TrainingRecoveryDay] = [:]
    var feelings: [Int: Double] = [:]
    let references: TrainingReferences

    /// Earliest day carrying any usable data.
    var firstDay: Int? {
        var days: [Int] = []
        days.append(contentsOf: loads.keys)
        days.append(contentsOf: sleep.keys)
        days.append(contentsOf: recovery.keys)
        days.append(contentsOf: feelings.keys)
        days.append(contentsOf: sessions.map { $0.day })
        return days.min()
    }

    init(_ input: TrainingInputs) {
        asOfDay = input.asOfDay
        references = input.references

        // Daily loads: one value per day, never summed (duplicates may be the same measure).
        let loadEntries = input.dailyLoads
            .filter { $0.day <= input.asOfDay }
            .compactMap { entry -> (Int, LoadPoint)? in
                guard let v = entry.value, v.isFinite, v >= 0 else { return nil }
                return (entry.day, LoadPoint(value: v, confidence: entry.confidence, source: entry.source))
            }
        for (day, point) in loadEntries {
            if let existing = loads[day] {
                loads[day] = TrainingDataset.preferredLoad(existing, point)
            } else {
                loads[day] = point
            }
        }

        // Sleep
        for raw in input.sleep where raw.day <= input.asOfDay {
            let night = TrainingDataset.sanitize(raw)
            guard night.durationMinutes != nil || night.efficiency != nil
                    || night.awakenings != nil else { continue }
            if let existing = sleep[night.day] {
                sleep[night.day] = TrainingDataset.preferredSleep(existing, night)
            } else {
                sleep[night.day] = night
            }
        }

        // Recovery
        for raw in input.recovery where raw.day <= input.asOfDay {
            guard let s = raw.score, s.isFinite, (0...100).contains(s) else { continue }
            if let existing = recovery[raw.day] {
                recovery[raw.day] = TrainingDataset.preferredRecovery(existing, raw)
            } else {
                recovery[raw.day] = raw
            }
        }

        // Feelings: mean of the day's valid entries (sorted so the sum is order independent).
        var feelingBuckets: [Int: [Double]] = [:]
        for raw in input.feelings where raw.day <= input.asOfDay {
            guard let v = raw.value, v.isFinite, (1...5).contains(v) else { continue }
            feelingBuckets[raw.day, default: []].append(v)
        }
        for (day, values) in feelingBuckets {
            if let m = TrainingMath.mean(values) { feelings[day] = m }
        }

        sessions = TrainingDataset.dedupe(input.sessions.filter { $0.day <= input.asOfDay })
    }

    // MARK: Series

    func series(_ metric: TrainingMetric) -> [Int: Double] {
        switch metric {
        case .cardioLoad:
            return loads.mapValues { $0.value }
        case .sleepDuration:
            return sleep.compactMapValues { $0.durationMinutes }
        case .sleepEfficiency:
            return sleep.compactMapValues { $0.efficiency }
        case .recoveryScore:
            return recovery.compactMapValues { $0.score }
        }
    }

    // MARK: Sanitising

    private static func sanitize(_ s: TrainingSleepNight) -> TrainingSleepNight {
        var n = s
        if let d = n.durationMinutes, !(d.isFinite && d > 0 && d <= 1440) { n.durationMinutes = nil }
        if let e = n.efficiency, !(e.isFinite && (0...1).contains(e)) { n.efficiency = nil }
        if let a = n.awakenings, a < 0 { n.awakenings = nil }
        if let c = n.coverage, !(c.isFinite && (0...1).contains(c)) { n.coverage = nil }
        return n
    }

    private static func sanitize(_ s: TrainingSession) -> TrainingSession {
        var n = s
        if let d = n.durationMinutes, !(d.isFinite && d > 0 && d <= 1440) { n.durationMinutes = nil }
        if let c = n.cardioLoad, !(c.isFinite && c >= 0) { n.cardioLoad = nil }
        if let r = n.perceivedExertion, !(r.isFinite && (0...10).contains(r)) { n.perceivedExertion = nil }
        if let t = n.startTime, !t.isFinite { n.startTime = nil }
        return n
    }

    // MARK: Deterministic preferences

    private static func preferredLoad(_ a: LoadPoint, _ b: LoadPoint) -> LoadPoint {
        let ca = a.confidence?.rank ?? -1
        let cb = b.confidence?.rank ?? -1
        if ca != cb { return ca > cb ? a : b }
        let sa = a.source ?? ""
        let sb = b.source ?? ""
        if sa != sb { return sa < sb ? a : b }
        return a.value <= b.value ? a : b
    }

    private static func preferredSleep(_ a: TrainingSleepNight, _ b: TrainingSleepNight) -> TrainingSleepNight {
        let ka = (a.coverage ?? -1, a.durationMinutes ?? -1)
        let kb = (b.coverage ?? -1, b.durationMinutes ?? -1)
        if ka.0 != kb.0 { return ka.0 > kb.0 ? a : b }
        if ka.1 != kb.1 { return ka.1 > kb.1 ? a : b }
        return (a.source ?? "") <= (b.source ?? "") ? a : b
    }

    private static func preferredRecovery(_ a: TrainingRecoveryDay, _ b: TrainingRecoveryDay) -> TrainingRecoveryDay {
        let ca = a.confidence?.rank ?? -1
        let cb = b.confidence?.rank ?? -1
        if ca != cb { return ca > cb ? a : b }
        return (a.score ?? 0) <= (b.score ?? 0) ? a : b
    }

    // MARK: Session de-duplication

    private static func completeness(_ s: TrainingSession) -> Int {
        (s.cardioLoad != nil ? 1 : 0) + (s.perceivedExertion != nil ? 1 : 0)
            + (s.durationMinutes != nil ? 1 : 0) + (s.startTime != nil ? 1 : 0)
    }

    private static func sessionOrder(_ a: TrainingSession, _ b: TrainingSession) -> Bool {
        if a.day != b.day { return a.day < b.day }
        let ta = a.startTime ?? Double.greatestFiniteMagnitude
        let tb = b.startTime ?? Double.greatestFiniteMagnitude
        if ta != tb { return ta < tb }
        if a.sport.rawValue != b.sport.rawValue { return a.sport.rawValue < b.sport.rawValue }
        if a.id != b.id { return a.id < b.id }
        return (a.source ?? "") < (b.source ?? "")
    }

    /// Merges two records of the same effort: the more complete one wins, missing fields are filled.
    private static func merge(_ a: TrainingSession, _ b: TrainingSession) -> TrainingSession {
        let ca = completeness(a)
        let cb = completeness(b)
        let primary: TrainingSession
        let secondary: TrainingSession
        if ca != cb {
            primary = ca > cb ? a : b
            secondary = ca > cb ? b : a
        } else if sessionOrder(a, b) {
            primary = a
            secondary = b
        } else {
            primary = b
            secondary = a
        }
        var merged = primary
        if merged.startTime == nil { merged.startTime = secondary.startTime }
        if merged.durationMinutes == nil { merged.durationMinutes = secondary.durationMinutes }
        if merged.cardioLoad == nil { merged.cardioLoad = secondary.cardioLoad }
        if merged.perceivedExertion == nil { merged.perceivedExertion = secondary.perceivedExertion }
        return merged
    }

    /// Same effort recorded twice: same day and sport, both with known start and duration,
    /// and an overlap covering at least 80 % of the shorter one. Different sports or
    /// non-overlapping sessions on the same day stay distinct.
    private static func isSameEffort(_ a: TrainingSession, _ b: TrainingSession) -> Bool {
        guard a.day == b.day, a.sport == b.sport,
              let sa = a.startTime, let sb = b.startTime,
              let da = a.durationMinutes, let db = b.durationMinutes else { return false }
        let ea = sa + da * 60
        let eb = sb + db * 60
        let overlap = min(ea, eb) - max(sa, sb)
        let shorter = min(da, db) * 60
        guard shorter > 0 else { return false }
        return overlap >= 0.8 * shorter
    }

    static func dedupe(_ raw: [TrainingSession]) -> [TrainingSession] {
        var byID: [String: TrainingSession] = [:]
        for s in raw.map({ sanitize($0) }).sorted(by: sessionOrder) {
            if let existing = byID[s.id] {
                byID[s.id] = merge(existing, s)
            } else {
                byID[s.id] = s
            }
        }
        var kept: [TrainingSession] = []
        for s in byID.values.sorted(by: sessionOrder) {
            if let i = kept.firstIndex(where: { isSameEffort($0, s) }) {
                kept[i] = merge(kept[i], s)
            } else {
                kept.append(s)
            }
        }
        return kept.sorted(by: sessionOrder)
    }
}

/// Metrics for which personal trends and change detection are available.
public enum TrainingMetric: String, Codable, Sendable, CaseIterable, Hashable {
    case cardioLoad
    case sleepDuration
    case sleepEfficiency
    case recoveryScore

    /// Floor for the MAD so a very stable series does not inflate deviations.
    var minimumMAD: Double {
        switch self {
        case .cardioLoad: return 0.5
        case .sleepDuration: return 10      // minutes
        case .sleepEfficiency: return 0.01  // fraction
        case .recoveryScore: return 3
        }
    }
}
