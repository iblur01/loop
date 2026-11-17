import Foundation
import WhoopStore
import WhoopProtocol
import LoopStrapEngine
import os

private enum ComputeInputError: LocalizedError {
    case truncated(String)
    case invalidMaximumHeartRate
    var errorDescription: String? {
        switch self {
        case .truncated(let stream): return "Lecture incomplète : limite atteinte pour \(stream)."
        case .invalidMaximumHeartRate: return "La fréquence cardiaque maximale renseignée est invalide."
        }
    }
}

// MARK: - LocalMetricsEngine

struct LocalComputeResult {
    let daily: [DailySnapshot]
    let sleepSessions: [SleepSession]
    let workoutSessions: [WorkoutSession]
    let stress: StressSnapshot?
    let hrSamples: [HeartRateSample]
    /// Local-day zone registry (YYYY-MM-DD → IANA id) used for these surfaces. Persisted with
    /// the cache so a past day keeps its original zone on later recomputes.
    var dayTimeZones: [String: String] = [:]
}

/// Changes to source priorities and algorithm contracts invalidate persisted projections.
/// `maxHeartRate` is the explicit override (replay `--max-hr`, tests) and wins over
/// `personalMaxHeartRate` (user entry, resolved by the caller).
/// The workout component is the order the engine actually applies (`WorkoutSourcePriority.order`,
/// fixed): `priority.workouts` only drives the Santé report, merged at read time, so changing it
/// must not invalidate the persisted strain / timeline.
func healthComputeSettingsKey(_ priority: HealthSourcePriority, maxHeartRate: Double? = nil,
                              personalMaxHeartRate: MaxHeartRateReference? = nil, deviceId: String? = nil) -> String {
    let rules = priority.orders.keys.sorted().map { key in
        "\(key)=\((priority.orders[key] ?? []).map(\.rawValue).joined(separator: ","))"
    }.joined(separator: ";")
    let maxHR = MaxHeartRatePolicy.cacheKeyComponent(override: maxHeartRate, personal: personalMaxHeartRate)
    let workouts = WorkoutSourcePriority.order.map(\.rawValue).joined(separator: ",")
    return "@engine:v8-workouts|device=\(deviceId ?? "unknown")|maxHR=\(maxHR)|\(rules)|workouts=\(workouts)|fallback=\(priority.fallback.map(\.rawValue).joined(separator: ","))"
}

/// Surfaced by `computeExpress()` : strain + stress for today only, sans détection du
/// sommeil. `snapshot.isExpress == true` ; sleep/recovery restent `nil` jusqu'au pass full.
struct ExpressResult {
    let snapshot: DailySnapshot
    let stress: StressSnapshot?
    let hrSamples: [HeartRateSample]
}

