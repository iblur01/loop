import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore

/// Orchestrates the historical-offload (backfill) session: starting it, routing frames to the
/// `Backfiller` in arrival order, watchdog timeouts, and the post-offload liveness check.
///
/// This type is pure orchestration — the actual decode/persist state machine lives in
/// `Backfiller` (Core/Collect). `BLEConnectionManager` owns this coordinator and feeds it
/// frames + connection state; the coordinator calls back into the connection manager via
/// `send` to talk to the strap.
@MainActor
final class BLEOffloadCoordinator {
    /// Sends a framed command. Mirrors `BLEConnectionManager.send`.
    private let send: (_ command: WhoopCommand, _ payload: [UInt8], _ writeType: CBCharacteristicWriteType) -> Void
    private let log: (String) -> Void
    private let state: BLEDeviceState

    /// True while a historical offload session is in progress (frames route to Backfiller).
    private(set) var backfilling = false {
        didSet {
            state.backfilling = backfilling
            // Couche A → SyncCoordinator : signale l'activité d'offload (remplace l'ancien write
            // direct de state.isSyncing ; le coordinator possède désormais le calcul du status).
            onOffloadActiveChanged(backfilling)
        }
    }
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Idle watchdog: a single pending timer that re-checks `lastOffloadFrameAt` when it fires, instead
    /// of cancelling + re-creating a DispatchWorkItem for every frame.
    private var backfillTimeout: DispatchWorkItem?
    private var lastOffloadFrameAt = Date()
    private var watchdogBackfiller: Backfiller?
    /// Offload frames received in the current session (a timeout with progress is worth continuing).
    private var sessionFrameCount = 0
    /// Session diagnostics: offload frames by packet type, when SEND_HISTORICAL went out, and the
    /// delay to the first frame. Types 47/49/50 and the per-chunk acks are deliberately absent from
    /// the BLE log, so without this summary a served-then-stalled session and a never-served one
    /// both read as "sent, then nothing, then timeout".
    private var sessionFramesByType: [UInt8: Int] = [:]
    private var sessionStartedAt = Date()
    private var sessionFirstFrameAfter: TimeInterval?
    private weak var sessionBackfiller: Backfiller?
    /// Follow-up passes chained after progress-making timeouts since the last fresh request.
    private var continuationCount = 0
    /// Current power/usage context; wired by the connection manager. Defaults to the plain foreground floors.
    var powerContext: () -> PowerContext = { .foreground }
    /// Whether the live HR stream is currently on (user opted in AND foreground). Wired by the manager.
    var realtimeHRActive: () -> Bool = { false }
    /// True while we paused the live HR stream to give the offload the whole link.
    private var pausedRealtimeHR = false
    /// Asks the connection manager for a follow-up pass (bypasses the rate floor).
    var onContinuationRequested: () -> Void = {}
    /// Ordered queue of frames awaiting drain through the serial Backfiller task.
    private var backfillFrameQueue: [[UInt8]] = []
    /// Index of the next frame to drain; avoids the O(n) `removeFirst()` shift per frame.
    private var backfillQueueHead = 0
    /// True while the drain task is running (prevents a second drain task from launching).
    private var backfillDraining = false
    /// Invalidates suspended drain tasks when a session ends or the link drops.
    private var drainGeneration = 0
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private(set) var backfillStarted = false
    /// True while the drain awaits a METADATA frame's ingest (a HISTORY_END = chunk commit). The
    /// strap is silent by design during that time (it waits for our ack), so it is not idleness.
    private var commitInFlight = false
    /// `onOffloadFinished` held back while a continuation pass is about to start, so the
    /// express + full refresh does not contend with the next pass's commits on the same store.
    private var finishDeferred = false
    /// Background work waits on completion without a periodic polling timer.
    private var completionWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Fires if the strap goes silent mid-offload (the genuine offload-frame idle watchdog). Generous
    /// (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE airtime, so genuine offload
    /// frames can arrive in bursts with multi-second lulls between chunks — a short watchdog cut
    /// sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60

    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"

