// MARK: - SleepClassifier

/// Deterministic sleep staging classifier: EpochFeatures → SleepStage labels.
///
/// Ports the Stage-2 and Stage-3 logic from `sleep_features.py` (§4):
///   - Stage 2 (`classifyEpochs`): per-night-relative percentile bands → rule tree.
///   - Stage 3a (`smoothLabels`): majority-window smoothing to kill isolated 30 s flips.
///   - Stage 3b (`reimposePhhysiology`): no-REM latency guard + deep-late downgrade.
///
/// Classifier constants (mirroring `sleep_features.py`):
///
/// | Constant             | Python name            | Value |
/// |----------------------|------------------------|-------|
/// | hrLo percentile      | STAGE_HR_LOW_PCT       | 25.0  |
/// | hrHi percentile      | STAGE_HR_HIGH_PCT      | 70.0  |
/// | hf/rmssd percentile  | STAGE_HRV_HIGH_PCT     | 70.0  |
/// | hrVar percentile     | STAGE_HRV_VAR_HIGH_PCT | 65.0  |
/// | rrvHi percentile     | STAGE_RRV_HIGH_PCT     | 65.0  |
/// | rrvLo percentile     | STAGE_RRV_LOW_PCT      | 50.0  |
/// | still threshold      | STAGE_STILL_MOVE_FRAC  | 0.10  |
/// | moving threshold     | STAGE_WAKE_MOVE_FRAC   | 0.15  |
/// | smooth window        | SMOOTH_EPOCHS          | 5     |
/// | no-REM latency (min) | NO_REM_AFTER_ONSET_MIN | 15.0  |
/// | deep-late fraction   | DEEP_LATE_FRACTION     | 0.95  |

// MARK: - classifyEpochs

/// Classify a sequence of epoch features into per-epoch sleep stage labels.
///
/// Ports `classify_epochs` from `sleep_features.py` (§4 Stage 2).
///
/// Physiology encoded (research §3):
/// - **wake**: sustained motion + activated cardiac (or no HR to vet motion).
/// - **deep**: still + high parasympathetic tone + low HR + regular respiration.
/// - **rem**: still + activated cardiac + irregular respiration (or dual-signal cardiac
///   without respiration data).
/// - **light**: everything else; the honest default when HRV/resp are missing.
///
/// Percentile bands (hrLo/hrHi/rmssdHi/hrVarHi/rrvHi/rrvLo) are computed over
/// **ckSleep == true epochs only** (Pattern 3 — so wake epochs don't skew the cardiac
/// bands). Falls back to all epochs when no ckSleep epoch exists.
///
/// **Phase 3 note (D-01):** `parasympHigh = rmssdHigh` in Phase 3 because `hf` is
/// always `.nan` (frequency-domain HRV not yet computed — see `D-01`). Phase 5
/// enables `hfHigh` when `hrvFromRR` fills `hf`/`lf`/`lfhf` via Welch PSD.
///
/// - Parameter features: Per-epoch features from `extractFeatures`. May be empty.
/// - Returns: Array of `SleepStage` labels, same length as `features`. Empty if input is empty.
public func classifyEpochs(_ features: [EpochFeatures]) -> [SleepStage] {
    let n = features.count
    guard n > 0 else { return [] }

    // Session-relative reference distributions: computed over ckSleep == true epochs
    // so wake epochs don't bias the cardiac bands (Pattern 3).
    let sleepFeats = features.filter { $0.ckSleep }.isEmpty ? features : features.filter { $0.ckSleep }

    // Extract per-signal arrays (NaN values are kept — percentile() filters .nan via
    // the Python _pct helper: sorted(v for v in values if v is not None and math.isfinite(v))).
    // We mirror that by only keeping finite values for percentile computation.
    let hrVals    = sleepFeats.map { $0.hr    }.filter { $0.isFinite }
    let hfVals    = sleepFeats.map { $0.hf    }.filter { $0.isFinite }
    let rmssdVals = sleepFeats.map { $0.rmssd }.filter { $0.isFinite }
    let hrVarVals = sleepFeats.map { $0.hrVar }.filter { $0.isFinite }
    let rrvVals   = sleepFeats.map { $0.rrv   }.filter { $0.isFinite }

    // Per-night-relative bands (§4 Stage 2 constants — see table in module doc).
    let hrLo    = (try? percentile(hrVals,    25.0)) ?? Double.nan
    let hrHi    = (try? percentile(hrVals,    70.0)) ?? Double.nan
    let hfHi    = (try? percentile(hfVals,    70.0)) ?? Double.nan
    let rmssdHi = (try? percentile(rmssdVals, 70.0)) ?? Double.nan
    let hrVarHi = (try? percentile(hrVarVals, 65.0)) ?? Double.nan
    let rrvHi   = (try? percentile(rrvVals,   65.0)) ?? Double.nan
    let rrvLo   = (try? percentile(rrvVals,   50.0)) ?? Double.nan

    return features.map {
        classifyOne($0,
                    hrLo: hrLo, hrHi: hrHi,
                    hfHi: hfHi, rmssdHi: rmssdHi,
                    hrVarHi: hrVarHi,
                    rrvHi: rrvHi, rrvLo: rrvLo)
    }
}

