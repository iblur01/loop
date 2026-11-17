import Foundation
import UIKit
import Combine
import LoopStrapEngine
import WhoopStore

enum HealthProducerDiscoveryError: Error {
    case storeUnavailable
}

@MainActor
final class LoopDataRepository: ObservableObject {
    @Published private(set) var cache: LoopCache = .empty {
        // Le rapport d'entraînement dérive uniquement de `cache` : toute modification l'invalide.
        didSet { trainingReportMemo = nil }
    }
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshIsFull = false
    @Published private(set) var isPurging = false
    @Published private(set) var lastError: String?
    @Published private(set) var dbStats: (decodedRows: Int, decodedRowsTotal: Int, rawBatches: Int, rawBytes: Int, latestTs: Int?)?
    @Published private(set) var computeProgress: (stage: String, completed: Int, total: Int)?
    @Published var isStale = false

    private let store = LocalDataStore()
    private var refreshPending = false
    private var refreshPendingForce = false
    private var refreshTask: Task<Void, Never>?
    private var expressTask: Task<Void, Never>?
    private var lastComputedRowCount: Int?
    private var loadTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var healthChanges: AnyCancellable?
    private var settingsChanges: AnyCancellable?
    private var cacheWriteTail: Task<Void, Error>?
    private var trainingReportMemo: (day: String, zone: String, report: TrainingReport?)?

    /// Queue snapshots in the order they were published on the main actor. Without this,
    /// fire-and-forget writes from preferences can land after a newer computation.
    private func queueCacheSave(_ snapshot: LoopCache) -> Task<Void, Error> {
        let previous = cacheWriteTail
        let task = Task { [store] in
            if let previous { _ = try? await previous.value }
            try await store.saveCache(snapshot)
        }
        cacheWriteTail = task
        return task
    }

    /// Injected by `BLEConnectionManager` after `bootstrapStore()` completes (plan 07-05).
    /// `refresh()` delegates to this engine for local-first metric computation.
    /// `didSet` eagerly refreshes `dbStats` so the Device page shows the real row count
    /// immediately — without waiting for the full `compute(days:60)` pass to complete.
    var localMetricsEngine: LocalMetricsEngine? {
        didSet {
            NotificationCenter.default.post(name: Notification.Name("loop.healthEngineChanged"), object: nil)
            guard let engine = localMetricsEngine else { return }
            Task { self.dbStats = await engine.dbStats() }
            // Day bounds read before the first compute (Santé day view) need the zones of the
            // days already computed, persisted in the cache.
            Task {
                await self.loadTask?.value
                await engine.restoreDayTimeZones(self.cache.dayTimeZones ?? [:])
            }
        }
    }

    /// Injects (or replaces) the local metrics engine after initial construction.
    func attach(engine: LocalMetricsEngine?) {
        self.localMetricsEngine = engine
    }

    func heartRateSamples(from: Int, to: Int) async throws -> [HeartRateSample] {
        guard let engine = localMetricsEngine else { throw HealthProducerDiscoveryError.storeUnavailable }
        return try await engine.heartRateSamples(from: from, to: to)
    }

    /// Vue fusionnée bracelet + Apple Santé d'un jour local ("YYYY-MM-DD"), pour Aujourd'hui.
    /// nil tant que le moteur local n'est pas prêt. Lecture seule.
    func healthDayReport(for day: String) async -> HealthDayReport? {
        guard let engine = localMetricsEngine else { return nil }
        let raw = await engine.healthDayRaw(date: day)
        let settings = HealthReconciliationSettings()
        return HealthDayReportBuilder.build(
            raw: raw,
            snapshot: cache.daily.first { $0.date == day },
            bandSleep: cache.sleepSessions,
            bandWorkouts: cache.workoutSessions,
            priority: settings.load(),
            producerOrders: settings.producerOrders())
    }

    /// Liste les applications présentes dans l'historique local, indépendamment du jour affiché.
    func healthSampleProducers(kind: HealthSampleKind) async throws -> [HealthSampleProducer] {
        guard let engine = localMetricsEngine else { throw HealthProducerDiscoveryError.storeUnavailable }
        return try await engine.healthSampleProducers(kind: kind)
    }