    /// Notifie le SyncCoordinator que l'offload (couche A) démarre/s'arrête.
    var onOffloadActiveChanged: (Bool) -> Void = { _ in }
    /// Notifie le SyncCoordinator qu'un offload vient de se terminer (lignes locales prêtes à uploader).
    var onOffloadFinished: () -> Void = {}
    /// Report failures so the UI can distinguish a blocked sync from a successful one.
    var onOffloadFailure: (_ message: String, _ archiveRequiredFreeBytes: Int64?) -> Void = { _, _ in }

    init(state: BLEDeviceState,
         send: @escaping (_ command: WhoopCommand, _ payload: [UInt8], _ writeType: CBCharacteristicWriteType) -> Void,
         log: @escaping (String) -> Void) {
        self.state = state
        self.send = send
        self.log = log
    }

    /// Reset all per-connection state. Called on disconnect.
    func reset() {
        backfillStarted = false
        backfilling = false
        completeWaiters(success: false)
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillQueueHead = 0
        drainGeneration &+= 1
        backfillDraining = false
        pausedRealtimeHR = false
        continuationCount = 0
        commitInFlight = false
        // The link dropped: no continuation will run, so release a held refresh now.
        flushDeferredFinish()
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8]) -> Bool {
        guard frame.count > 4 else { return false }
        switch frame[4] {
        case 47, 48, 49, 50: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 { newest = max(newest ?? 0, w) }
            i += 4
        }
        return newest
    }

    /// Record the newest unix the strap reports having, from a GET_DATA_RANGE response frame.
    func observeDataRangeFrame(_ frame: [UInt8]) {
        if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue,
           let newest = BLEOffloadCoordinator.dataRangeNewestUnix(from: frame) {
            strapNewestTs = newest
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger, backfiller: Backfiller?, connectHandshakeDone: Bool) {
        guard BLEOffloadCoordinator.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEOffloadCoordinator.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last, context: powerContext()) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        guard connectHandshakeDone, let backfiller else {
            log("Backfill: deferred — handshake or store not ready")
            return
        }
        UserDefaults.standard.set(now, forKey: BLEOffloadCoordinator.backfillLastAtKey)
        if trigger != .continuation { continuationCount = 0 }
        beginBackfill(backfiller: backfiller, connectHandshakeDone: connectHandshakeDone)
    }

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    private func beginBackfill(backfiller: Backfiller?, connectHandshakeDone: Bool) {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return
        }
        guard let backfiller else {
            // Store not ready yet. Do NOT force live HR — the type-47 backfill is the metric
            // source. Just log; the next periodic backfill tick will run once the store is ready.
            log("Backfill: store not ready — deferring to next periodic tick")
            return
        }
        backfiller.begin()
        sessionFrameCount = 0
        sessionFramesByType.removeAll()
        sessionStartedAt = Date()
        sessionFirstFrameAfter = nil
        sessionBackfiller = backfiller
        // Free the airtime: the live HR stream shares the link with the offload. Resumed on exit.
        if realtimeHRActive() {
            send(.toggleRealtimeHR, [0x00], .withoutResponse)
            pausedRealtimeHR = true
        }
        // Optional experiment (off by default): defensively leave high-freq-sync before offloading.
        if UserDefaults.standard.bool(forKey: "backfillDefensiveExitHighFreq") {
            send(.exitHighFreqSync, [0x00], .withoutResponse)
        }
        backfilling = true
        backfillStarted = true
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload uses [0x00] too. Plain offload — the strap streams HISTORY_START → type-47 records →
        // HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, [0x00], .withResponse)
        armBackfillTimeout(backfiller: backfiller)
        log("Backfill: session started — historical offload requested")
    }

    /// Wait for this session's real completion, or stop waiting when iOS expires the task.
    func waitForCompletion() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard backfilling, !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                completionWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.completionWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    private func completeWaiters(success: Bool) {
        let waiters = Array(completionWaiters.values)
        completionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: success) }
    }

    /// Feed a frame to the Backfiller preserving exact arrival order. Frames are appended
    /// synchronously (delegate order) and drained sequentially by a single task, so START /
    /// data / END chunk assembly is never reordered (Backfiller.ingest is async).
    func routeBackfillFrame(_ frame: [UInt8], backfiller: Backfiller?) {
        guard BLEOffloadCoordinator.isOffloadFrame(frame) else { return }
        sessionFramesByType[frame[4], default: 0] += 1
        if sessionFirstFrameAfter == nil { sessionFirstFrameAfter = Date().timeIntervalSince(sessionStartedAt) }
        // type-48 EVENTs must not keep a stalled offload alive (they flow even when no data does).
        if frame[4] != 48 {
            noteOffloadProgress(backfiller: backfiller)
            sessionFrameCount += 1
        }
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        let generation = drainGeneration
        Task { @MainActor in
            while generation == self.drainGeneration && self.backfillQueueHead < self.backfillFrameQueue.count {
                let f = self.backfillFrameQueue[self.backfillQueueHead]
                self.backfillQueueHead += 1
                // Release consumed frames in bulk so the array doesn't grow for the whole session.
                if self.backfillQueueHead >= 256 {
                    self.backfillFrameQueue.removeFirst(self.backfillQueueHead)
                    self.backfillQueueHead = 0
                }
                // Bracket chunk commits so their duration never counts as strap silence: touch the
                // idle clock before (the frame may have queued behind a slow commit) and after.
                let isMeta = f.count > 4 && f[4] == 49
                if isMeta {
                    self.lastOffloadFrameAt = Date()
                    self.commitInFlight = true
                }
                await backfiller?.ingest(f)
                guard generation == self.drainGeneration else { return }
                if isMeta {
                    self.commitInFlight = false
                    self.lastOffloadFrameAt = Date()
                }
                self.afterBackfillIngest(backfiller: backfiller)
            }
            guard generation == self.drainGeneration else { return }
            self.backfillFrameQueue.removeAll(keepingCapacity: true)
            self.backfillQueueHead = 0
            self.backfillDraining = false
        }
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest(backfiller: Backfiller?) {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        if let failure = backfiller?.failureReason {
            let required = backfiller?.archiveLimitReached == true ? backfiller?.archiveRequiredFreeBytes : nil
            onOffloadFailure(failure, required)
            exitBackfilling(reason: "failure: \(failure)", collector: nil)
        } else {
            exitBackfilling(reason: "HISTORY_COMPLETE", collector: nil)
        }
    }

    /// Record genuine offload progress. Cheap (a timestamp); the single watchdog timer re-checks it.
    private func noteOffloadProgress(backfiller: Backfiller?) {
        lastOffloadFrameAt = Date()
        if backfillTimeout == nil { scheduleWatchdog(after: TimeInterval(BLEOffloadCoordinator.backfillIdleTimeoutSeconds), backfiller: backfiller) }
    }

    /// (Re)start the idle watchdog from now. If the strap goes silent the timer fires and we exit the
    /// session (the durable strap_trim cursor means the next session resumes where we left off).
    private func armBackfillTimeout(backfiller: Backfiller?) {
        lastOffloadFrameAt = Date()
        backfillTimeout?.cancel()
        scheduleWatchdog(after: TimeInterval(BLEOffloadCoordinator.backfillIdleTimeoutSeconds), backfiller: backfiller)
    }

    private func scheduleWatchdog(after delay: TimeInterval, backfiller: Backfiller?) {
        watchdogBackfiller = backfiller
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfillTimeout = nil
            let idle = Date().timeIntervalSince(self.lastOffloadFrameAt)
            // A commit in progress gets a wider (still bounded) window so a wedged store
            // write cannot pin the session open forever.
            let base = TimeInterval(BLEOffloadCoordinator.backfillIdleTimeoutSeconds)
            let limit = self.commitInFlight ? base * 4 : base
            if idle < limit {
                self.scheduleWatchdog(after: limit - idle, backfiller: self.watchdogBackfiller)
                return
            }
            self.watchdogBackfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout", collector: nil)
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only. Between
    /// backfills the Collector sees only the live type-43 flood, which extractStreams ignores — the
    /// data comes from the next periodic offload.
    ///
    /// `collector` is passed through so `checkStrapLiveness` can read the biometric frontier; pass
    /// nil to skip the liveness check (e.g. when the collector isn't ready yet).
    func exitBackfilling(reason: String, collector: Collector?) {
        guard backfilling else { return }
        backfilling = false
        completeWaiters(success: reason == "HISTORY_COMPLETE")
        backfillTimeout?.cancel()
        backfillTimeout = nil
        watchdogBackfiller = nil
        backfillFrameQueue.removeAll()
        backfillQueueHead = 0
        drainGeneration &+= 1
        backfillDraining = false
        commitInFlight = false
        log("Backfill: session ended — reason=\(reason) · \(sessionSummary())")
        if pausedRealtimeHR {
            pausedRealtimeHR = false
            if realtimeHRActive() { send(.toggleRealtimeHR, [0x01], .withoutResponse) }
        }
        // A timeout that still moved data means a deep backlog: chain another pass right away
        // (capped) instead of waiting for the 15-min periodic floor.
        if reason == "timeout", sessionFrameCount > 0, continuationCount < powerContext().maxContinuations {
            continuationCount += 1
            log("Backfill: continuing deep backlog (pass \(continuationCount + 1))")
            finishDeferred = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.onContinuationRequested()
                // Continuation refused (link gone, paused, storage blocked…): refresh now.
                if !self.backfilling { self.flushDeferredFinish() }
            }
        } else {
            // Délègue au SyncCoordinator : il pilote le pipeline sériel drain→pull→refresh (et le
            // restore once-per-launch interne). On ne déclenche plus drain/restore/pull séparément ici.
            finishDeferred = false
            onOffloadFinished()
        }
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        }
        checkStrapLiveness(collector: collector)  // safety-net: strap ahead + frontier frozen ⇒ stuck?
    }

    /// One-line account of what the strap actually sent and what we acked during the session.
    private func sessionSummary() -> String {
        let types = sessionFramesByType.keys.sorted()
            .map { "\($0):\(sessionFramesByType[$0] ?? 0)" }.joined(separator: " ")
        let first = sessionFirstFrameAfter.map { String(format: "%.1fs", $0) } ?? "never"
        let ends = sessionBackfiller?.sessionEndCount ?? 0
        let acks = sessionBackfiller?.sessionAckCount ?? 0
        return "frames=[\(types)] firstFrame=\(first) ends=\(ends) acks=\(acks)"
    }

    /// The live HR stream is off for the whole offload (paused in `beginBackfill` when it was on).
    /// A foreground return or a user toggle that lands mid-offload must not write to the strap —
    /// the validated Mac sequence sends nothing but chunk acks while the strap is streaming — so it
    /// only records whether the stream should be re-enabled when the session ends.
    func holdRealtimeHR(resumeOnExit: Bool) {
        guard backfilling else { return }
        pausedRealtimeHR = resumeOnExit
    }

    private func flushDeferredFinish() {
        guard finishDeferred else { return }
        finishDeferred = false
        onOffloadFinished()
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness(collector: Collector?) {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let now = Date().timeIntervalSince1970
            let stuck = self.stuckDetector.observe(strapNewestTs: strapNewest,
                                                    ourFrontierTs: frontier ?? nil,
                                                    now: now)
            self.state.strapNeedsReboot = stuck
            if stuck {
                self.log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                self.send(.exitHighFreqSync, [0x00], .withoutResponse)
                self.send(.setClock, BLEBondingHandshake.setClockPayload(), .withoutResponse)
            }
        }
    }
}