// MARK: - smoothLabels

/// Majority-window smoothing over the epoch label sequence.
///
/// Ports `smooth_labels` from `sleep_features.py` (§4 Stage 3a).
///
/// Applies a centered window of `window` epochs (forced odd). For each epoch, counts
/// the label frequencies in the window and keeps the most common label. On a tie,
/// the incumbent label (current epoch's input label) is preserved — this prevents
/// artificial drift during transitions.
///
/// - Parameters:
///   - labels: Per-epoch stage labels from `classifyEpochs`.
///   - window: Window size in epochs (default 5 = SMOOTH_EPOCHS; forced odd internally).
/// - Returns: Smoothed label array, same length as input. Returns input unchanged if empty or `window <= 1`.
public func smoothLabels(_ labels: [SleepStage], window: Int) -> [SleepStage] {
    let n = labels.count
    guard n > 0, window > 1 else { return labels }

    // Force window to odd (mirrors Python's `if window % 2 == 0: window += 1`).
    var w = window
    if w % 2 == 0 { w += 1 }
    let half = w / 2

    var out = [SleepStage]()
    out.reserveCapacity(n)

    for i in 0..<n {
        let lo = max(0, i - half)
        let hi = min(n, i + half + 1)
        let win = labels[lo..<hi]

        // Count label occurrences in window.
        var counts: [SleepStage: Int] = [:]
        for s in win { counts[s, default: 0] += 1 }

        let best = counts.values.max() ?? 0

        // Incumbent-preservation : si le label courant est l'un des gagnants, on le garde.
        if counts[labels[i]] == best {
            out.append(labels[i])
        } else {
            // Départage DÉTERMINISTE des ex æquo : on prend le stade qui apparaît en PREMIER
            // dans la fenêtre (ordre temporel), comme `Counter.most_common` côté Python (ordre
            // d'insertion = premier vu). L'ancien `winners[0]` lisait l'ordre d'itération d'un
            // Dictionary, randomisé par process (hash seed) → des epochs basculaient de stade
            // d'un lancement à l'autre, faisant varier le TST de plusieurs minutes au même input.
            let winner = win.first { counts[$0] == best } ?? labels[i]
            out.append(winner)
        }
    }
    return out
}

// MARK: - reimposePhhysiology

