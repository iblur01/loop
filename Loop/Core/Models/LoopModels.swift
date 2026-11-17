import Foundation
import LoopStrapEngine
import WhoopStore

struct LoopCache: Codable, Equatable {
    var daily: [DailySnapshot]
    var sleepSessions: [SleepSession]
    var workoutSessions: [WorkoutSession]
    var stress: StressSnapshot?
    var hrSamples: [HeartRateSample]
    var summary: ServerSummary?
    var updatedAt: Date?
    /// Decoded-row count at the time this cache was computed. Persisted so a relaunch with
    /// unchanged raw data skips the full recompute (P2): the in-memory-only watermark forced
    /// a 60-day recompute on every cold start. `nil` means "never computed / unknown".
    var computedRowCount: Int?
    /// Per-day decoded-row fingerprint (YYYY-MM-DD → count) at the last compute. Drives the
    /// incremental recompute: only days whose count changed (plus everything after) are re-run.
    var dayCounts: [String: Int]?
    /// Multiplicateur de difficulté du strain effectif au dernier calcul. Persisté ICI (et donc
    /// inclus dans le backup) en plus de UserDefaults : sur iOS, UserDefaults ne survit pas à une
    /// suppression+réinstallation, alors que le backup (cache.json) si — au restore, on réinjecte
    /// cette valeur dans UserPreferences pour retrouver le réglage.
    var strainDifficulty: Double?
    /// Séances d'exercice rejetées par l'utilisateur — filtrées du résultat à chaque recalcul.
    var rejectedWorkouts: [WorkoutRejection]?
    /// Fuseau IANA de chaque jour local calculé (YYYY-MM-DD → identifiant). Un jour passé garde
    /// son fuseau d'origine au recalcul ; absent dans les caches antérieurs au moteur v6.
    var dayTimeZones: [String: String]?
    /// Set only after a full recomputation with persisted express markers. Older caches may
    /// contain an express day whose provisional status was lost during encoding.
    var expressMigrationComplete: Bool = false

    static let empty = LoopCache(
        daily: [],
        sleepSessions: [],
        workoutSessions: [],
        stress: nil,
        hrSamples: [],
        summary: nil,
        updatedAt: nil,
        computedRowCount: nil,
        dayCounts: nil
    )

    init(
        daily: [DailySnapshot],
        sleepSessions: [SleepSession],
        workoutSessions: [WorkoutSession],
        stress: StressSnapshot?,
        hrSamples: [HeartRateSample],
        summary: ServerSummary?,
        updatedAt: Date?,
        computedRowCount: Int? = nil,
        dayCounts: [String: Int]? = nil,
        strainDifficulty: Double? = nil,
        rejectedWorkouts: [WorkoutRejection]? = nil,
        dayTimeZones: [String: String]? = nil
    ) {
        self.daily = daily
        self.sleepSessions = sleepSessions
        self.workoutSessions = workoutSessions
        self.stress = stress
        self.hrSamples = hrSamples
        self.summary = summary
        self.updatedAt = updatedAt
        self.computedRowCount = computedRowCount
        self.dayCounts = dayCounts
        self.strainDifficulty = strainDifficulty
        self.rejectedWorkouts = rejectedWorkouts
        self.dayTimeZones = dayTimeZones
    }

    private enum CodingKeys: String, CodingKey {
        case daily
        case sleepSessions
        case workoutSessions
        case stress
        case hrSamples
        case summary
        case updatedAt
        case computedRowCount
        case dayCounts
        case strainDifficulty
        case rejectedWorkouts
        case dayTimeZones
        case expressMigrationComplete
    }