/// Actor that orchestrates WhoopStore + DailyEngine + AdviceEngine to assemble
/// `[DailySnapshot]` from raw on-device data — the offline-first compute layer.
///
/// All CPU-intensive computation runs off the main thread (actor Swift pur, pas
/// @MainActor). Instantiated by `BLEConnectionManager.bootstrapStore()` and injected
/// into `LoopDataRepository` via `LoopApp.swift`.
actor LocalMetricsEngine {

    // MARK: - Dependencies

    private let store: WhoopStore
    nonisolated let deviceId: String
    nonisolated let maxHeartRateOverride: Double?
    private let priorityOverride: HealthSourcePriority?
    /// Explicit zone (tests, replay). nil = device zone, re-read at every compute.
    nonisolated let timeZoneOverride: TimeZone?
    /// Zones of already computed local days, restored from the cache (see `LocalDaySchedule`).
    private var dayZoneRegistry: [String: String] = [:]
    private var sourcePriority: HealthSourcePriority { priorityOverride ?? HealthReconciliationSettings().load() }
    private static let log = Logger(subsystem: "loop.engine", category: "LocalMetricsEngine")

    /// HRmax dérivé une fois par session pour le pass express (99.5e percentile du HR sur
    /// les ~14 derniers jours). Mis en cache sur l'actor : le strain express n'a pas besoin
    /// du pool global 60j (scan coûteux), et HRmax varie lentement. Le pass full recalcule
    /// le sien précisément depuis `allHRBpm`.
    private var expressHRmax: Double?

    /// HRmax (99.5e pctile du pool HR 60j) mis en cache entre runs. Calculé sur le chemin FULL
    /// (où tout le HR est déjà en mémoire dans `allInputs`) puis réutilisé par les recalculs
    /// INCRÉMENTAUX, qui sinon relisent les ~760k lignes HR de toute la fenêtre juste pour
    /// ré-estimer un HRmax qui ne bouge quasi pas (mesuré : 1129 ms/partiel). Le HRmax est une
    /// estimation lente par construction ; le figer entre deux fulls n'altère pas le strain de
    /// façon perceptible. Rafraîchi à chaque pass full.
    private var cachedFullHRmax: Double?
    private var hasCachedFullHRmax = false

    /// P6 — run a DB read and, on failure, LOG it (then fall back to `[]`) instead of swallowing
    /// the error with `try?`. A swallowed read error looks identical to "no data" downstream and
    /// surfaces as silent 0-metrics; logging makes the real cause visible in the console while
    /// keeping compute resilient for the other days.
    private func loggedRead<T>(_ label: String, _ op: () async throws -> [T]) async -> [T] {
        let t0 = Date()
        do {
            let rows = try await op()
            let ms = Date().timeIntervalSince(t0) * 1000
            // Log only non-trivial reads to keep the noise down but surface slow scans.
            if ms > 50 {
                Self.log.info("read \(label, privacy: .public) \(rows.count, privacy: .public) lignes en \(Int(ms), privacy: .public)ms")
            }
            return rows
        } catch {
            Self.log.error("read \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Init

    init(store: WhoopStore, deviceId: String, priorityOverride: HealthSourcePriority? = nil,
         maxHeartRateOverride: Double? = nil, timeZone: TimeZone? = nil) {
        self.store = store
        self.deviceId = deviceId
        self.priorityOverride = priorityOverride
        self.maxHeartRateOverride = maxHeartRateOverride
        self.timeZoneOverride = timeZone
    }

    /// Reads the complete band series for a bounded interval. The primary key permits at most
    /// one sample per second and device, so this limit cannot silently truncate the interval.
    func heartRateSamples(from: Int, to: Int) async throws -> [HeartRateSample] {
        guard from <= to else { return [] }
        let rows = try await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: to - from + 1)
        return rows.map { HeartRateSample(ts: $0.ts, bpm: $0.bpm) }
    }

    // MARK: - Local day policy

    /// Zone defining "today" and every day not yet computed.
    nonisolated var currentTimeZone: TimeZone { timeZoneOverride ?? LocalDay.deviceZone }

    /// Local calendar day of `date` in the current zone ("today" for `Date()`).
    nonisolated func localDayKey(for date: Date = Date()) -> String {
        LocalDay.key(date.timeIntervalSince1970, in: currentTimeZone)
    }

    /// Fingerprint key: a change of device zone must trigger a recompute of today.
    nonisolated func zoneCacheKey() -> String { "@zone:\(currentTimeZone.identifier)" }

    /// Restores the persisted zone registry (cache.json) before any read keyed by day.
    func restoreDayTimeZones(_ registry: [String: String]) {
        dayZoneRegistry.merge(registry) { _, restored in restored }
    }

    private func schedule(now: Date, registry: [String: String]? = nil) -> LocalDaySchedule {
        LocalDaySchedule(currentZone: currentTimeZone, frozen: registry ?? dayZoneRegistry, now: now)
    }

    // MARK: - Public API

    /// Returns storage statistics from the underlying WhoopStore: total decoded rows,
    /// raw batches, raw storage bytes, and the latest HR sample timestamp (if any).
    func dbStats() async -> (decodedRows: Int, decodedRowsTotal: Int, rawBatches: Int, rawBytes: Int, latestTs: Int?) {
        let stats = (try? await store.storageStats(deviceId: deviceId)) ?? (decodedRows: 0, rawBatches: 0, rawBytes: 0)
        let total = (try? await store.storageStats()) ?? (decodedRows: 0, rawBatches: 0, rawBytes: 0)
        let latestTs = try? await store.latestHRSampleTs(deviceId: deviceId)
        return (decodedRows: stats.decodedRows, decodedRowsTotal: total.decodedRows, rawBatches: stats.rawBatches,
                rawBytes: stats.rawBytes, latestTs: latestTs)
    }

    func inputRevision() async throws -> (instance: String, revision: Int) {
        let token = try await store.inputRevisions()
        return (token.instance, token.revision)
    }

    /// Applications ayant produit une métrique Santé à n'importe quelle date importée.
    func healthSampleProducers(kind: HealthSampleKind) async throws -> [HealthSampleProducer] {
        try await store.healthSampleProducers(type: kind.rawValue)
    }

    /// Bulk-insert decoded streams into the local store, marking them synced. Retained as a
    /// generic seeding entry point (the former server-import caller has been removed).
    @discardableResult
    func importStreams(_ streams: Streams) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await store.insert(streams, deviceId: deviceId, markSynced: true)
    }

    /// Deletes all decoded-stream and derived-metric rows from the store.
    /// Returns total rows deleted.
    func purgeAll() async throws -> Int {
        try await store.deleteAllDecodedRows()
    }

    /// Compute daily snapshots for the last `days` calendar days.
    ///
    /// Orchestrates:
    ///   1. Load raw streams from WhoopStore for each day
    ///   2. `DailyEngine.compute()` → `DailyResult`
    ///   3. `AdviceEngine.compute()` → `AdviceResult`
    ///   4. Upsert advice signals into GRDB (idempotent)
    ///   5. Assemble `DailySnapshot`
    ///
    /// - Parameter days: Number of calendar days to compute (default 60).
    /// - Parameter onProgress: Optional callback called with (stage, completed, total) as work advances.
    ///   `stage` is a human-readable description of the current computation phase.
    ///   `total` = sleep precompute chunks + daily data load + snapshot assembly.
    ///   Called from the actor's executor — callers must hop to MainActor if needed.
    /// - Returns: Local compute surfaces sorted by date ascending where applicable.
    /// - Throws: WhoopStore I/O errors; module errors are suppressed via `try?`.
    /// Full recompute of the last `days` calendar days (no reuse). Thin wrapper over
    /// `computeCore` used by tests and any caller that wants an unconditional rebuild.
    func compute(days: Int = 60, strainDifficulty: Double? = nil, personalMaxHeartRate: MaxHeartRateReference? = nil,
                 now: Date = Date(), onProgress: ((String, Int, Int) -> Void)? = nil) async throws -> LocalComputeResult {
        try await computeCore(days: days, previous: nil, previousDayCounts: nil,
                              forceFull: true, strainDifficulty: strainDifficulty,
                              personalMaxHeartRate: personalMaxHeartRate, now: now, onProgress: onProgress).result
    }

    // MARK: - Perceived effort (session RPE)

    /// Façade RPE adossée à la base de l'app, pour la feuille de saisie. Sans accès disque ici.
    nonisolated var perceivedEffortStore: PerceivedEffortStore { PerceivedEffortStore(store: store) }

    /// Façade de saisie manuelle des séances (lignes `external_workout` marquées manuelles).
    nonisolated var manualWorkoutStore: ManualWorkoutStore { ManualWorkoutStore(store: store) }

    /// Attaches the stored session RPE (`workout_perceived_effort`) and its sRPE × minutes load.
    /// Display-only training-load proxy: never added to the daily cardio strain. A missing or
    /// unreadable entry leaves both fields nil.
    func attachPerceivedEfforts(_ sessions: [WorkoutSession]) async -> [WorkoutSession] {
        guard !sessions.isEmpty else { return sessions }
        let efforts: [String: WorkoutPerceivedEffort]
        do {
            efforts = try await store.perceivedEfforts(workoutIds: sessions.map(\.perceivedEffortKey))
        } catch {
            Self.log.error("read perceived effort failed: \(error.localizedDescription, privacy: .public)")
            efforts = [:]
        }
        return sessions.map { $0.withPerceivedEffort(efforts[$0.perceivedEffortKey]?.rpe) }
    }

    /// Incremental compute. Recomputes only the days whose decoded-row fingerprint changed since
    /// the last run (`previousDayCounts`), plus everything after the earliest change (forward
    /// dependency: later days' baselines fold from earlier days). Clean earlier days are reused
    /// verbatim from `previous`. The global HRmax pool is read once over the whole range so the
    /// reused days still contribute to it exactly — no precision loss vs a full recompute.
    ///
    /// - Parameters:
    ///   - strainDifficulty: Optional multiplier for strain sensitivity (0.3-2.0).
    ///     Lower values = easier (less strain accumulation), higher = harder.
    /// - Returns: the merged surfaces AND the fresh per-day fingerprint to persist for next time.
    func computeCore(
        days: Int = 60,
        previous: LocalComputeResult?,
        previousDayCounts: [String: Int]?,
        forceFull: Bool,
        strainDifficulty: Double? = nil,
        rejectedRanges: [(start: Int, end: Int)] = [],
        personalMaxHeartRate: MaxHeartRateReference? = nil,
        now: Date = Date(),
        onProgress: ((String, Int, Int) -> Void)? = nil
    ) async throws -> (result: LocalComputeResult, dayCounts: [String: Int]) {
        if let maxHeartRateOverride,
           (!maxHeartRateOverride.isFinite || !CardioInputPolicy.heartRateBPM.contains(maxHeartRateOverride)) {
            throw ComputeInputError.invalidMaximumHeartRate
        }
        // Override (replay/tests) > personal reference (caller) > percentile estimate below.
        let fixedMaxHR = MaxHeartRatePolicy.fixedValue(override: maxHeartRateOverride, personal: personalMaxHeartRate)
        let maxHRSource = MaxHeartRatePolicy.source(override: maxHeartRateOverride, personal: personalMaxHeartRate)
        // Fenêtres rejetées (faux positifs sport) à exclure du strain, converties une fois.
        let strainExcludeRanges = rejectedRanges.map { (start: Double($0.start), end: Double($0.end)) }
        // Local calendar days (device zone; past days keep the zone recorded when they were
        // computed). One schedule drives day bounds, night attribution, strain, stress,
        // workouts, "today", cache keys and fingerprints — no layer buckets by UTC any more.
        // The persisted registry (previous result) wins over the actor copy.
        let registry = dayZoneRegistry.merging(previous?.dayTimeZones ?? [:]) { _, persisted in persisted }
        let schedule = schedule(now: now, registry: registry)
        func dayBounds(_ day: String) -> (from: Int, to: Int) { schedule.bounds(day) }
        let dates = schedule.days(count: days)
        guard !dates.isEmpty else {
            return (LocalComputeResult(daily: [], sleepSessions: [], workoutSessions: [], stress: nil, hrSamples: []), [:])
        }
        let resultRegistry = schedule.registry(recording: dates)

        // ── Per-day fingerprint: decoded-row count in each day window ─────────────
        let perfT0 = Date()
        PerfLog.reset("computeCore START full=\(forceFull) days=\(dates.count)")
        let fpStart = Date()
        let revisions = try await store.inputRevisions()
        let revisionKey = "@inputRevision:\(revisions.instance)"
        let settingsKey = healthComputeSettingsKey(sourcePriority, maxHeartRate: maxHeartRateOverride,
                                                   personalMaxHeartRate: personalMaxHeartRate, deviceId: deviceId)
        var currentDayCounts: [String: Int] = [revisionKey: revisions.revision, "@window:\(dates.last!)": 1,
                                               settingsKey: 1, "@zone:\(currentTimeZone.identifier)": 1]
        // Input revisions are recorded per UTC day by SQLite triggers; a local day's fingerprint
        // sums the (monotonic) revisions of every UTC day it intersects. Over-invalidation only.
        for date in dates {
            let b = dayBounds(date)
            currentDayCounts[date] = LocalDaySchedule.utcDays(from: b.from, to: b.to)
                .reduce(0) { $0 + (revisions.days[$1] ?? 0) }
        }
        PerfLog.emit("fingerprint queries=\(dates.count) \(PerfLog.ms(since: fpStart))ms")

        // ── Decide the dirty range [dirtyStart ..< end] ──────────────────────────
        // earliest date whose count differs from the persisted fingerprint (or is unknown).
        // Expanded back one day for the 30h sleep window spillover. Everything from there to
        // today is recomputed; strictly-earlier days are reused from `previous`.
        var dirtyStart = 0
        var firstDirtyDate = "—"
        if !forceFull, let previous, let previousDayCounts,
           previousDayCounts[revisionKey] != nil, previousDayCounts[settingsKey] == 1 {
            var earliest: Int?
            let previousZones = previous.dayTimeZones
            for (i, date) in dates.enumerated() {
                // A day whose zone changed (today after a trip, legacy UTC cache) is dirty too.
                if (currentDayCounts[date] ?? 0) != (previousDayCounts[date] ?? -1)
                    || previousZones[date] != resultRegistry[date] { earliest = i; break }
            }
            guard let earliest else {
                Self.log.info("compute incrémental: aucun jour modifié → réutilise le cache (0 recalcul)")
                PerfLog.emit("computeCore TOTAL \(PerfLog.ms(since: perfT0))ms NO-OP (cache réutilisé, 0 recalcul)")
                var reused = previous
                reused.dayTimeZones = resultRegistry
                reused = LocalComputeResult(daily: reused.daily, sleepSessions: reused.sleepSessions,
                    workoutSessions: await attachPerceivedEfforts(reused.workoutSessions),
                    stress: reused.stress, hrSamples: reused.hrSamples, dayTimeZones: reused.dayTimeZones)
                dayZoneRegistry = resultRegistry
                return (reused, currentDayCounts)
            }
            dirtyStart = max(0, earliest - 1)
            firstDirtyDate = dates[earliest]

            _ = previous   // (surfaces consumed below)
        }

        // Every daily strain uses the global HRmax. If it changes, reusing older days would
        // silently mix scores from different calibrations. On a cold actor the old value is
        // unknown, so rebuild once rather than assume it agrees with the persisted cache.
        if dirtyStart > 0 {
            guard hasCachedFullHRmax else {
                return try await computeCore(days: days, previous: previous, previousDayCounts: previousDayCounts,
                    forceFull: true, strainDifficulty: strainDifficulty, rejectedRanges: rejectedRanges,
                    personalMaxHeartRate: personalMaxHeartRate, now: now, onProgress: onProgress)
            }
            let from = dayBounds(dates.first!).from
            let to = dayBounds(dates.last!).to
            let band = try await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: 10_000_000)
            guard band.count < 10_000_000 else { throw ComputeInputError.truncated("historique FC") }
            let pool: [Double]
            if band.isEmpty {
                let health = try await healthEngineInputs(from: from, to: to, priority: sourcePriority)
                pool = health.hr.map(\.bpm)
            } else {
                pool = band.map { Double($0.bpm) }
            }
            let updatedMax = fixedMaxHR ?? estimateHRmax(hrHistory: pool, age: nil)
            if updatedMax != cachedFullHRmax {
                return try await computeCore(days: days, previous: previous, previousDayCounts: previousDayCounts,
                    forceFull: true, strainDifficulty: strainDifficulty, rejectedRanges: rejectedRanges,
                    personalMaxHeartRate: personalMaxHeartRate, now: now, onProgress: onProgress)
            }
        }

        let dirtyDates = Array(dates[dirtyStart...])
        let cleanDates = Array(dates[0..<dirtyStart])
        let cleanDateSet = Set(cleanDates)

        Self.log.info("""
            compute: forceFull=\(forceFull, privacy: .public) \
            previous=\(previous != nil, privacy: .public) \
            prevCounts=\(previousDayCounts?.count ?? -1, privacy: .public) \
            jours=\(dates.count, privacy: .public) dirty=\(dirtyDates.count, privacy: .public) \
            clean=\(cleanDates.count, privacy: .public) premierModifié=\(firstDirtyDate, privacy: .public)
            """)

        // ── 1. Load all DailyInputs for each date ────────────────────────────────
        var allInputs: [(date: String, inputs: DailyInputs)] = []
        var allSleepSessions: [SleepSession] = []
        var seenSleepSessionIds = Set<String>()
        var allWorkoutSessions: [WorkoutSession] = []
        var latestStress: StressSnapshot?
        var recentHRSamples: [HeartRateSample] = []

        // Reuse clean (unchanged) earlier days from the previous result, and seed `allInputs`
        // with reconstructed history entries so the dirty days' baseline folds see them.
        if dirtyStart > 0, let previous {
            allSleepSessions = previous.sleepSessions.filter {
                cleanDateSet.contains(schedule.day(containing: Double($0.endTs)))
            }
            allWorkoutSessions = previous.workoutSessions.filter {
                $0.externalID == nil && cleanDateSet.contains(schedule.day(containing: Double($0.startTs)))
            }
            recentHRSamples = previous.hrSamples
            latestStress = previous.stress
            for date in cleanDates {
                let snap = previous.daily.first { $0.date == date }
                allInputs.append((date: date, inputs: reconstructInputs(date: date, snapshot: snap, deviceId: deviceId)))
            }
        }

        // Progress bar weighted by DIRTY days processed (sleep + input-load + assembly).
        let progressTotal = max(1, dirtyDates.count * 3)
        var progressCompleted = 0
        let stageSleep = "Détection du sommeil"
        let stageInputs = "Chargement des données"
        let stageAssembly = "Calcul récupération & strain"

        // Sleep detection — PER-DAY window, same shape as the former server window but on the
        // LOCAL day: [day-1 18:00 local, next local midnight). The window choice is load-bearing: a wider window
        // (e.g. multi-day chunks) pulls an evening doze the previous night into the cluster and
        // shifts onset earlier. Detect on the day window, then keep the sessions that END on this
        // date (the server attributes the cluster ending on `day`). Dedup by id across windows.
        var detectedSleepSessions = detectSleep(streams: SleepStreams(hr: [], rr: [], resp: [], gravity: []))
        detectedSleepSessions.removeAll()

        // Per-day daily payload captured during the SAME pass as sleep detection: the 24h daily
        // slices (HR/RR/gravity) are filtered out of the already-loaded 30h sleep window, so the
        // former second `daily.*` reads disappear (B). DailyInputs needs the dedup'd session set
        // for its sleep summary, so it's assembled in a cheap post-dedup pass (no reads).
        struct PendingDay {
            let date: String
            let hrSeries: [(ts: Double, bpm: Double)]
            let rrSeries: [(ts: Double, rrMs: Double)]
            let gravitySeries: [(ts: Double, v: Double)]
            /// Band HR of the 6 h before the day (already in the sleep window), so a workout that
            /// started the previous day is recognised as such and not re-detected here.
            let headHR: [(ts: Double, bpm: Double)]
        }
        var pendingDays: [PendingDay] = []

        var sleepReadMs = 0.0
        var detectMs = 0.0
        // C: detectSleep par-nuit est une rafale CPU pure et indépendante d'une nuit à l'autre. On
        // traite les jours sales par paquets : lecture DB SÉRIE (l'actor sérialise le store) puis
        // détection PARALLÈLE du paquet sur l'exécuteur concurrent (Task.detached), bornée à
        // `sleepChunk` nuits pour plafonner la mémoire des fenêtres 30h tenues simultanément.
        let sleepChunk = 6
        var chunkStart = 0
        while chunkStart < dirtyDates.count {
            try Task.checkCancellation()
            await Task.yield()
            let chunk = Array(dirtyDates[chunkStart..<min(chunkStart + sleepChunk, dirtyDates.count)])

            // ── 1. Lectures SÉRIE + slices 24h (depuis la fenêtre 30h, pas de 2e read) ──
            struct DayRaw {
                let date: String
                let sleepToTs: Int
                let streams: SleepStreams
                let hrRows: [HRSample]
                let hrSeries: [(ts: Double, bpm: Double)]
                let rrSeries: [(ts: Double, rrMs: Double)]
                let gravitySeries: [(ts: Double, v: Double)]
                let headHR: [(ts: Double, bpm: Double)]
            }
            var raws: [DayRaw] = []
            let readStart = Date()
            for date in chunk {
                let (dayFrom, dayTo) = dayBounds(date)
                let sleepFromTs = dayFrom - 6 * 60 * 60   // veille 18:00 locale (lead = -6 h)
                let sleepToTs = dayTo                      // minuit local suivant - 1 s
                let winLimit = 250_000

                let sleepHRRaw = try await store.hrSamples(deviceId: deviceId, from: sleepFromTs, to: sleepToTs, limit: winLimit)
                let sleepRRRaw = try await store.rrIntervals(deviceId: deviceId, from: sleepFromTs, to: sleepToTs, limit: winLimit)
                let sleepRespRaw = try await store.respSamples(deviceId: deviceId, from: sleepFromTs, to: sleepToTs, limit: winLimit)
                let sleepGravityRaw = try await store.gravitySamples(deviceId: deviceId, from: sleepFromTs, to: sleepToTs, limit: winLimit)
                guard sleepHRRaw.count < winLimit, sleepRRRaw.count < winLimit,
                      sleepRespRaw.count < winLimit, sleepGravityRaw.count < winLimit else {
                    throw ComputeInputError.truncated("les signaux du \(date)")
                }
                let streams = SleepStreams(
                    hr: sleepHRRaw.map { (t: Double($0.ts), v: Double($0.bpm)) },
                    rr: sleepRRRaw.map { (t: Double($0.ts), v: Double($0.rrMs)) },
                    resp: sleepRespRaw.map { (t: Double($0.ts), v: Double($0.raw)) },
                    // gravity = per-record movement proxy (Python _gravity_deltas), NOT magnitude:
                    // magnitude is orientation-blind and over-detects stillness (rotations read as 0).
                    gravity: gravityDeltaProxy(sleepGravityRaw.map {
                        (t: Double($0.ts), x: $0.x, y: $0.y, z: $0.z)
                    })
                )
                // 24h daily slices from the SAME raw rows ([dayFrom, dayTo] ⊂ 30h window).
                let hrRows = sleepHRRaw.filter { $0.ts >= dayFrom && $0.ts <= dayTo }
                let hrSeries = hrRows.map { (ts: Double($0.ts), bpm: Double($0.bpm)) }
                let rrSeries = sleepRRRaw.filter { $0.ts >= dayFrom && $0.ts <= dayTo }
                    .map { (ts: Double($0.ts), rrMs: Double($0.rrMs)) }
                let gravitySeries = sleepGravityRaw.filter { $0.ts >= dayFrom && $0.ts <= dayTo }
                    .map { (ts: Double($0.ts), v: sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z)) }
                let headHR = sleepHRRaw.filter { $0.ts < dayFrom }.map { (ts: Double($0.ts), bpm: Double($0.bpm)) }
                raws.append(DayRaw(date: date, sleepToTs: sleepToTs, streams: streams,
                                   hrRows: hrRows, hrSeries: hrSeries, rrSeries: rrSeries,
                                   gravitySeries: gravitySeries, headHR: headHR))
            }
            sleepReadMs += Date().timeIntervalSince(readStart) * 1000

            // ── 2. Détection PARALLÈLE du paquet (off-actor), résultats remis en ordre ──
            let detStart = Date()
            let sessionsByIdx = await detectSleepBatch(raws.map { $0.streams })
            detectMs += Date().timeIntervalSince(detStart) * 1000

            // ── 3. Post-traitement SÉRIE en ordre du jour (accumulateurs actor) ──
            for (i, dr) in raws.enumerated() {
                for session in sessionsByIdx[i] {
                    // Rejette les sessions COUPÉES au bord supérieur de la fenêtre (≈ sleepToTs) :
                    // tête tronquée d'une nuit du jour SUIVANT, détectée entière dans sa fenêtre.
                    if session.end >= Double(dr.sleepToTs) - 120 { continue }
                    guard schedule.day(containing: session.end) == dr.date else { continue }
                    let id = "\(Int(session.start))-\(Int(session.end))"
                    guard seenSleepSessionIds.insert(id).inserted else { continue }
                    detectedSleepSessions.append(session)
                }
                progressCompleted += 1
                onProgress?(stageSleep, progressCompleted, progressTotal)

                if let stress = makeStressSnapshot(date: dr.date, hrSeries: dr.hrSeries,
                                                   rrSeries: dr.rrSeries, gravitySeries: dr.gravitySeries) {
                    latestStress = stress
                }
                recentHRSamples.append(contentsOf: dr.hrRows.suffix(240).map {
                    HeartRateSample(ts: $0.ts, bpm: $0.bpm)
                })
                pendingDays.append(PendingDay(date: dr.date, hrSeries: dr.hrSeries,
                                              rrSeries: dr.rrSeries, gravitySeries: dr.gravitySeries,
                                              headHR: dr.headHR))
                progressCompleted += 1
                onProgress?(stageInputs, progressCompleted, progressTotal)
            }
            chunkStart += sleepChunk
        }

        // Dédup global par CHEVAUCHEMENT : la fenêtre de 30h se recoupe avec celle du jour
        // voisin, donc une même nuit peut être détectée deux fois (une version tronquée dans
        // une fenêtre, la version entière dans l'autre) avec des fins différentes — le dédup
        // par (start,end) ne les voit pas comme identiques. Deux vrais sommeils ne se
        // chevauchent jamais dans le temps ; tout chevauchement = même sommeil physique. On
        // garde la session la plus longue (TST) du groupe qui se chevauche et on jette les
        // fragments. Les vraies siestes (pas de chevauchement avec la nuit) sont conservées.
        detectedSleepSessions = dedupOverlappingSleepSessions(
            detectedSleepSessions, start: { $0.start }, end: { $0.end }, tst: { $0.tst }
        )
        PerfLog.emit("sleep dirtyDays=\(dirtyDates.count) reads=\(Int(sleepReadMs))ms detectSleep=\(Int(detectMs))ms sessions=\(detectedSleepSessions.count)")

        for session in detectedSleepSessions {
            guard session.tst >= 20 else { continue }
            let stages = session.stages.map {
                [
                    "start": $0.start,
                    "end": $0.end,
                    "stage": $0.stage.rawValue
                ] as [String: Any]
            }
            let stageData = try? JSONSerialization.data(withJSONObject: stages, options: [.sortedKeys])
            allSleepSessions.append(SleepSession(
                startTs: Int(session.start),
                endTs: Int(session.end),
                efficiency: session.efficiency.isFinite ? session.efficiency : nil,
                restingHr: session.restingHR.isFinite ? Int(session.restingHR.rounded()) : nil,
                avgHrv: session.avgRmssd.isFinite ? session.avgRmssd : nil,
                stages: stageData
            ))
        }

        // Assemble DailyInputs now that the dedup'd session set is final — pure CPU, no reads.
        // The 24h HR/RR/gravity slices were already captured in the merged sleep pass above, so the
        // former per-day `daily.*` reads (a full second pass over data already in the 30h window)
        // are gone (B). `sleepSummary`/`primarySession` need the global dedup, hence this pass.
        let assembleStart = Date()
        let healthPriority = sourcePriority
        let firstBound = dayBounds(dates.first!).from
        let lastBound = dayBounds(dates.last!).to
        let external = try await store.externalWorkouts(overlapping: Double(firstBound), to: Double(lastBound))
        let activityRanges = external.filter { $0.endDate > $0.startDate }
            .map { (start: $0.startDate, end: $0.endDate) }
        for pd in pendingDays {
            let (healthFrom, healthTo) = dayBounds(pd.date)
            let health = try await healthEngineInputs(from: healthFrom, to: healthTo, priority: healthPriority)
            let endWindow = (from: Double(healthFrom), to: Double(healthTo) + 1)
            var sleepSummary = dailySleepSummary(sessions: detectedSleepSessions, date: pd.date,
                                                 endWindow: endWindow)
            var primarySession = detectedSleepSessions
                .filter { $0.end >= endWindow.from && $0.end < endWindow.to }
                .max(by: { $0.tst < $1.tst })
            let samples = try await store.healthSamples(type: "sleepAnalysis",
                from: Double(healthFrom - 6 * 3600), to: Double(healthTo))
            let order = healthPriority.order(for: .sleepAnalysis, context: .sleep)
            if let externalSleep = HealthSleepAdapter.summaries(samples: samples, date: pd.date, priority: healthPriority,
                                                                     endWindow: endWindow) {
                let source = externalSleep.source
                let externalRank = order.firstIndex(of: source) ?? Int.max
                let bandRank = order.firstIndex(of: .whoop) ?? Int.max
                if primarySession == nil || externalRank < bandRank {
                    let s = externalSleep.summary
                    // Keep bracelet HRV/RHR only if its physiological session substantially
                    // overlaps the selected external sleep. SDNN is never treated as RMSSD.
                    let overlap = primarySession.map {
                        max(0, min($0.end, Double(externalSleep.session.endTs)) - max($0.start, Double(externalSleep.session.startTs)))
                    } ?? 0
                    let bandDuration = primarySession.map { $0.end - $0.start } ?? 0
                    let matchingBand = bandDuration > 0 && overlap >= bandDuration * 0.5
                    sleepSummary = DailySleepSummary(date: s.date, totalSleepMin: s.totalSleepMin,
                        efficiency: s.efficiency, deepMin: s.deepMin, remMin: s.remMin,
                        lightMin: s.lightMin, disturbances: s.disturbances,
                        restingHR: matchingBand ? sleepSummary.restingHR : nil,
                        avgRmssd: matchingBand ? sleepSummary.avgRmssd : nil,
                        sleepStart: s.sleepStart, sleepEnd: s.sleepEnd)
                    allSleepSessions.removeAll {
                        max($0.startTs, externalSleep.session.startTs) < min($0.endTs, externalSleep.session.endTs)
                    }
                    allSleepSessions.append(externalSleep.session)
                    primarySession = nil
                }
            }
            let healthRecovery = try await healthRecoveryInputs(summary: sleepSummary, priority: healthPriority)
            let inputs = DailyInputs(
                date: pd.date,
                sleepSummary: sleepSummary,
                sleepSession: primarySession,
                hrSeries: pd.hrSeries,
                rrSeries: pd.rrSeries.isEmpty ? nil : pd.rrSeries,
                gravitySeries: pd.gravitySeries.isEmpty ? nil : pd.gravitySeries,
                userProfile: nil,
                hrHistory: pd.hrSeries.map { $0.bpm },
                strainDifficulty: strainDifficulty,
                supplementalHRSeries: health.hr,
                supplementalRestingHR: health.restingHR,
                preferredHRSeries: health.preferred,
                preferredHRRanges: activityRanges.filter { $0.start <= Double(healthTo) && $0.end > Double(healthFrom) },
                healthSDNN: healthRecovery.sdnn,
                healthRestingHR: healthRecovery.nightlyHR,
                bandSourceID: deviceId
            )
            allInputs.append((date: pd.date, inputs: inputs))
        }
        PerfLog.emit("dailyInputs days=\(pendingDays.count) \(PerfLog.ms(since: assembleStart))ms (0 reads — fusionné dans le pass sommeil)")

        // Band workouts: detected per local day with a 6 h margin on each side, so a session that
        // crosses local midnight is detected whole and attributed once, to its start day. The
        // threshold still comes from the day's own HR. The tail is the next dirty day's slice;
        // a clean previous day never needs it (its tail lies in an unchanged day).
        // Runs AFTER the sleep selection above: the retained nights and naps (band or Santé) are
        // final, so a detection that is not clearly separated from sleep is never created. The
        // recorded Santé workouts cut the band signal: only what lies outside them can be detected.
        let workoutMargin = 6.0 * 3600
        let sleepWindows = allSleepSessions.filter { $0.endTs > $0.startTs }
            .map { WorkoutInterval(start: Double($0.startTs), end: Double($0.endTs)) }
        let recordedWindows = activityRanges.map { WorkoutInterval(start: $0.start, end: $0.end) }
        for (i, pd) in pendingDays.enumerated() {
            let b = dayBounds(pd.date)
            let tail = i + 1 < pendingDays.count
                ? pendingDays[i + 1].hrSeries.filter { $0.ts <= Double(b.to) + workoutMargin } : []
            allWorkoutSessions.append(contentsOf: detectWorkoutSessions(
                hrSeries: pd.headHR + pd.hrSeries + tail, thresholdSeries: pd.hrSeries,
                startWindow: (Double(b.from), Double(b.to) + 1),
                sleep: sleepWindows, recorded: recordedWindows))
        }
        let hrmaxStart = Date()

        // Global HRmax (99.5 pctile of pooled HR), computed ONCE and reused across all days.
        // - FULL path: every day's HR is already in `allInputs`, so pool from there (no read) and
        //   refresh the cache. Bit-exact vs the old per-day `estimateHRmax(allHRBpm)`.
        // - INCREMENTAL path: reuse `cachedFullHRmax` from the last full and SKIP the whole-range
        //   HR read entirely (was 760k rows / ~1.1s/partial for a value that barely drifts). Only
        //   if the cache is cold (first run after launch is incremental) do we read once to seed it.
        let poolHRmax: Double?
        var hrmaxPoolCount = 0
        if cleanDates.isEmpty {
            let bandPool = allInputs.flatMap { $0.inputs.hrSeries.map { $0.bpm } }
            // Watch-only users still need an estimate; never mix HRV metrics here.
            let allHRBpm = bandPool.isEmpty
                ? allInputs.flatMap { $0.inputs.supplementalHRSeries.map { $0.bpm } }
                : bandPool
            hrmaxPoolCount = allHRBpm.count
            poolHRmax = fixedMaxHR ?? estimateHRmax(hrHistory: allHRBpm, age: nil)
            cachedFullHRmax = poolHRmax
            hasCachedFullHRmax = true
        } else if let cached = cachedFullHRmax {
            poolHRmax = cached
        } else {
            let globalFrom = dayBounds(dates.first!).from
            let globalTo = dayBounds(dates.last!).to
            let globalRows = try await store.hrSamples(deviceId: deviceId, from: globalFrom, to: globalTo, limit: 10_000_000)
            guard globalRows.count < 10_000_000 else { throw ComputeInputError.truncated("historique FC") }
            let pool = globalRows.map { Double($0.bpm) }
            hrmaxPoolCount = pool.count
            poolHRmax = fixedMaxHR ?? estimateHRmax(hrHistory: pool, age: nil)
            cachedFullHRmax = poolHRmax
            hasCachedFullHRmax = true
        }

        PerfLog.emit("hrmax pool=\(hrmaxPoolCount) cached=\(cleanDates.isEmpty ? false : (hrmaxPoolCount == 0)) value=\(poolHRmax.map { String(format: "%.0f", $0) } ?? "nil") \(PerfLog.ms(since: hrmaxStart))ms")
        let asmStart = Date()

        // ── 3. Assemble DailySnapshots ───────────────────────────────────────────
        // Clean earlier days are reused verbatim from `previous`; we only run the engine for the
        // dirty tail. The clean reconstructed entries sit at the front of `allInputs` so each
        // dirty day's history fold sees them.
        var snapshots: [DailySnapshot] = dirtyStart > 0
            ? (previous?.daily.filter { cleanDateSet.contains($0.date) } ?? [])
            : []

        for idx in cleanDates.count..<allInputs.count {
            let entry = allInputs[idx]
            try Task.checkCancellation()
            await Task.yield()   // cède l'actor pour laisser passer un express prioritaire (cf. boucle sommeil)
            // Skip engine runs for days with no sensor data — no HR means no sleep, HRV,
            // strain, or recovery to compute. Still report progress so the bar advances.
            // Un jour sans bracelet mais avec FC Apple Santé est calculé (strain seul : pas de nuit
            // bracelet → ni récupération ni sommeil). Sans Santé, règle inchangée.
            if entry.inputs.hrSeries.isEmpty && entry.inputs.supplementalHRSeries.isEmpty
                && entry.inputs.sleepSummary.totalSleepMin <= 0 {
                progressCompleted += 1
                onProgress?(stageAssembly, progressCompleted, progressTotal)
                continue
            }
            // History = all prior days (oldest → idx-1)
            let history = allInputs[0..<idx].map { $0.inputs }

            // HRmax is supplied pre-computed (poolHRmax) so the engine skips its per-day
            // estimateHRmax sort of the whole pool; hrHistory stays empty on purpose.
            let dayInputs = DailyInputs(
                date: entry.inputs.date,
                sleepSummary: entry.inputs.sleepSummary,
                sleepSession: entry.inputs.sleepSession,
                hrSeries: entry.inputs.hrSeries,
                rrSeries: entry.inputs.rrSeries,
                gravitySeries: entry.inputs.gravitySeries,
                userProfile: entry.inputs.userProfile,
                hrHistory: [],
                hrmaxOverride: poolHRmax,
                strainDifficulty: entry.inputs.strainDifficulty,
                strainExcludeRanges: strainExcludeRanges,
                supplementalHRSeries: entry.inputs.supplementalHRSeries,
                supplementalRestingHR: entry.inputs.supplementalRestingHR,
                preferredHRSeries: entry.inputs.preferredHRSeries,
                preferredHRRanges: entry.inputs.preferredHRRanges,
                healthSDNN: entry.inputs.healthSDNN,
                healthRestingHR: entry.inputs.healthRestingHR,
                bandSourceID: entry.inputs.bandSourceID
            )

            // ── DailyEngine.compute() ─────────────────────────────────────────
            // NOTE: The zero-spread BaselineState below is only used by DailyEngine when
            // history.isEmpty (i.e. the very first day). For all subsequent days, Daily.swift
            // recomputes the HRV baseline from history internally and ignores this argument.
            // On day 0 with no history, spread: 0 makes sigmaHrv collapse to 1e-9, which
            // clamps recovery to 0 or 100 — but the cold-start gate in Recovery.swift
            // returns nil score when the baseline is not yet usable, so the UI shows
            // "calibrating" rather than a nonsensical score. Risk is low but documented here.
            // TODO: Consider deriving the baseline from history before calling compute() to
            // make the intent explicit and avoid the degenerate first-day argument.
            let daily = DailyEngine.compute(
                day: dayInputs,
                history: Array(history),
                baseline: BaselineState(
                    baseline: 0, spread: 0, nValid: 0,
                    nightsSinceUpdate: 0, status: .calibrating
                )
            )

            // ── AdviceEngine inputs from DailyResult ──────────────────────────
            let recoveryResult = daily.recoveryEvidence

            // Sleep history: total sleep minutes for each prior night
            let sleepHistoryValues: [Double?] = history.map { h in
                h.sleepSummary.totalSleepMin > 0 ? h.sleepSummary.totalSleepMin : nil
            }

            // Tonight's bedtime offset (from sleep session start if available)
            // Unused while bedtimeBaseline is nil (UTC noon reference, see IMPLEMENTATION-FUSEAU-LOCAL).
            let tonightBedtimeOffset: Double? = daily.sleepStart.map { bedtimeOffsetMinutes($0) }

            // Historique de strain + baseline personnelle, construits depuis les snapshots DÉJÀ
            // calculés ce run (jours antérieurs, ordre chronologique). Le strain y est déjà à
            // l'échelle de la difficulté choisie, donc la cible (targetStrain) qui en découle suit
            // automatiquement le réglage du slider — fini la cible fixe 15.5 incohérente.
            let priorStrains: [Double?] = snapshots.map { $0.strain }
            let recentStrainHistory: [Double?] = Array(priorStrains.suffix(3))
            let strainBaseline: BaselineState? = priorStrains.isEmpty ? nil : {
                let b = foldHistory(priorStrains, cfg: .strain)
                return b.usable ? b : nil
            }()

            // Recompute durBaseline from history for sleepTargetMin
            let durHistory: [Double?] = history.map { h -> Double? in
                h.sleepSummary.totalSleepMin > 0 ? h.sleepSummary.totalSleepMin : nil
            }
            let durBaseline: BaselineState? = history.isEmpty ? nil : {
                let b = foldHistory(durHistory, cfg: .sleepDuration)
                return b.usable ? b : nil
            }()

            // ── AdviceEngine.compute() ────────────────────────────────────────
            let advice = AdviceEngine.compute(
                recovery: recoveryResult,
                sleepHistory: sleepHistoryValues,
                durationBaseline: durBaseline,
                bedtimeBaseline: nil,           // bedtime baseline: Phase 7 scope — nil
                tonightBedtimeOffset: tonightBedtimeOffset,
                strainBaseline: strainBaseline,
                recentStrainHistory: recentStrainHistory
            )

            // ── Upsert advice signals into GRDB ───────────────────────────────
            let primarySignalRow = AdviceSignalRow(
                code: advice.primaryCode.rawValue,
                paramsJSON: paramsToJSON(advice.primaryParams),
                confidence: advice.primaryConfidence
            )
            let secondaryRows = advice.secondary.map { s in
                AdviceSignalRow(code: s.code, paramsJSON: s.paramsJSON, confidence: s.confidence)
            }
            let allRows = [primarySignalRow] + secondaryRows
            _ = try? await store.upsertAdviceSignals(allRows, deviceId: deviceId, day: entry.date)

            // ── Extract effort target fields from advice ───────────────────────
            var targetStrain: Double? = nil
            var targetStrainConfidence: String? = nil
            var recentOverload: Bool? = nil

            for signal in advice.secondary {
                if signal.code == AdviceCode.effortTarget.rawValue {
                    if let data = signal.paramsJSON.data(using: .utf8),
                       let params = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        targetStrain = params["target_strain"] as? Double
                        recentOverload = params["recent_overload"] as? Bool
                    }
                    targetStrainConfidence = signal.confidence
                }
            }

            // ── Assemble all advice signals for DailySnapshot ─────────────────
            let primarySignal = AdviceSignal(
                code: advice.primaryCode.rawValue,
                paramsJSON: paramsToJSON(advice.primaryParams),
                confidence: advice.primaryConfidence
            )
            let allAdviceSignals = [primarySignal] + advice.secondary

            // ── Assemble DailySnapshot ────────────────────────────────────────
            let snapshot = DailySnapshot(
                date: daily.date,
                totalSleepMin: daily.totalSleepMin,
                efficiency: daily.efficiency,
                deepMin: daily.deepMin,
                remMin: daily.remMin,
                lightMin: daily.lightMin,
                disturbances: daily.disturbances,
                sleepStart: daily.sleepStart,
                sleepEnd: daily.sleepEnd,
                sleepScore: daily.sleepScore,
                restingHR: daily.restingHR,
                avgHrv: daily.avgHrv,
                recovery: daily.recovery,
                recoveryStatus: daily.recoveryStatus,
                recoveryBand: daily.recoveryBand,
                strain: daily.strain,
                sleepTargetMin: durBaseline.map { $0.baseline },
                targetStrain: targetStrain,
                targetStrainConfidence: targetStrainConfidence,
                recentOverload: recentOverload,
                adviceSignals: allAdviceSignals,
                recoveryZHrv: recoveryResult.zHrv,
                recoveryZRhr: recoveryResult.zRhr,
                recoveryZResp: recoveryResult.zResp,
                strainObservedMinutes: daily.strainEvidence?.observedMinutes,
                strainBelowZoneMinutes: daily.strainEvidence?.belowZoneMinutes,
                strainHRmaxUsed: daily.strainHRmaxUsed,
                strainRestingHRUsed: daily.strainRestingHRUsed,
                healthSDNN: daily.healthSDNN,
                healthRestingHR: daily.healthRestingHR,
                recoveryHRVMetric: daily.recoveryHRVMetric,
                recoveryHRVObservation: daily.recoveryHRVObservation,
                recoveryRHRObservation: daily.recoveryRHRObservation,
                heartRateZones: daily.strainEvidence.flatMap { evidence in
                    guard let rest = daily.strainRestingHRUsed, let maxHR = daily.strainHRmaxUsed else { return nil }
                    return HeartRateZoneBreakdown(result: evidence, restingHR: rest, maxHR: maxHR,
                                                  maxHRSource: maxHRSource)
                },
                timeZone: schedule.zoneIdentifier(for: entry.date)
            )
            snapshots.append(snapshot)
            progressCompleted += 1
            onProgress?(stageAssembly, progressCompleted, progressTotal)
        }

        PerfLog.emit("assembly engineDays=\(allInputs.count - cleanDates.count) \(PerfLog.ms(since: asmStart))ms")

        snapshots.sort { $0.date < $1.date }
        allSleepSessions.sort { $0.startTs < $1.startTs }
        allWorkoutSessions.sort { $0.startTs < $1.startTs }
        // Merge reused + fresh HR tail, dedup by ts, keep the most recent 1000 for the UI sparkline.
        var hrByTs: [Int: HeartRateSample] = [:]
        for s in recentHRSamples { hrByTs[s.ts] = s }
        let hrSamples = Array(hrByTs.values.sorted { $0.ts < $1.ts }.suffix(1_000))

        let mergedWorkouts = HealthWorkoutCanonicalizer.merge(band: allWorkoutSessions, external: external)
        var enrichedWorkouts: [WorkoutSession] = []
        for workout in mergedWorkouts {
            guard workout.externalID != nil, workout.endTs > workout.startTs else {
                enrichedWorkouts.append(workout)
                continue
            }
            let raw = try await store.hrSamples(deviceId: deviceId, from: workout.startTs,
                                                to: workout.endTs, limit: 250_000)
            guard raw.count < 250_000 else { throw ComputeInputError.truncated("workout heart rate") }
            let health = try await healthEngineInputs(from: workout.startTs, to: workout.endTs, priority: healthPriority)
            let band = raw.map { (ts: Double($0.ts), bpm: Double($0.bpm)) }
            let series = mergePrioritizedHR(band: band, supplemental: health.hr, preferred: health.preferred,
                preferredRanges: [(start: Double(workout.startTs), end: Double(workout.endTs))]).filter {
                $0.ts >= Double(workout.startTs) && $0.ts < Double(workout.endTs)
            }
            let coveredSeconds = Set(series.map { Int($0.ts.rounded(.down)) }).count
            let coverage = Double(coveredSeconds) / Double(workout.endTs - workout.startTs)
            let enough = coverage >= 0.8 && series.count >= 600
            let avg = enough ? series.map(\.bpm).reduce(0, +) / Double(series.count) : nil
            let peak = enough ? series.map { Int($0.bpm.rounded()) }.max() : nil
            let day = schedule.day(containing: Double(workout.startTs))
            // For an overnight session, use the start day's resting HR consistently.
            var rhr = snapshots.first { $0.date == day }?.restingHR
                ?? allInputs.first { $0.date == day }?.inputs.supplementalRestingHR
                ?? health.restingHR
            if rhr == nil {
                let bounds = dayBounds(day)
                let samples = try await store.healthSamples(type: HealthSampleKind.restingHeartRate.rawValue,
                    from: Double(bounds.from), to: Double(bounds.to))
                rhr = HealthEngineInputs.restingHR(samples, from: bounds.from, to: bounds.to, priority: healthPriority)
            }
            let activityStrain: Double?
            var zones: HeartRateZoneBreakdown?
            if enough, let hrmax = poolHRmax, let rhr, hrmax > rhr,
               let result = try? strain(hrSeries: series, restingHR: rhr, hrmaxEstimate: hrmax,
                                        sex: .male, difficulty: strainDifficulty) {
                activityStrain = result.strain
                // Mêmes minutes que la charge (bornes Karvonen du moteur), avec les références
                // réellement utilisées : seule source des zones affichées pour cette séance.
                zones = HeartRateZoneBreakdown(result: result, restingHR: rhr, maxHR: hrmax,
                                               maxHRSource: maxHRSource)
            } else {
                activityStrain = nil
            }
            enrichedWorkouts.append(WorkoutSession(deviceId: workout.deviceId,
                startTs: workout.startTs, endTs: workout.endTs, avgHr: avg, peakHr: peak,
                strain: activityStrain, kind: workout.kind, durationS: workout.durationS,
                caloriesKcal: workout.caloriesKcal, sportType: workout.sportType,
                distanceM: workout.distanceM, sourceName: workout.sourceName, externalID: workout.externalID,
                heartRateZones: zones))
        }
        let result = LocalComputeResult(
            daily: snapshots,
            sleepSessions: allSleepSessions,
            workoutSessions: await attachPerceivedEfforts(enrichedWorkouts),
            stress: latestStress,
            hrSamples: hrSamples,
            dayTimeZones: resultRegistry
        )
        dayZoneRegistry = resultRegistry
        PerfLog.emit("computeCore TOTAL \(PerfLog.ms(since: perfT0))ms dirty=\(dirtyDates.count) clean=\(cleanDates.count)")
        return (result, currentDayCounts)
    }

    // MARK: - Express compute (strain + stress, no sleep)

    /// Pass express : calcule le strain et le stress d'**aujourd'hui** sans attendre la
    /// détection du sommeil (la partie lente : 4 streams × fenêtre 30h × 60 jours).
    ///
    /// Dépendances réelles :
    ///   - **Strain** a juste besoin de `hrSeries` + `restingHR` + `hrmaxEstimate`. Le RHR
    ///     « vrai » vient du sommeil (absent ici) → on prend le 10e percentile du HR waking
    ///     comme fallback (légèrement > RHR de sommeil → strain légèrement **sous-estimé**,
    ///     direction sûre). HRmax = 99.5e percentile du HR des ~14 derniers jours, caché
    ///     sur l'actor pour la session.
    ///   - **Stress** est déjà indépendant du sommeil (HR + RR + gravity sur la journée).
    ///   - **Recovery** nécessite l'HRV/RHR de la nuit → reste `nil` (`isExpress = true`),
    ///     le pass full le remplira.
    ///
    /// Lancé par `LoopDataRepository.requestExpressRefresh()` à l'arrivée de données bracelet
    /// et au retour foreground stale. Le pass full (`computeCore`) tourne en parallèle et
    /// remplace ce snapshot (`isExpress = false`) quand il termine.
    func computeExpress(strainDifficulty: Double? = nil, referenceRestingHR: Double? = nil,
                        dayTimeZones: [String: String]? = nil,
                        personalMaxHeartRate: MaxHeartRateReference? = nil, now: Date = Date()) async -> ExpressResult? {
        if let maxHeartRateOverride,
           (!maxHeartRateOverride.isFinite || !CardioInputPolicy.heartRateBPM.contains(maxHeartRateOverride)) { return nil }
        let fixedMaxHR = MaxHeartRatePolicy.fixedValue(override: maxHeartRateOverride, personal: personalMaxHeartRate)
        let xT0 = Date()
        PerfLog.reset("computeExpress START")
        if let dayTimeZones { restoreDayTimeZones(dayTimeZones) }
        let today = schedule(now: now)
        let dateStr = today.today
        let (fromTs, toTs) = today.bounds(dateStr)

        guard let hrRaw = try? await store.hrSamples(deviceId: deviceId, from: fromTs, to: toTs, limit: 100_000) else { return nil }
        let hrSeries: [(ts: Double, bpm: Double)] = hrRaw.map { (ts: Double($0.ts), bpm: Double($0.bpm)) }

        guard let rrRaw = try? await store.rrIntervals(deviceId: deviceId, from: fromTs, to: toTs, limit: 100_000) else { return nil }
        let rrSeries: [(ts: Double, rrMs: Double)] = rrRaw.map { (ts: Double($0.ts), rrMs: Double($0.rrMs)) }

        guard let gravRaw = try? await store.gravitySamples(deviceId: deviceId, from: fromTs, to: toTs, limit: 100_000) else { return nil }
        guard hrRaw.count < 100_000, rrRaw.count < 100_000, gravRaw.count < 100_000 else {
            Self.log.error("express: limite de lecture atteinte, résultat non publié")
            return nil
        }
        let gravitySeries: [(ts: Double, v: Double)] = gravRaw.map {
            (ts: Double($0.ts), v: sqrt(Double($0.x * $0.x + $0.y * $0.y + $0.z * $0.z)))
        }

        // ── HRmax : pool 14j mis en cache pour la session ───────────────────────
        if expressHRmax == nil {
            let lookback = 14 * 24 * 60 * 60
            guard let poolRaw = try? await store.hrSamples(deviceId: deviceId, from: fromTs - lookback, to: toTs, limit: 2_000_000) else { return nil }
            guard poolRaw.count < 2_000_000 else {
                Self.log.error("express: limite du pool FC atteinte, résultat non publié")
                return nil
            }
            let pool: [Double]
            if poolRaw.isEmpty {
                guard let history = try? await healthEngineInputs(from: fromTs - lookback, to: toTs, priority: sourcePriority) else {
                    return nil
                }
                pool = history.hr.map(\.bpm)
            } else {
                pool = poolRaw.map { Double($0.bpm) }
            }
            expressHRmax = estimateHRmax(hrHistory: pool, age: nil)
            Self.log.info("express: HRmax estimé = \(self.expressHRmax.map { String($0) } ?? "nil", privacy: .public) sur \(pool.count, privacy: .public) HR (14j)")
        }

        guard let health = try? await healthEngineInputs(from: fromTs, to: toTs, priority: sourcePriority) else {
            Self.log.error("express: impossible de lire les données Santé, résultat non publié")
            return nil
        }
        let strainHR = mergeSupplementalHR(band: hrSeries, supplemental: health.hr)
        guard !strainHR.isEmpty else { return nil }
        // A waking percentile or a hard-coded 60 bpm is not a resting-HR measurement.
        // Until a measured reference is available, the provisional strain stays absent.
        let measuredRHR = referenceRestingHR.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? health.restingHR
        var strainVal: Double? = nil
        if let hrmax = fixedMaxHR ?? cachedFullHRmax ?? expressHRmax, let measuredRHR, hrmax > measuredRHR, strainHR.count >= 600 {
            strainVal = try? strain(
                hrSeries: strainHR,
                restingHR: measuredRHR,
                hrmaxEstimate: hrmax,
                sex: .male,
                difficulty: strainDifficulty
            ).strain
        }

        // ── Stress (inchangé vs pass full) ──────────────────────────────────────
        let stress = makeStressSnapshot(
            date: dateStr,
            hrSeries: hrSeries,
            rrSeries: rrSeries,
            gravitySeries: gravitySeries
        )

        let hrSamples = hrRaw.suffix(240).map { HeartRateSample(ts: $0.ts, bpm: $0.bpm) }

        let snapshot = DailySnapshot(
            date: dateStr,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, sleepStart: nil, sleepEnd: nil, sleepScore: nil,
            restingHR: nil, avgHrv: nil,
            recovery: nil, recoveryStatus: "low", recoveryBand: nil,
            strain: strainVal,
            sleepTargetMin: nil, targetStrain: nil, targetStrainConfidence: nil,
            recentOverload: nil, adviceSignals: [],
            isExpress: true,
            timeZone: today.zoneIdentifier(for: dateStr)
        )
        Self.log.info("express: today=\(dateStr, privacy: .public) strain=\(strainVal.map { String(format: "%.2f", $0) } ?? "nil", privacy: .public) stress=\(stress != nil, privacy: .public)")
        PerfLog.emit("computeExpress TOTAL \(PerfLog.ms(since: xT0))ms strain=\(strainVal != nil) stress=\(stress != nil)")
        return ExpressResult(snapshot: snapshot, stress: stress, hrSamples: Array(hrSamples))
    }

    // MARK: - Apple Santé (entrées du calcul)

    /// Lit les entrées Apple Santé d'un jour pour le calcul. Vide/nil si rien n'est importé.
    private func healthEngineInputs(from: Int, to: Int, priority: HealthSourcePriority)
        async throws -> (hr: [(ts: Double, bpm: Double)], restingHR: Double?, preferred: [(ts: Double, bpm: Double)]) {
        // A failed read must not silently become an apparently valid bracelet-only score.
        let hrRows = try await store.healthSamples(type: HealthSampleKind.heartRate.rawValue, from: Double(from), to: Double(to))
        let rhrRows = try await store.healthSamples(type: HealthSampleKind.restingHeartRate.rawValue, from: Double(from), to: Double(to))
        let order = priority.order(for: .heartRate, context: .activity)
        let bandRank = order.firstIndex(of: .whoop) ?? order.count
        let preferredRows = hrRows.filter {
            let source = HealthDataSource.classify(sourceName: $0.sourceName, metadataOrigin: $0.metadataOrigin,
                                                   sourceBundle: $0.sourceBundle,
                                                   productType: $0.productType, deviceModel: $0.deviceModel)
            guard source != .whoop, let rank = order.firstIndex(of: source) else { return false }
            return rank < bandRank
        }
        return (HealthEngineInputs.supplementalHR(hrRows, priority: priority),
                HealthEngineInputs.restingHR(rhrRows, from: from, to: to, priority: priority),
                HealthEngineInputs.supplementalHR(preferredRows, priority: priority))
    }

    /// The chosen sleep window anchors both series. The nighttime median is a
    /// separate experimental proxy, never the bracelet's resting-HR baseline.
    private func healthRecoveryInputs(summary: DailySleepSummary, priority: HealthSourcePriority)
        async throws -> (sdnn: RecoveryObservation?, nightlyHR: RecoveryObservation?) {
        guard let start = summary.sleepStart, let end = summary.sleepEnd,
              start.isFinite, end.isFinite, end > start else { return (nil, nil) }
        let sdnn = try await store.healthSamples(type: HealthSampleKind.heartRateVariabilitySDNN.rawValue,
                                                 from: start, to: end)
        let heartRate = try await store.healthSamples(type: HealthSampleKind.heartRate.rawValue,
                                                      from: start, to: end)
        return (HealthRecoveryInputs.observation(sdnn.filter { $0.endDate <= end }, kind: .heartRateVariabilitySDNN, priority: priority),
                HealthRecoveryInputs.observation(heartRate.filter { $0.endDate <= end }, kind: .heartRate, priority: priority))
    }

    /// Lecture Santé brute d'un jour local (mêmes bornes que le calcul) pour la vue fusionnée d'Aujourd'hui,
    /// avec la FC du bracelet du jour (comparée à la Watch dans l'indicateur d'accord).
    func healthDayRaw(date: String) async -> HealthDayRaw {
        let (from, to) = dayBounds(date)
        var samples: [HealthSampleKind: [HealthSample]] = [:]
        for kind in HealthSampleKind.allCases {
            let rows = await loggedRead("health.day.\(kind.rawValue)") {
                if HealthAggregation.for(kind) == .sum {
                    return try await store.healthSamplesOverlapping(type: kind.rawValue, from: Double(from), to: Double(to) + 1)
                }
                return try await store.healthSamples(type: kind.rawValue, from: Double(from), to: Double(to))
            }
            if !rows.isEmpty { samples[kind] = rows }
        }
        // Sommeil : une nuit commence la veille. Même fenêtre que la détection bracelet (veille 18:00 locale).
        let sleepRows = await loggedRead("health.day.sleep") {
            try await store.healthSamples(type: HealthSampleKind.sleepAnalysis.rawValue,
                                          from: Double(from - 6 * 60 * 60), to: Double(to))
        }
        samples[.sleepAnalysis] = sleepRows.isEmpty ? nil : sleepRows
        let workouts = await loggedRead("health.day.workouts") {
            // Séances qui commencent ce jour local (même rattachement que le moteur).
            try await store.externalWorkouts(from: Double(from), to: Double(to))
        }
        let bandHR = await loggedRead("health.day.bandHR") {
            try await store.hrSamples(deviceId: deviceId, from: from, to: to, limit: 100_000)
        }
        return HealthDayRaw(date: date, from: Double(from), to: Double(to) + 1, samples: samples,
                            workouts: workouts,
                            bandHR: bandHR.map { HealthMeasurePoint(at: Date(timeIntervalSince1970: Double($0.ts)), value: Double($0.bpm)) })
    }

    // MARK: - Helpers

    /// `[fromTs, toTs]` (inclusive) of a LOCAL calendar day: local midnight → next local
    /// midnight - 1 s (23 h / 25 h on DST days), in the zone recorded for that day.
    func dayBounds(_ date: String, now: Date = Date()) -> (from: Int, to: Int) {
        schedule(now: now).bounds(date)
    }

    private func makeStressSnapshot(
        date: String,
        hrSeries: [(ts: Double, bpm: Double)],
        rrSeries: [(ts: Double, rrMs: Double)],
        gravitySeries: [(ts: Double, v: Double)]
    ) -> StressSnapshot? {
        guard let result = try? stressTimeline(
            hrSeries: hrSeries,
            rrSeries: rrSeries,
            gravitySeries: gravitySeries
        ), !result.timeline.isEmpty else {
            return nil
        }

        let hrBuckets = Dictionary(grouping: hrSeries) { floor($0.ts / 60.0) * 60.0 }
        let movementBuckets = movementByMinute(gravitySeries)
        let timestamps = hrBuckets.keys.sorted()
        let points = zip(timestamps, result.timeline).map { pair in
            let (ts, score) = pair
            let bpms = hrBuckets[ts] ?? []
            let avgBpm = bpms.isEmpty ? nil : bpms.map { $0.bpm }.reduce(0.0, +) / Double(bpms.count)
            let movement = movementBuckets[ts]
            return StressPoint(
                ts: Int(ts),
                score: score,
                nonActivityScore: nil,
                hrBpm: avgBpm,
                rmssdMs: nil,
                movementIntensity: movement,
                context: movement.map { $0 >= 0.20 ? "active" : "rest" }
            )
        }

        guard !points.isEmpty else { return nil }
        let maxScore = points.map { $0.score }.max()
        let activityMinutes = points.filter { ($0.movementIntensity ?? 0) >= 0.20 }.count

        return StressSnapshot(
            date: date,
            latest: points.last,
            timeline: points,
            summary: StressSummary(
                avgScore: result.meanStress,
                avgNonActivityScore: nil,
                maxScore: maxScore,
                highMinutes: result.fractionHigh * Double(points.count),
                activityMinutes: Double(activityMinutes)
            )
        )
    }

    /// Band-detected sessions (`detected_cardio`). Thresholds and rules: `WorkoutDetector`.
    /// - Parameters:
    ///   - hrSeries: day slice plus margins (previous / next local day).
    ///   - thresholdSeries: the day's own slice; the activity threshold depends on it only.
    ///   - startWindow: `[from, to)`; sessions starting outside belong to a neighbouring day.
    ///   - sleep: retained sleep windows; a detection touching one (± guard) is not created.
    ///   - recorded: Santé workouts; their span is never re-detected from the band.
    private func detectWorkoutSessions(
        hrSeries: [(ts: Double, bpm: Double)],
        thresholdSeries: [(ts: Double, bpm: Double)],
        startWindow: (from: Double, to: Double),
        sleep: [WorkoutInterval],
        recorded: [WorkoutInterval]
    ) -> [WorkoutSession] {
        WorkoutDetector.detect(hrSeries: hrSeries, thresholdSeries: thresholdSeries,
                               startWindow: startWindow, sleep: sleep, recorded: recorded).map { d in
            WorkoutSession(
                deviceId: deviceId,
                startTs: Int(d.start),
                endTs: Int(d.end),
                avgHr: d.averageBPM,
                peakHr: Int(d.peakBPM.rounded()),
                strain: nil,
                kind: "detected_cardio",
                durationS: Int(d.end - d.start),
                caloriesKcal: nil
            )
        }
    }

    /// Serialise a `[String: Double]` params dict to a compact JSON string.
    private func paramsToJSON(_ params: [String: Double]) -> String {
        let any: [String: Any] = Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.value as Any) })
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Apple Santé → entrées du calcul (pur)