/// Re-impose physiological constraints on the hypnogram (§4 Stage 3b).
///
/// Ports `reimpose_physiology` from `sleep_features.py`.
///
/// Two rules:
/// 1. **No REM before 15 minutes after sleep onset** (`NO_REM_AFTER_ONSET_MIN = 15.0`):
///    early-REM epochs within the first 30 epochs after onset are relabelled to `.light`.
/// 2. **Deep-late downgrade** (`DEEP_LATE_FRACTION = 0.95`):
///    deep epochs with `f.clock > 0.95` (i.e., in the last 5% of the sleep period) are
///    relabelled to `.light` — a loose artifact guard (not a strict first-third rule).
///
/// Only epochs with index in `[onsetIdx, finalWakeIdx]` (inclusive) are modified;
/// pre-onset and post-final-wake epochs are returned unchanged.
///
/// - Parameters:
///   - labels: Smoothed stage labels from `smoothLabels`.
///   - features: Per-epoch features (used to read `f.clock` for the deep-late rule).
///   - onsetIdx: Index of the first sleep epoch (sleep onset).
///   - finalWakeIdx: Index of the last wake epoch bounding the sleep period.
/// - Returns: Physiology-corrected label array, same length as input. Returns `[]` if empty.
public func reimposePhhysiology(
    _ labels: [SleepStage],
    features: [EpochFeatures],
    onsetIdx: Int,
    finalWakeIdx: Int
) -> [SleepStage] {
    guard !labels.isEmpty else { return [] }

    // NO_REM_AFTER_ONSET_MIN = 15.0 min; EPOCH_S = 30 s → 30 epochs.
    let noRemEpochs = Int((15.0 * 60.0 / epochS).rounded())
    // DEEP_LATE_FRACTION = 0.95
    let deepLateFraction: Double = 0.95

    var out = labels
    for i in 0..<out.count {
        guard i >= onsetIdx, i <= finalWakeIdx else { continue }
        // Rule 1: no REM before latency window.
        if out[i] == .rem && (i - onsetIdx) < noRemEpochs {
            out[i] = .light
        }
        // Rule 2: deep in the last 5% of the sleep period → downgrade to light.
        if out[i] == .deep && i < features.count && features[i].clock > deepLateFraction {
            out[i] = .light
        }
    }
    return out
}

// MARK: - enforceMinBout

/// Stage 3c — minimum bout-duration smoothing (**LOCAL DIVERGENCE** from the Python oracle).
///
/// Real sleep occurs in multi-minute bouts; the 30 s epoch classifier plus the 5-epoch
/// majority window still leave short, physiologically implausible runs that make the
/// hypnogram look noisy — rapid deep↔light↔rem↔wake flips. This pass iteratively absorbs
/// any run shorter than its stage's `minEpochs` threshold into the neighbouring run,
/// producing fewer, longer, more readable segments.
///
/// Greedy shortest-run absorption (guaranteed to converge — each pass removes ≥1 run):
///   1. Group labels into contiguous runs.
///   2. Find the shortest run with `len < threshold(stage)`. Stop if none.
///   3. Relabel it to its **longer** neighbour (tie → previous; edge run → only neighbour).
///   4. Re-group (adjacent same-stage runs coalesce) and repeat.
///
/// There is no equivalent step in `sleep_features.py`; this is accepted divergence under
/// the local-first principle (see `minBoutEpochs`).
///
/// - Parameters:
///   - labels: Physiology-corrected labels from `reimposePhhysiology` (post edge-forcing).
///   - minEpochs: Per-stage minimum bout length in epochs (default `minBoutEpochs`).
/// - Returns: Smoothed labels, same length as input. Unchanged if fewer than 2 epochs.
public func enforceMinBout(_ labels: [SleepStage],
                           minEpochs: [SleepStage: Int] = minBoutEpochs) -> [SleepStage] {
    guard labels.count > 1 else { return labels }
    var out = labels

    while true {
        // Group into contiguous runs: (stage, start index, length).
        var runs: [(stage: SleepStage, start: Int, len: Int)] = []
        for (i, s) in out.enumerated() {
            if let last = runs.last, last.stage == s {
                runs[runs.count - 1].len += 1
            } else {
                runs.append((stage: s, start: i, len: 1))
            }
        }
        guard runs.count > 1 else { break }

        // Shortest sub-threshold run wins (ties → earliest, deterministic).
        var victim: Int? = nil
        var victimLen = Int.max
        for (idx, r) in runs.enumerated() {
            let thr = minEpochs[r.stage] ?? 0
            if r.len < thr && r.len < victimLen {
                victim = idx
                victimLen = r.len
            }
        }
        guard let v = victim else { break }

        // Absorb into the longer neighbour (tie → previous; edge → only neighbour).
        let prev = v > 0 ? runs[v - 1] : nil
        let next = v < runs.count - 1 ? runs[v + 1] : nil
        let replacement: SleepStage
        switch (prev, next) {
        case let (p?, n?): replacement = (n.len > p.len) ? n.stage : p.stage
        case let (p?, nil): replacement = p.stage
        case let (nil, n?): replacement = n.stage
        case (nil, nil):    return out  // single run — unreachable (runs.count > 1)
        }

        let r = runs[v]
        for i in r.start..<(r.start + r.len) { out[i] = replacement }
    }
    return out
}