    // Custom decoder to gracefully handle older cache.json shapes on disk. `decodeIfPresent`
    // still throws when a present key has an incompatible shape, so each field is isolated:
    // one stale server-shaped field must not make the whole cache load as `.empty`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        daily = (try? container.decode([DailySnapshot].self, forKey: .daily)) ?? []
        sleepSessions = (try? container.decode([SleepSession].self, forKey: .sleepSessions)) ?? []
        workoutSessions = (try? container.decode([WorkoutSession].self, forKey: .workoutSessions)) ?? []
        stress = try? container.decode(StressSnapshot.self, forKey: .stress)
        hrSamples = (try? container.decode([HeartRateSample].self, forKey: .hrSamples)) ?? []
        summary = try? container.decode(ServerSummary.self, forKey: .summary)
        updatedAt = try? container.decode(Date.self, forKey: .updatedAt)
        computedRowCount = try? container.decode(Int.self, forKey: .computedRowCount)
        dayCounts = try? container.decode([String: Int].self, forKey: .dayCounts)
        strainDifficulty = try? container.decode(Double.self, forKey: .strainDifficulty)
        rejectedWorkouts = try? container.decode([WorkoutRejection].self, forKey: .rejectedWorkouts)
        dayTimeZones = try? container.decode([String: String].self, forKey: .dayTimeZones)
        expressMigrationComplete = (try? container.decode(Bool.self, forKey: .expressMigrationComplete)) ?? false
    }
}

struct ServerSummary: Codable, Equatable {
    let hr: Int
    let rr: Int
    let events: Int
    let battery: Int
    let spo2: Int
    let skinTemp: Int
    let resp: Int
    let gravity: Int
    let batches: Int

    var sampleCount: Int {
        hr + rr + events + battery + spo2 + skinTemp + resp + gravity
    }
}

// MARK: - DailySnapshot

/// Local-first daily summary produced by LocalMetricsEngine from raw on-device data.
/// Replaces the server-shaped DailyMetric type. All fields from DailyResult are present
/// alongside advice fields extracted from AdviceResult. The `adviceSignals` array uses
/// LoopStrapEngine.AdviceSignal — no local redefinition.
struct DailySnapshot: Codable, Identifiable, Equatable {
    // MARK: Identity
    /// ISO date string YYYY-MM-DD — primary key, aligns with DailyResult.date.
    let date: String
    var id: String { date }

    // MARK: Sleep fields (from DailyResult)
    let totalSleepMin: Double?
    let efficiency: Double?
    let deepMin: Double?
    let remMin: Double?
    let lightMin: Double?
    let disturbances: Int?
    let sleepStart: Double?         // Unix seconds
    let sleepEnd: Double?           // Unix seconds
    let sleepScore: Double?

    // MARK: Biometric fields (from DailyResult)
    let restingHR: Double?
    let avgHrv: Double?
    let recovery: Double?           // 0–100
    let recoveryStatus: String      // "low" | "medium" | "high"
    let recoveryBand: String?       // "red" | "yellow" | "green" | nil
    let strain: Double?
    /// Contributions to recovery relative to the corresponding personal baseline.
    let recoveryZHrv: Double?
    let recoveryZRhr: Double?
    let recoveryZResp: Double?
    /// Observations Santé gardées séparément même les jours où le bracelet est prioritaire.
    let healthSDNN: RecoveryObservation?
    let healthRestingHR: RecoveryObservation?
    let recoveryHRVMetric: String?
    let recoveryHRVObservation: RecoveryObservation?
    let recoveryRHRObservation: RecoveryObservation?
    let strainObservedMinutes: Double?
    let strainBelowZoneMinutes: Double?
    let strainHRmaxUsed: Double?
    let strainRestingHRUsed: Double?
    /// Minutes par zone FC de la fenêtre de charge du jour (mêmes bornes Karvonen que le strain),
    /// avec FC repos/max utilisées et provenance du max. nil sans strain calculé (carte masquée).
    let heartRateZones: HeartRateZoneBreakdown?
    /// Fuseau IANA qui a défini les bornes de ce jour local (nil : cache UTC antérieur au v6).
    let timeZone: String?

    // MARK: Advice fields (from AdviceResult baselines)
    /// Sleep duration baseline in minutes — sourced from durBaseline.baseline in DailyEngine.
    let sleepTargetMin: Double?
    /// Recommended effort target — EFFORT_TARGET.target_strain from AdviceEngine.
    let targetStrain: Double?
    /// Confidence level of the effort target recommendation — "low" | "medium" | "high".
    let targetStrainConfidence: String?
    /// Whether recent overload was detected — EFFORT_TARGET.recent_overload.
    let recentOverload: Bool?