/// Prépare les entrées Apple Santé de `DailyInputs`. Pur : testable sans store.
/// HealthKit's SDNN and the nightly median HR are experimental observations, not
/// interchangeable with the band's RMSSD or nightly resting HR. Preserve one
/// producer per observation and stable methodology in its identity.
enum HealthRecoveryInputs {
    static func observation(_ rows: [HealthSample], kind: HealthSampleKind,
                            priority: HealthSourcePriority) -> RecoveryObservation? {
        guard kind == .heartRate || kind == .heartRateVariabilitySDNN else { return nil }
        let order = priority.order(for: kind, context: .sleep)
        let eligible = rows.filter { row in
            guard row.type == kind.rawValue, row.metadataOrigin != HealthSampleMapping.loopOrigin,
                  row.startDate.isFinite, row.endDate.isFinite, row.endDate >= row.startDate,
                  HealthDataSource.classify(sourceName: row.sourceName, metadataOrigin: nil, sourceBundle: row.sourceBundle,
                                            productType: row.productType, deviceModel: row.deviceModel) == .appleWatch,
                  order.contains(.appleWatch), let value = row.value, value.isFinite else { return false }
            if kind == .heartRateVariabilitySDNN {
                return row.unit == "ms" && (MetricCfg.hrv.minVal...MetricCfg.hrv.maxVal).contains(value)
            }
            return row.unit == "count/min" && (MetricCfg.restingHR.minVal...MetricCfg.restingHR.maxVal).contains(value)
        }
        let groups = Dictionary(grouping: eligible) { row in
            (row.sourceBundle ?? "") + "|" + (row.sourceName ?? "")
        }
        var candidates: [(key: String, values: [Double])] = []
        for (key, group) in groups where key != "|" {
            // A source can emit duplicate entries at the same instant; keep one deterministic
            // value per instant so duplicates cannot meet the minimum sample requirement.
            var unique: [Double: Double] = [:]
            for row in group.sorted(by: { $0.uuid < $1.uuid }) { unique[row.startDate] = row.value }
            let times = unique.keys.sorted()
            if kind == .heartRate {
                guard times.count >= 5, let first = times.first, let last = times.last,
                      last - first >= 30 * 60 else { continue }
            } else if times.isEmpty { continue }
            candidates.append((key, times.compactMap { unique[$0] }))
        }
        guard let selected = candidates.sorted(by: {
            $0.values.count == $1.values.count ? $0.key < $1.key : $0.values.count > $1.values.count
        }).first else { return nil }
        let sorted = selected.values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let method = kind == .heartRate ? "sleep-median-hr-v1" : "sleep-median-sdnn-v1"
        return RecoveryObservation(value: median, sourceID: "\(method)|\(selected.key)", sampleCount: sorted.count)
    }
}