    init() {
        healthChanges = NotificationCenter.default.publisher(for: Notification.Name("loop.healthInputsChanged"))
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestRefresh() }
            }
        settingsChanges = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let engine = self.localMetricsEngine else { return }
                    let key = healthComputeSettingsKey(HealthReconciliationSettings().load(),
                                                       maxHeartRate: engine.maxHeartRateOverride,
                                                       personalMaxHeartRate: self.personalMaxHeartRate(),
                                                       deviceId: engine.deviceId)
                    if self.cache.dayCounts?[key] != 1 { self.requestRefresh() }
                }
            }
        loadTask = Task {
            await load()
        }
    }

    /// Fire-and-forget refresh: stores the Task so `cancelRefresh()` can cancel it.
    /// No-op while a purge is in progress.
    func requestRefresh(force: Bool = false) {
        guard !isPurging else { return }
        if isRefreshing {
            refreshPending = true
            refreshPendingForce = refreshPendingForce || force
            return
        }
        // Priorité basse : le full (détection sommeil 60j) ne doit pas passer devant l'express.
        refreshTask = Task(priority: .utility) { await refresh(force: force) }
    }

    /// Applique une nouvelle difficulté de strain : écrit IMMÉDIATEMENT le cache durable (source de
    /// vérité, incluse au backup) puis déclenche un recalcul complet. Appelé au relâchement du
    /// slider. Sans cette écriture synchrone, la valeur ne vivait que dans UserDefaults (fragile,
    /// effacé à la réinstallation) et le cache gardait l'ancienne — d'où le retour au centre.
    func applyStrainDifficulty(_ value: Double) {
        var updated = cache
        updated.strainDifficulty = value
        cache = updated
        _ = queueCacheSave(updated)
        requestRefresh(force: true)
    }

    /// Rejette une séance d'exercice (faux positif) : l'ajoute aux rejections persistées (incluses
    /// au backup), la retire immédiatement de l'affichage, et la sauvegarde. À chaque recalcul, les
    /// séances re-détectées qui matchent une rejection sont automatiquement filtrées.
    func rejectWorkout(_ session: WorkoutSession) {
        var updated = cache
        var rejections = updated.rejectedWorkouts ?? []
        guard !rejections.contains(where: { $0.startTs == session.startTs && $0.endTs == session.endTs }) else { return }
        rejections.append(WorkoutRejection(startTs: session.startTs, endTs: session.endTs))
        updated.rejectedWorkouts = rejections
        updated.workoutSessions.removeAll { $0.id == session.id }
        cache = updated
        _ = queueCacheSave(updated)
        // Recalcul complet : le strain doit exclure le créneau rejeté. Le fingerprint de lignes ne
        // change pas (mêmes données brutes), donc seul un force déclenche le recalcul.
        requestRefresh(force: true)
    }

    /// Annule toutes les rejections (réaffiche les séances au prochain recalcul).
    func clearWorkoutRejections() {
        guard cache.rejectedWorkouts?.isEmpty == false else { return }
        var updated = cache
        updated.rejectedWorkouts = []
        cache = updated
        _ = queueCacheSave(updated)
        requestRefresh(force: true)
    }

    /// Filtre les séances re-détectées qui matchent une rejection utilisateur.
    private func applyWorkoutRejections(_ workouts: [WorkoutSession]) -> [WorkoutSession] {
        let rejections = cache.rejectedWorkouts ?? []
        guard !rejections.isEmpty else { return workouts }
        return workouts.filter { w in w.externalID != nil || !rejections.contains { $0.matches(w) } }
    }

    func requestBackgroundRefresh() async {
        beginBackgroundTask()
        // A short compute must not replace the 60-day cache or truncate baseline history.
        await refresh(force: false, days: 60)
        endBackgroundTask()
    }

    /// Pass express : strain + stress d'aujourd'hui sans détection du sommeil. Lancé à
    /// l'arrivée de données bracelet (`onDataIngested`) et au retour foreground stale, pour
    /// afficher du strain/stress en quelques secondes pendant que le pass full (sommeil +
    /// recovery) tourne en arrière-plan. No-op si today a déjà un snapshot réel (pass full
    /// terminé) — on ne clobber jamais une recovery calculée avec du nil.
    func requestExpressRefresh() {
        guard !isPurging, !isRefreshing, localMetricsEngine != nil else { return }
        if expressTask != nil { return }
        let todayStr = currentLocalDay()
        if let today = cache.daily.first(where: { $0.date == todayStr }), !today.isExpress {
            return
        }
        // Priorité haute : strain/stress « rapides » doivent s'intercaler devant le full en cours.
        expressTask = Task(priority: .userInitiated) { await runExpress() }
    }

    private func runExpress() async {
        await loadTask?.value
        guard let engine = localMetricsEngine else { return }
        defer { expressTask = nil }
        let strainDifficulty = await Task { @MainActor in UserPreferences.shared.strainDifficulty }.value
        let today = currentLocalDay()
        let measuredRHR = cache.daily.first { $0.date == today }?.restingHR
        guard let express = await engine.computeExpress(strainDifficulty: strainDifficulty,
                                                        referenceRestingHR: measuredRHR,
                                                        dayTimeZones: cache.dayTimeZones ?? [:],
                                                        personalMaxHeartRate: personalMaxHeartRate()) else { return }

        var updated = cache
        let todayStr = express.snapshot.date
        if let idx = updated.daily.firstIndex(where: { $0.date == todayStr }) {
            // Double-check : un pass full a pu terminer entre le pre-check synchrone et ici.
            // Si today est désormais réel, on garde ses recovery/sleep et on jette l'express.
            guard updated.daily[idx].isExpress else { return }
            updated.daily[idx] = express.snapshot
        } else {
            updated.daily.append(express.snapshot)
            updated.daily.sort { $0.date < $1.date }
        }
        if let stress = express.stress { updated.stress = stress }
        var hrByTs: [Int: HeartRateSample] = [:]
        for s in updated.hrSamples { hrByTs[s.ts] = s }
        for s in express.hrSamples { hrByTs[s.ts] = s }
        updated.hrSamples = Array(hrByTs.values.sorted { $0.ts < $1.ts }.suffix(1_000))
        cache = updated
        try? await queueCacheSave(updated).value
    }

    /// FC max personnelle saisie (Profil), convertie pour le moteur ; nil = estimation automatique.
    /// Lue ici et passée explicitement au moteur, qui ne dépend pas des préférences.
    private func personalMaxHeartRate() -> MaxHeartRateReference? {
        UserPreferences.shared.resolvedMaxHeartRate().flatMap {
            MaxHeartRateReference(bpm: Double($0.bpm), provenance: $0.provenance.rawValue)
        }
    }

    /// Ré-attache les RPE enregistrés aux séances du cache sans recalcul (saisie RPE : la table
    /// n'entre pas dans les révisions d'entrée). N'affecte aucun strain.
    func reloadPerceivedEfforts() async {
        await loadTask?.value
        guard let engine = localMetricsEngine else { return }
        let before = cache.workoutSessions
        let sessions = await engine.attachPerceivedEfforts(before)
        // A compute that finished meanwhile already attached the current RPE: keep its result.
        guard cache.workoutSessions == before, sessions != before else { return }
        var updated = cache
        updated.workoutSessions = sessions
        cache = updated
        try? await queueCacheSave(updated).value
    }

    /// Façade RPE (saisie dans le détail d'une séance) ; nil tant que le moteur local n'est pas prêt.
    var perceivedEffortStore: PerceivedEffortStore? { localMetricsEngine?.perceivedEffortStore }

    // MARK: - Séances saisies à la main

    /// Façade de saisie manuelle ; nil tant que le moteur local n'est pas prêt.
    var manualWorkoutStore: ManualWorkoutStore? { localMetricsEngine?.manualWorkoutStore }

    /// Résultat d'une saisie : nouvelle séance manuelle, ou effort rattaché à la séance
    /// enregistrée qui couvre déjà ce créneau.
    enum ManualEntryOutcome: Equatable {
        case created(externalID: String)
        case attachedEffort(sessionID: String)
    }

    /// Enregistre la saisie selon `draft.plan(existing:)` :
    /// - aucune séance enregistrée ne la recouvre : ligne `external_workout` manuelle + RPE
    ///   (une transaction), puis recalcul — l'insertion avance la révision d'entrée du jour ;
    /// - une séance montre / Santé de sport compatible la recouvre : AUCUNE ligne n'est créée
    ///   (ni doublon ni double charge), le RPE et la note sont écrits sur cette séance.
    /// Aucune formule n'est touchée. `existing` = séances du cache par défaut.
    @discardableResult
    func saveManualEntry(_ draft: ManualWorkoutDraft, existing: [WorkoutSession]? = nil,
                         now: Date = Date()) async throws -> ManualEntryOutcome {
        await loadTask?.value
        if let error = draft.validationError(now: now) { throw error }
        guard let manual = manualWorkoutStore, let efforts = perceivedEffortStore else {
            throw HealthProducerDiscoveryError.storeUnavailable
        }
        switch draft.plan(existing: existing ?? cache.workoutSessions) {
        case .attachEffort(let target, _):
            try await efforts.save(workoutId: target.perceivedEffortKey, rpe: draft.rpe, note: draft.note, now: now)
            let computing = isRefreshing
            await reloadPerceivedEfforts()
            // Un calcul en cours a pu lire les RPE avant cette écriture et ignore alors le
            // rechargement : la table RPE n'avance pas la révision, on relance explicitement.
            if computing || isRefreshing { requestRefresh(force: true) }
            return .attachedEffort(sessionID: target.id)
        case .create:
            let saved = try await manual.save(sport: draft.sport, start: draft.start,
                                              durationMinutes: draft.durationMinutes,
                                              rpe: draft.rpe, note: draft.note, now: now)
            requestRefresh()
            return .created(externalID: saved.id)
        }
    }

    /// Vrai si la séance (id `external_workout`) a été saisie dans Loop ; seule condition de suppression.
    func isManualWorkout(externalID: String) async -> Bool {
        guard let store = manualWorkoutStore else { return false }
        return await store.isManual(id: externalID)
    }

    /// Supprime une séance saisie à la main (jamais une séance importée), la retire de
    /// l'affichage et relance le calcul. Retourne false si la séance n'est pas manuelle.
    @discardableResult
    func deleteManualWorkout(externalID: String) async throws -> Bool {
        guard let store = manualWorkoutStore else { return false }
        guard try await store.delete(id: externalID) else { return false }
        var updated = cache
        updated.workoutSessions.removeAll { $0.externalID == externalID }
        cache = updated
        _ = queueCacheSave(updated)
        requestRefresh()
        return true
    }

    /// Statistiques et indicateurs d'entraînement dérivés du cache. Lecture seule : aucun accès
    /// disque ni réseau. Mémorisé, recalculé seulement quand `cache` (ou le jour local) change.
    /// nil quand le cache ne contient aucune donnée exploitable.
    var trainingReport: TrainingReport? {
        let today = currentLocalDay()
        let zone = LoopDataRepository.deviceZone()
        if let memo = trainingReportMemo, memo.day == today, memo.zone == zone.identifier { return memo.report }
        let report = TrainingReportBuilder.make(cache: cache, today: today, deviceZone: zone)
        trainingReportMemo = (today, zone.identifier, report)
        return report
    }

    /// Séances du cache dont le début tombe sur le jour local `day`, plus récentes d'abord.
    func workoutSessions(forDay day: String) -> [WorkoutSession] {
        let zone = LoopDataRepository.deviceZone()
        return cache.workoutSessions
            .filter { TrainingReportBuilder.localDay(of: $0, cache: cache, deviceZone: zone) == day }
            .sorted { $0.startTs > $1.startTs }
    }

    private static func deviceZone() -> TimeZone { LocalDay.deviceZone }

    /// Jour local « aujourd'hui » (YYYY-MM-DD), même politique de fuseau que computeCore.
    private func currentLocalDay() -> String {
        if let engine = localMetricsEngine { return engine.localDayKey() }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        fmt.timeZone = TimeZone.autoupdatingCurrent
        return fmt.string(from: Date())
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LoopCompute") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        computeProgress = nil
    }

    func refresh(force: Bool = false, days: Int = 60) async {
        await loadTask?.value

        // Le pass express est PRIORITAIRE sur le full 60j : on l'attend avant de lancer
        // le calcul lourd. Sans ça, computeCore (4 streams × 30h × 60 jours) monopolise
        // l'actor LocalMetricsEngine et l'express reste bloqué derrière — l'utilisateur
        // voit "—" pendant plusieurs minutes, surtout en économie d'énergie où le CPU est
        // throttled. L'express (today-only, ~4 lectures bornées) termine en quelques
        // secondes et libère l'actor pour le full.
        if let express = expressTask {
            await express.value
        }

        guard let engine = localMetricsEngine else { return }
        if isRefreshing {
            refreshPending = true
            refreshPendingForce = refreshPendingForce || force
            return
        }
        isRefreshing = true
        lastError = nil
        defer {
            isRefreshing = false
            refreshIsFull = false
            computeProgress = nil
        }

        // Express results omit sleep and recovery. They must never satisfy the revision
        // fast path or the engine's unchanged-day cache reuse after a restart.
        var effectiveForce = force || cache.daily.contains(where: \.isExpress)
            || (!cache.daily.isEmpty && !cache.expressMigrationComplete)

        repeat {
            refreshPending = false
            effectiveForce = effectiveForce || refreshPendingForce
            refreshPendingForce = false

            let currentStats = await engine.dbStats()
            dbStats = currentStats
            let revision: (instance: String, revision: Int)
            do {
                revision = try await engine.inputRevision()
            } catch {
                lastError = "Impossible de vérifier les données : \(error.localizedDescription)"
                break
            }
            let revisionKey = "@inputRevision:\(revision.instance)"
            let personalMaxHR = personalMaxHeartRate()
            let settingsKey = healthComputeSettingsKey(HealthReconciliationSettings().load(), maxHeartRate: engine.maxHeartRateOverride,
                                                       personalMaxHeartRate: personalMaxHR, deviceId: engine.deviceId)
            let revisionUnchanged = cache.dayCounts?[revisionKey] == revision.revision
                && cache.dayCounts?["@window:\(currentLocalDay())"] == 1
                && cache.dayCounts?[settingsKey] == 1
                && cache.dayCounts?[engine.zoneCacheKey()] == 1
            let cacheHasLocalSurfaces = !cache.daily.isEmpty
            if !effectiveForce && revisionUnchanged && cacheHasLocalSurfaces {
                isStale = false
                return
            }
            let forceThisPass = effectiveForce
            effectiveForce = false

            do {
                computeProgress = nil
                let cacheHasSurfaces = !self.cache.daily.isEmpty
                let previous: LocalComputeResult? = cacheHasSurfaces
                    ? LocalComputeResult(
                        daily: self.cache.daily,
                        sleepSessions: self.cache.sleepSessions,
                        workoutSessions: self.cache.workoutSessions,
                        stress: self.cache.stress,
                        hrSamples: self.cache.hrSamples,
                        dayTimeZones: self.cache.dayTimeZones ?? [:])
                    : nil
                let isFull = forceThisPass || previous == nil || cache.dayCounts?[revisionKey] == nil
                    || cache.dayCounts?[settingsKey] != 1
                refreshIsFull = isFull
                let strainDifficulty = await Task { @MainActor in UserPreferences.shared.strainDifficulty }.value
                let rejectedRanges = (self.cache.rejectedWorkouts ?? []).map { (start: $0.startTs, end: $0.endTs) }
                let (result, dayCounts) = try await engine.computeCore(
                    days: max(60, days),
                    previous: previous,
                    previousDayCounts: self.cache.dayCounts,
                    forceFull: isFull,
                    strainDifficulty: strainDifficulty,
                    rejectedRanges: rejectedRanges,
                    personalMaxHeartRate: personalMaxHR
                ) { [weak self] stage, completed, total in
                    Task { @MainActor [weak self] in self?.computeProgress = (stage, completed, total) }
                }
                if result.daily.isEmpty && (!self.cache.daily.isEmpty || currentStats.decodedRows > 0) {
                    lastError = "Recalcul local vide: cache existant conservé"
                    break
                }
                var updated = self.cache
                updated.daily = result.daily
                updated.sleepSessions = result.sleepSessions
                updated.workoutSessions = applyWorkoutRejections(result.workoutSessions)
                updated.stress = result.stress
                updated.hrSamples = result.hrSamples
                updated.updatedAt = Date()
                updated.computedRowCount = currentStats.decodedRows
                updated.dayCounts = dayCounts
                updated.dayTimeZones = result.dayTimeZones
                updated.strainDifficulty = strainDifficulty
                if isFull { updated.expressMigrationComplete = true }
                self.cache = updated
                try await queueCacheSave(updated).value
                lastComputedRowCount = currentStats.decodedRows
                let after = try await engine.inputRevision()
                isStale = dayCounts["@inputRevision:\(after.instance)"] != after.revision
            } catch is CancellationError {
                break
            } catch {
                lastError = error.localizedDescription
            }
            dbStats = await engine.dbStats()
        } while refreshPending
    }

    // MARK: - Purge

    /// Deletes all decoded-stream rows from every table. Resets cache.
    func purgeAll() {
        guard let engine = localMetricsEngine, !isPurging else { return }
        cancelRefresh()
        isPurging = true
        Task {
            defer { self.isPurging = false }
            do {
                _ = try await engine.purgeAll()
                self.dbStats = await engine.dbStats()
                self.lastComputedRowCount = nil
                var empty = self.cache
                empty.daily = []
                empty.sleepSessions = []
                empty.workoutSessions = []
                empty.stress = nil
                empty.hrSamples = []
                empty.updatedAt = nil
                self.cache = empty
                try? await self.queueCacheSave(empty).value
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Recharge le cache depuis le disque. Appelé après une restauration iCloud qui a remplacé
    /// `cache.json` sous le store : l'UI repart du snapshot restauré sans recompute immédiat.
    func reloadCacheFromDisk() async {
        do {
            cache = try await store.loadCache()
            lastComputedRowCount = (!cache.daily.isEmpty && !cache.hrSamples.isEmpty)
                ? cache.computedRowCount : nil
            isStale = false
        } catch {
            lastError = "Cache local illisible: \(error.localizedDescription)"
        }
    }

    private func load() async {
        do {
            cache = try await store.loadCache()
            // P2 — restore the persisted watermark so an unchanged-data relaunch skips the
            // full 60-day recompute. Only trust it when the cache actually carries local
            // surfaces; a daily-only legacy cache must still recompute to populate hrSamples.
            if !cache.daily.isEmpty && !cache.hrSamples.isEmpty {
                lastComputedRowCount = cache.computedRowCount
            }
            // Source de vérité = le cache (durable, inclus au backup) : on réinjecte TOUJOURS la
            // difficulté dans UserPreferences au lancement. UserDefaults n'est qu'un miroir rapide.
            let restored = cache.strainDifficulty
            await MainActor.run { UserPreferences.shared.applyRestored(restored) }
        } catch {
            lastError = "Cache local illisible: \(error.localizedDescription)"
            cache = .empty
        }
    }
}


// MARK: - Training report (lecture seule sur le cache)

/// Sortie de l'analyse d'entraînement : statistiques + indicateurs explicables.
struct TrainingReport: Equatable {
    let stats: TrainingStatsReport
    let insights: [TrainingInsight]
}

/// Construit `TrainingInputs` depuis un `LoopCache` puis lance `TrainingStats` et
/// `TrainingAdviceEngine`. Pur : aucune horloge, aucun fuseau implicite, aucune E/S.
enum TrainingReportBuilder {
    /// Numéro de jour (jours écoulés depuis 1970-01-01) d'une clé "YYYY-MM-DD" ; nil si invalide.
    static func dayOrdinal(_ day: String) -> Int? {
        guard let c = LocalDay.components(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let d = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) else { return nil }
        return Int((d.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Jour local d'une séance : fuseau connu du jour du cache si disponible, sinon celui de l'appareil.
    static func localDay(of session: WorkoutSession, cache: LoopCache, deviceZone: TimeZone) -> String {
        let ts = Double(session.startTs)
        let guess = LocalDay.key(ts, in: deviceZone)
        if let id = cache.dayTimeZones?[guess], let zone = TimeZone(identifier: id) {
            return LocalDay.key(ts, in: zone)
        }
        return guess
    }

    /// Libellé expérimental de la récupération : HRV Santé (SDNN) ou FC médiane de nuit, comme
    /// `RecoveryCoachModel.usesExperimentalHealthRecovery`. nil pour une récupération du bracelet.
    static let experimentalRecoveryLabel = "apple_health_recovery"

    static func experimentalRecoveryLabel(_ d: DailySnapshot) -> String? {
        let experimental = d.recoveryHRVMetric == "sdnn"
            || d.recoveryRHRObservation?.sourceID.contains("sleep-median-hr") == true
        return experimental ? experimentalRecoveryLabel : nil
    }

    /// Efficacité de sommeil en fraction 0...1, convention du moteur (`DailySleepSummary.efficiency`,
    /// TST / TIB). Les valeurs de 1 (exclu) à 100 sont des snapshots hérités en pourcentage et sont
    /// converties explicitement ; toute autre valeur est rejetée (nil).
    static func normalizedEfficiency(_ value: Double?) -> Double? {
        guard let v = value, v.isFinite else { return nil }
        if (0...1).contains(v) { return v }
        if v > 1 && v <= 100 { return v / 100 }
        return nil
    }

    static func make(cache: LoopCache, today: String, deviceZone: TimeZone) -> TrainingReport? {
        guard let asOf = dayOrdinal(today) else { return nil }
        // Les snapshots « express » (strain partiel, sans sommeil) sont provisoires : exclus.
        let finalDays = cache.daily.filter { !$0.isExpress }
        var days: [TrainingDayRecord] = []
        var sleep: [TrainingSleepRecord] = []
        for d in finalDays {
            guard let ord = dayOrdinal(d.date) else { continue }
            days.append(TrainingDayRecord(day: ord, strain: d.strain, strainConfidence: d.targetStrainConfidence,
                                          recovery: d.recovery, recoveryConfidence: d.recoveryStatus,
                                          recoveryExperimentalLabel: experimentalRecoveryLabel(d), source: "loop"))
            let efficiency = normalizedEfficiency(d.efficiency)
            if d.totalSleepMin != nil || efficiency != nil {
                sleep.append(TrainingSleepRecord(day: ord, totalSleepMin: d.totalSleepMin, efficiency: efficiency,
                                                 disturbances: d.disturbances, source: "loop"))
            }
        }
        let workouts: [TrainingWorkoutRecord] = cache.workoutSessions.compactMap { w in
            guard let ord = dayOrdinal(localDay(of: w, cache: cache, deviceZone: deviceZone)) else { return nil }
            return TrainingWorkoutRecord(id: w.id, day: ord, kind: w.kind, sportType: w.sportType,
                                         startTs: w.startTs, endTs: w.endTs, durationS: w.durationS,
                                         strain: w.strain, perceivedEffort: w.perceivedEffort,
                                         source: w.sourceName)
        }
        guard let inputs = TrainingInputsAdapter.makeInputs(asOfDay: asOf, days: days, sleep: sleep, workouts: workouts)
        else { return nil }
        return TrainingReport(stats: TrainingStats.compute(inputs), insights: TrainingAdviceEngine.insights(for: inputs))
    }
}