    // MARK: Structured advice signals
    /// Full list of advice signals produced by AdviceEngine for this day.
    let adviceSignals: [AdviceSignal]

    // MARK: Express preview
    /// `true` when this snapshot was produced by the fast `computeExpress()` pass
    /// (strain + stress only, no sleep detection yet). The UI uses this to render a
    /// "calcul en cours" state for recovery/sleep instead of a misleading 0. The next
    /// full compute pass replaces it with `isExpress = false` and the real values.
    /// Persisted so a restart cannot mistake a provisional result for a completed computation.
    var isExpress: Bool = false

    init(
        date: String,
        totalSleepMin: Double?, efficiency: Double?, deepMin: Double?, remMin: Double?,
        lightMin: Double?, disturbances: Int?, sleepStart: Double?, sleepEnd: Double?,
        sleepScore: Double?, restingHR: Double?, avgHrv: Double?, recovery: Double?,
        recoveryStatus: String, recoveryBand: String?, strain: Double?,
        sleepTargetMin: Double?, targetStrain: Double?, targetStrainConfidence: String?,
        recentOverload: Bool?, adviceSignals: [AdviceSignal],
        isExpress: Bool = false,
        recoveryZHrv: Double? = nil, recoveryZRhr: Double? = nil, recoveryZResp: Double? = nil,
        strainObservedMinutes: Double? = nil, strainBelowZoneMinutes: Double? = nil,
        strainHRmaxUsed: Double? = nil, strainRestingHRUsed: Double? = nil,
        healthSDNN: RecoveryObservation? = nil, healthRestingHR: RecoveryObservation? = nil,
        recoveryHRVMetric: String? = nil, recoveryHRVObservation: RecoveryObservation? = nil,
        recoveryRHRObservation: RecoveryObservation? = nil,
        heartRateZones: HeartRateZoneBreakdown? = nil,
        timeZone: String? = nil
    ) {
        self.date = date
        self.heartRateZones = heartRateZones
        self.timeZone = timeZone
        self.totalSleepMin = totalSleepMin
        self.efficiency = efficiency
        self.deepMin = deepMin
        self.remMin = remMin
        self.lightMin = lightMin
        self.disturbances = disturbances
        self.sleepStart = sleepStart
        self.sleepEnd = sleepEnd
        self.sleepScore = sleepScore
        self.restingHR = restingHR
        self.avgHrv = avgHrv
        self.recovery = recovery
        self.recoveryStatus = recoveryStatus
        self.recoveryBand = recoveryBand
        self.strain = strain
        self.recoveryZHrv = recoveryZHrv
        self.recoveryZRhr = recoveryZRhr
        self.recoveryZResp = recoveryZResp
        self.healthSDNN = healthSDNN
        self.healthRestingHR = healthRestingHR
        self.recoveryHRVMetric = recoveryHRVMetric
        self.recoveryHRVObservation = recoveryHRVObservation
        self.recoveryRHRObservation = recoveryRHRObservation
        self.strainObservedMinutes = strainObservedMinutes
        self.strainBelowZoneMinutes = strainBelowZoneMinutes
        self.strainHRmaxUsed = strainHRmaxUsed
        self.strainRestingHRUsed = strainRestingHRUsed
        self.sleepTargetMin = sleepTargetMin
        self.targetStrain = targetStrain
        self.targetStrainConfidence = targetStrainConfidence
        self.recentOverload = recentOverload
        self.adviceSignals = adviceSignals
        self.isExpress = isExpress
    }