enum HealthEngineInputs {
    /// Types Santé qui entrent dans le calcul (et donc dans l'empreinte de recalcul).
    static let types = [HealthSampleKind.heartRate.rawValue, HealthSampleKind.restingHeartRate.rawValue]

    /// FC externe pour combler les trous du bracelet. Exclut les écritures de Loop (copie du
    /// bracelet) et les valeurs hors plage. Si plusieurs sources externes se recouvrent, une seule
    /// est gardée par instant : ordre de la priorité FC « activité » (les trous sont le plus souvent
    /// des séances sans bracelet), une source moins prioritaire n'étant gardée qu'à plus de
    /// `SupplementalHR.maxHoldSeconds` d'un échantillon d'une source plus prioritaire.
    /// Une source absente de cet ordre (exclue par l'utilisateur) n'est jamais retenue.
    static func supplementalHR(_ rows: [HealthSample], priority: HealthSourcePriority) -> [(ts: Double, bpm: Double)] {
        let order = priority.order(for: .heartRate, context: .activity)
        let series = HealthSourceSeries.grouped(rows)
            .filter { $0.source != .whoop && order.contains($0.source) }
        guard !series.isEmpty else { return [] }
        func rank(_ s: HealthDataSource) -> Int { order.firstIndex(of: s) ?? order.count }

        var kept: [Double] = []   // instants déjà retenus, triés
        var out: [(ts: Double, bpm: Double)] = []
        for s in series.sorted(by: { rank($0.source) < rank($1.source) }) {
            let points = s.points
                .filter { HealthPlausibility.isValid($0, kind: .heartRate) }
                .map { (ts: $0.start.timeIntervalSince1970, bpm: $0.value) }
            let fresh = kept.isEmpty ? points : points.filter { !isNear($0.ts, sorted: kept) }
            out.append(contentsOf: fresh)
            kept = (kept + fresh.map(\.ts)).sorted()
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// FC repos du jour selon la priorité de réconciliation (une seule fenêtre = le jour). Les
    /// écritures de Loop sont exclues : la FC repos du bracelet vient déjà de la nuit.
    static func restingHR(_ rows: [HealthSample], from: Int, to: Int, priority: HealthSourcePriority) -> Double? {
        let series = HealthSourceSeries.grouped(rows).filter { $0.source != .whoop }
        guard !series.isEmpty else { return nil }
        let start = Date(timeIntervalSince1970: Double(from))
        let end = Date(timeIntervalSince1970: Double(to) + 1)
        let merged = HealthReconciliation.mergeSeries(kind: .restingHeartRate, series: series,
                                                      from: start, to: end, bucket: end.timeIntervalSince(start),
                                                      priority: priority)
        return merged.buckets.first?.value
    }

    private static func isNear(_ t: Double, sorted: [Double]) -> Bool {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        let tol = SupplementalHR.maxHoldSeconds
        if lo < sorted.count, sorted[lo] - t <= tol { return true }
        if lo > 0, t - sorted[lo - 1] <= tol { return true }
        return false
    }
}

// MARK: - Private helpers (file-scope)

/// Effondre les sessions de sommeil qui se chevauchent en gardant la plus longue (TST) de
/// chaque groupe. Deux vrais sommeils ne se chevauchent jamais dans le temps : un chevauchement
/// signale la même nuit détectée plusieurs fois (fenêtres de 30h qui se recoupent), une version
/// tronquée et une version entière. Glouton « plus long d'abord » : on garde la session
/// dominante, on jette tout ce qui la recoupe. Les siestes disjointes survivent.
/// Générique sur accesseurs pour éviter de nommer `LoopStrapEngine.SleepSession` (collision avec
/// un type homonyme du module, raison pour laquelle le reste du fichier s'appuie sur l'inférence).
private func dedupOverlappingSleepSessions<S>(
    _ sessions: [S],
    start: (S) -> Double,
    end: (S) -> Double,
    tst: (S) -> Double
) -> [S] {
    let byTSTDesc = sessions.sorted { tst($0) > tst($1) }
    var kept: [S] = []
    for s in byTSTDesc {
        let overlaps = kept.contains { k in
            max(0, min(end(s), end(k)) - max(start(s), start(k))) > 0
        }
        if !overlaps { kept.append(s) }
    }
    return kept.sorted { start($0) < start($1) }
}

/// Reconstructs a clean (unchanged) day's `DailyInputs` from its cached `DailySnapshot`, with only
/// the `sleepSummary` populated — the only thing a downstream baseline fold reads from history
/// entries. Avoids reloading raw streams + re-detecting sleep for days that didn't change.
private func reconstructInputs(date: String, snapshot: DailySnapshot?, deviceId: String) -> DailyInputs {
    let summary = DailySleepSummary(
        date: date,
        totalSleepMin: snapshot?.totalSleepMin ?? 0,
        efficiency: snapshot?.efficiency ?? 0,
        deepMin: snapshot?.deepMin ?? 0,
        remMin: snapshot?.remMin ?? 0,
        lightMin: snapshot?.lightMin ?? 0,
        disturbances: snapshot?.disturbances ?? 0,
        restingHR: snapshot?.restingHR,
        avgRmssd: snapshot?.avgHrv,
        sleepStart: snapshot?.sleepStart,
        sleepEnd: snapshot?.sleepEnd
    )
    return DailyInputs(
        date: date,
        sleepSummary: summary,
        sleepSession: nil,
        hrSeries: [],
        rrSeries: nil,
        gravitySeries: nil,
        userProfile: nil,
        hrHistory: [],
        healthSDNN: snapshot?.healthSDNN,
        healthRestingHR: snapshot?.healthRestingHR,
        bandSourceID: deviceId
    )
}

private func movementByMinute(_ gravitySeries: [(ts: Double, v: Double)]) -> [Double: Double] {
    guard gravitySeries.count > 1 else { return [:] }
    var buckets: [Double: [Double]] = [:]
    var previous = gravitySeries[0]
    for sample in gravitySeries.dropFirst() {
        let bucket = floor(sample.ts / 60.0) * 60.0
        let delta = abs(sample.v - previous.v)
        buckets[bucket, default: []].append(delta)
        previous = sample
    }
    return buckets.mapValues { deltas in
        guard !deltas.isEmpty else { return 0.0 }
        let moving = deltas.filter { $0 >= 0.013 }.count
        return Double(moving) / Double(deltas.count)
    }
}