// MARK: - Helpers

/// Classify a single epoch from session-relative percentile bands.
///
/// Ports `_classify_one` from `sleep_features.py`.
///
/// Decision tree (in priority order):
/// 1. **Wake**: moving (`moveFrac >= 0.15`) AND cardiac activated (or no HR).
/// 2. **Deep**: still (`moveFrac <= 0.10`) AND parasympHigh AND hrLow AND rrvRegular.
/// 3. **REM**: still AND cardiac activated AND rrvIrregular.
/// 4. **REM fallback**: still AND hrHigh AND hrVarHigh AND NaN RRV (dual-signal without resp data).
/// 5. **Light**: everything else.
///
/// **Piège 5 (motion gate):** Uses `f.moveFrac` (scale-robust epoch fraction), NOT
/// the Cole–Kripke count or `f.rmssd`.
///
/// **Piège 6 (RRV NaN = regular):** `rrvRegular = !f.rrv.isFinite || f.rrv <= rrvLo`.
/// Missing respiration is treated as "regular" — pro-deep bias that degrades gracefully
/// (no resp data → deep still reachable; REM harder to call). Mirrors Python:
/// `rrv_regular = (not math.isfinite(f.rrv)) or (rrv_lo is not None and f.rrv <= rrv_lo)`.
///
/// **Phase 3 (D-01):** `parasympHigh = rmssdHigh` only. `hfHigh` is always false in
/// Phase 3 because `hf` is always `.nan` (frequency-domain HRV not computed — see D-01).
/// Phase 5 enables `hfHigh` when `hrvFromRR` fills `hf`/`lf`/`lfhf` via Welch PSD.
private func classifyOne(
    _ f: EpochFeatures,
    hrLo: Double,
    hrHi: Double,
    hfHi: Double,
    rmssdHi: Double,
    hrVarHi: Double,
    rrvHi: Double,
    rrvLo: Double
) -> SleepStage {
    // --- HR gates ---
    let hasHR       = f.hr.isFinite
    let hrLow       = hasHR && hrLo.isFinite && f.hr <= hrLo
    let hrHigh      = hasHR && hrHi.isFinite && f.hr >= hrHi

    // --- Parasympathetic gate ---
    // Phase 3 (D-01): hfHigh is always false (hf == .nan) → parasympHigh = rmssdHigh.
    // Phase 5 extends this to hfHigh || rmssdHigh when Welch PSD fills hf.
    let hfHigh      = f.hf.isFinite && hfHi.isFinite && f.hf >= hfHi   // always false Phase 3 (D-01)
    let rmssdHigh   = f.rmssd.isFinite && rmssdHi.isFinite && f.rmssd >= rmssdHi
    let parasympHigh = hfHigh || rmssdHigh  // = rmssdHigh in Phase 3 per D-01

    // --- Cardiac activation gate ---
    let hrVarHigh      = f.hrVar.isFinite && hrVarHi.isFinite && f.hrVar >= hrVarHi
    let cardiacActivated = hrHigh || hrVarHigh

    // --- Respiration gates ---
    let rrvIrregular = f.rrv.isFinite && rrvHi.isFinite && f.rrv >= rrvHi
    // Piège 6: NaN RRV = regular (pro-deep bias; see module doc).
    let rrvRegular   = !f.rrv.isFinite || (rrvLo.isFinite && f.rrv <= rrvLo)

    // --- Motion gates (Piège 5: use moveFrac, NOT count) ---
    let still  = f.moveFrac <= moveFracStillMax    // 0.10
    let moving = f.moveFrac >= moveFracMovingMin   // 0.15

    // ── WAKE ──: sustained motion + activated cardiac (or no HR to vet the motion).
    if moving && (cardiacActivated || !hasHR) {
        return .wake
    }

    // ── DEEP ──: still + high parasympathetic + low HR + regular respiration.
    if still && parasympHigh && hrLow && rrvRegular {
        return .deep
    }

    // ── REM ──: still body + activated cardiac + irregular respiration.
    if still && cardiacActivated && rrvIrregular {
        return .rem
    }
    // REM fallback when respiration unavailable: require BOTH cardiac signals.
    if still && hrHigh && hrVarHigh && !f.rrv.isFinite {
        return .rem
    }

    return .light
}