    private enum CodingKeys: String, CodingKey {
        case date, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances
        case sleepStart, sleepEnd, sleepScore, restingHR, avgHrv, recovery, recoveryStatus
        case recoveryBand, strain, sleepTargetMin, targetStrain, targetStrainConfidence
        case recentOverload, adviceSignals, recoveryZHrv, recoveryZRhr, recoveryZResp
        case strainObservedMinutes, strainBelowZoneMinutes, strainHRmaxUsed, strainRestingHRUsed
        case healthSDNN, healthRestingHR, recoveryHRVMetric, recoveryHRVObservation, recoveryRHRObservation
        case timeZone, heartRateZones, isExpress
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        heartRateZones = try? c.decode(HeartRateZoneBreakdown.self, forKey: .heartRateZones)
        totalSleepMin = try? c.decode(Double.self, forKey: .totalSleepMin)
        efficiency = try? c.decode(Double.self, forKey: .efficiency)
        deepMin = try? c.decode(Double.self, forKey: .deepMin)
        remMin = try? c.decode(Double.self, forKey: .remMin)
        lightMin = try? c.decode(Double.self, forKey: .lightMin)
        disturbances = try? c.decode(Int.self, forKey: .disturbances)
        sleepStart = try? c.decode(Double.self, forKey: .sleepStart)
        sleepEnd = try? c.decode(Double.self, forKey: .sleepEnd)
        sleepScore = try? c.decode(Double.self, forKey: .sleepScore)
        restingHR = try? c.decode(Double.self, forKey: .restingHR)
        avgHrv = try? c.decode(Double.self, forKey: .avgHrv)
        recovery = try? c.decode(Double.self, forKey: .recovery)
        recoveryStatus = (try? c.decode(String.self, forKey: .recoveryStatus)) ?? "low"
        recoveryBand = try? c.decode(String.self, forKey: .recoveryBand)
        strain = try? c.decode(Double.self, forKey: .strain)
        recoveryZHrv = try? c.decode(Double.self, forKey: .recoveryZHrv)
        recoveryZRhr = try? c.decode(Double.self, forKey: .recoveryZRhr)
        recoveryZResp = try? c.decode(Double.self, forKey: .recoveryZResp)
        healthSDNN = try? c.decode(RecoveryObservation.self, forKey: .healthSDNN)
        healthRestingHR = try? c.decode(RecoveryObservation.self, forKey: .healthRestingHR)
        recoveryHRVMetric = try? c.decode(String.self, forKey: .recoveryHRVMetric)
        recoveryHRVObservation = try? c.decode(RecoveryObservation.self, forKey: .recoveryHRVObservation)
        recoveryRHRObservation = try? c.decode(RecoveryObservation.self, forKey: .recoveryRHRObservation)
        strainObservedMinutes = try? c.decode(Double.self, forKey: .strainObservedMinutes)
        strainBelowZoneMinutes = try? c.decode(Double.self, forKey: .strainBelowZoneMinutes)
        strainHRmaxUsed = try? c.decode(Double.self, forKey: .strainHRmaxUsed)
        strainRestingHRUsed = try? c.decode(Double.self, forKey: .strainRestingHRUsed)
        sleepTargetMin = try? c.decode(Double.self, forKey: .sleepTargetMin)
        targetStrain = try? c.decode(Double.self, forKey: .targetStrain)
        targetStrainConfidence = try? c.decode(String.self, forKey: .targetStrainConfidence)
        recentOverload = try? c.decode(Bool.self, forKey: .recentOverload)
        adviceSignals = (try? c.decode([AdviceSignal].self, forKey: .adviceSignals)) ?? []
        timeZone = try? c.decode(String.self, forKey: .timeZone)
        isExpress = (try? c.decode(Bool.self, forKey: .isExpress)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(totalSleepMin, forKey: .totalSleepMin)
        try c.encodeIfPresent(efficiency, forKey: .efficiency)
        try c.encodeIfPresent(deepMin, forKey: .deepMin)
        try c.encodeIfPresent(remMin, forKey: .remMin)
        try c.encodeIfPresent(lightMin, forKey: .lightMin)
        try c.encodeIfPresent(disturbances, forKey: .disturbances)
        try c.encodeIfPresent(sleepStart, forKey: .sleepStart)
        try c.encodeIfPresent(sleepEnd, forKey: .sleepEnd)
        try c.encodeIfPresent(sleepScore, forKey: .sleepScore)
        try c.encodeIfPresent(restingHR, forKey: .restingHR)
        try c.encodeIfPresent(avgHrv, forKey: .avgHrv)
        try c.encodeIfPresent(recovery, forKey: .recovery)
        try c.encode(recoveryStatus, forKey: .recoveryStatus)
        try c.encodeIfPresent(recoveryBand, forKey: .recoveryBand)
        try c.encodeIfPresent(strain, forKey: .strain)
        try c.encodeIfPresent(recoveryZHrv, forKey: .recoveryZHrv)
        try c.encodeIfPresent(recoveryZRhr, forKey: .recoveryZRhr)
        try c.encodeIfPresent(recoveryZResp, forKey: .recoveryZResp)
        try c.encodeIfPresent(healthSDNN, forKey: .healthSDNN)
        try c.encodeIfPresent(healthRestingHR, forKey: .healthRestingHR)
        try c.encodeIfPresent(recoveryHRVMetric, forKey: .recoveryHRVMetric)
        try c.encodeIfPresent(recoveryHRVObservation, forKey: .recoveryHRVObservation)
        try c.encodeIfPresent(recoveryRHRObservation, forKey: .recoveryRHRObservation)
        try c.encodeIfPresent(strainObservedMinutes, forKey: .strainObservedMinutes)
        try c.encodeIfPresent(strainBelowZoneMinutes, forKey: .strainBelowZoneMinutes)
        try c.encodeIfPresent(strainHRmaxUsed, forKey: .strainHRmaxUsed)
        try c.encodeIfPresent(strainRestingHRUsed, forKey: .strainRestingHRUsed)
        try c.encodeIfPresent(sleepTargetMin, forKey: .sleepTargetMin)
        try c.encodeIfPresent(targetStrain, forKey: .targetStrain)
        try c.encodeIfPresent(targetStrainConfidence, forKey: .targetStrainConfidence)
        try c.encodeIfPresent(recentOverload, forKey: .recentOverload)
        try c.encode(adviceSignals, forKey: .adviceSignals)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
        try c.encodeIfPresent(heartRateZones, forKey: .heartRateZones)
        try c.encode(isExpress, forKey: .isExpress)
    }
}

struct SleepSession: Codable, Identifiable, Equatable {
    var id: String { "\(startTs)-\(endTs)" }
    let startTs: Int
    let endTs: Int
    let efficiency: Double?
    let restingHr: Int?
    let avgHrv: Double?
    let stages: Data?
    let sourceName: String?
    /// Source Santé classée à l'import de la nuit (identité stable : productType, bundle, nom).
    /// nil pour une nuit bracelet ou une session mise en cache avant ce champ (repli sur le nom).
    let healthSource: HealthDataSource?

    init(startTs: Int, endTs: Int, efficiency: Double?, restingHr: Int?, avgHrv: Double?,
         stages: Data?, sourceName: String? = nil, healthSource: HealthDataSource? = nil) {
        self.startTs = startTs; self.endTs = endTs; self.efficiency = efficiency
        self.restingHr = restingHr; self.avgHrv = avgHrv; self.stages = stages
        self.sourceName = sourceName; self.healthSource = healthSource
    }
}

struct WorkoutSession: Codable, Identifiable, Equatable {
    var id: String { externalID.map { "healthkit-\($0)" } ?? "\(deviceId)-\(startTs)" }
    let deviceId: String
    let startTs: Int
    let endTs: Int
    let avgHr: Double?
    let peakHr: Int?
    let strain: Double?
    let kind: String?
    let durationS: Int?
    let caloriesKcal: Double?
    let sportType: Int?
    let distanceM: Double?
    let sourceName: String?
    let externalID: String?
    /// Session RPE (1-10) entered by the user; nil when absent. Re-attached at every compute.
    let perceivedEffort: Int?
    /// sRPE × minutes (arbitrary units). Separate self-reported proxy: never added to `strain`
    /// nor to the daily cardio strain. nil when RPE or duration is missing.
    let rpeLoad: Double?
    /// Minutes par zone FC (Karvonen, bornes de la charge cardio), FC repos/max utilisées et
    /// provenance du max, calculées par le moteur avec le strain de la séance. Seule source des
    /// zones affichées ; nil si la séance n'a pas de couverture FC suffisante (carte masquée).
    let heartRateZones: HeartRateZoneBreakdown?

    init(deviceId: String, startTs: Int, endTs: Int, avgHr: Double?, peakHr: Int?,
         strain: Double?, kind: String?, durationS: Int?, caloriesKcal: Double?,
         sportType: Int? = nil, distanceM: Double? = nil, sourceName: String? = nil,
         externalID: String? = nil, perceivedEffort: Int? = nil, rpeLoad: Double? = nil,
         heartRateZones: HeartRateZoneBreakdown? = nil) {
        self.deviceId = deviceId; self.startTs = startTs; self.endTs = endTs
        self.avgHr = avgHr; self.peakHr = peakHr; self.strain = strain; self.kind = kind
        self.durationS = durationS; self.caloriesKcal = caloriesKcal
        self.sportType = sportType; self.distanceM = distanceM
        self.sourceName = sourceName; self.externalID = externalID
        self.perceivedEffort = perceivedEffort; self.rpeLoad = rpeLoad
        self.heartRateZones = heartRateZones
    }

    /// Key of this session in `workout_perceived_effort` (shared with the RPE entry UI).
    var perceivedEffortKey: String {
        WorkoutPerceivedEffort.workoutKey(externalID: externalID, deviceId: deviceId, startTs: startTs)
    }

    /// Copy carrying `rpe` and its sRPE load; other fields (including `strain`) unchanged.
    func withPerceivedEffort(_ rpe: Int?) -> WorkoutSession {
        let seconds = durationS ?? (endTs - startTs)
        let load = rpe.flatMap { sessionRPELoad(perceivedExertion: Double($0), durationMinutes: Double(seconds) / 60) }
        return WorkoutSession(deviceId: deviceId, startTs: startTs, endTs: endTs, avgHr: avgHr, peakHr: peakHr,
                              strain: strain, kind: kind, durationS: durationS, caloriesKcal: caloriesKcal,
                              sportType: sportType, distanceM: distanceM, sourceName: sourceName,
                              externalID: externalID, perceivedEffort: rpe, rpeLoad: load,
                              heartRateZones: heartRateZones)
    }
}

/// Séance d'exercice rejetée par l'utilisateur (faux positif). Persistée dans `LoopCache` (donc
/// incluse au backup) et ré-appliquée à chaque recalcul : les séances sont re-détectées depuis le
/// HR à chaque compute, donc sans cette liste un faux positif rejeté réapparaîtrait. Sert aussi de
/// jeu d'étiquettes pour calibrer la détection avec le temps.
struct WorkoutRejection: Codable, Equatable {
    let startTs: Int
    let endTs: Int

    /// Vrai si `session` recouvre cette rejection sur ≥ 50 % de sa durée — match tolérant au léger
    /// drift des bornes entre deux détections incrémentales.
    func matches(_ session: WorkoutSession) -> Bool {
        let overlap = max(0, min(endTs, session.endTs) - max(startTs, session.startTs))
        let dur = max(1, session.endTs - session.startTs)
        return Double(overlap) / Double(dur) >= 0.5
    }
}

struct StressSnapshot: Codable, Equatable {
    let date: String
    let latest: StressPoint?
    let timeline: [StressPoint]
    let summary: StressSummary
}

struct StressPoint: Codable, Identifiable, Equatable {
    var id: String { "\(ts)" }
    let ts: Int
    let score: Double
    let nonActivityScore: Double?
    let hrBpm: Double?
    let rmssdMs: Double?
    let movementIntensity: Double?
    let context: String?
}

struct StressSummary: Codable, Equatable {
    let avgScore: Double?
    let avgNonActivityScore: Double?
    let maxScore: Double?
    let highMinutes: Double
    let activityMinutes: Double
}

struct HeartRateSample: Codable, Identifiable, Equatable {
    var id: String { "\(ts)" }
    let ts: Int
    let bpm: Int
}
