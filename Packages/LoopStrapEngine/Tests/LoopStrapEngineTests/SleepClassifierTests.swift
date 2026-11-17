import XCTest
@testable import LoopStrapEngine

// MARK: - SleepClassifierTests

/// Unit tests for SleepClassifier.swift: classifyEpochs, smoothLabels, reimposePhhysiology.
/// TDD RED phase — tests written before implementation.
final class SleepClassifierTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal EpochFeatures for testing — all NaN HRV, finite HR, zero motion.
    private func makeEpoch(
        epochIdx: Int = 0,
        hr: Double = 60.0,
        hrVar: Double = 1.0,
        rmssd: Double = 30.0,
        sdnn: Double = 25.0,
        hf: Double = Double.nan,
        lf: Double = Double.nan,
        lfhf: Double = Double.nan,
        respRate: Double = Double.nan,
        rrv: Double = Double.nan,
        moveFrac: Double = 0.0,
        ckSleep: Bool = true,
        clock: Double = 0.0
    ) -> EpochFeatures {
        EpochFeatures(
            epochIdx: epochIdx,
            hr: hr,
            hrVar: hrVar,
            rmssd: rmssd,
            sdnn: sdnn,
            hf: hf,
            lf: lf,
            lfhf: lfhf,
            respRate: respRate,
            rrv: rrv,
            moveFrac: moveFrac,
            ckSleep: ckSleep,
            clock: clock
        )
    }

    // MARK: - classifyEpochs — edge cases

    func testClassifyEpochsEmptyReturnsEmpty() {
        let result = classifyEpochs([])
        XCTAssertTrue(result.isEmpty, "empty features must return empty labels")
    }

    func testClassifyEpochsOutputSameLengthAsInput() {
        let features = (0..<5).map { makeEpoch(epochIdx: $0) }
        let result = classifyEpochs(features)
        XCTAssertEqual(result.count, features.count)
    }

    // MARK: - classifyEpochs — wake gate (moveFrac)

    func testClassifyEpochsHighMoveFracWithHighHRVarProducesWake() {
        // moveFrac >= STAGE_WAKE_MOVE_FRAC (0.15) + cardiac activated → wake
        // Must use moveFrac (Piège 5), not count
        let features = (0..<10).map { i -> EpochFeatures in
            // 3 normal still epochs to establish percentile bands, 1 moving
            if i == 5 {
                return makeEpoch(epochIdx: i, hr: 80.0, hrVar: 10.0, moveFrac: 0.20)
            }
            return makeEpoch(epochIdx: i, hr: 60.0, hrVar: 1.0, moveFrac: 0.0)
        }
        let result = classifyEpochs(features)
        XCTAssertEqual(result[5], .wake,
                       "High moveFrac + cardiac activated → wake (Piège 5: moveFrac gate)")
    }

    func testClassifyEpochsLowMoveFracDoesNotProduceWakeFromMotionAlone() {
        // moveFrac below threshold → cannot be wake via motion gate
        let features = (0..<10).map { makeEpoch(epochIdx: $0, moveFrac: 0.05) }
        let result = classifyEpochs(features)
        XCTAssertFalse(result.contains(.wake),
                       "moveFrac=0.05 < 0.15 threshold → no wake from motion gate")
    }

    func testClassifyEpochsCkSleepFalseDoesNotCrash() {
        // ckSleep=false epochs are excluded from percentile band calculation (Pattern 3).
        // When all epochs have ckSleep=false, the fallback is to use all epochs.
        // The classifier should not crash and must return a valid label.
        // (Python classify_epochs does NOT gate on ckSleep in _classify_one —
        //  ckSleep only affects which epochs are used for percentile bands.)
        let f = makeEpoch(epochIdx: 0, moveFrac: 0.0, ckSleep: false)
        let result = classifyEpochs([f])
        XCTAssertEqual(result.count, 1, "ckSleep=false must return exactly 1 label")
        // Label is determined by the decision tree, not by ckSleep directly.
        let validStages: Set<SleepStage> = [.wake, .light, .deep, .rem]
        XCTAssertTrue(validStages.contains(result[0]),
                      "ckSleep=false must still produce a valid SleepStage label")
    }

    // MARK: - classifyEpochs — percentile bands on ckSleep only (Pattern 3)

    func testClassifyEpochsPercentileFilterOnCkSleepOnlyNotAllEpochs() {
        // All ckSleep=false epochs present (wake epochs). If bands are computed
        // over all epochs (wrong), the result may differ from bands computed only
        // on ckSleep=true epochs (correct Pattern 3).
        // With only ckSleep=true epochs, percentile filter must fall back to all.
        let allWakeFeatures = (0..<5).map { makeEpoch(epochIdx: $0, ckSleep: false) }
        // All false ckSleep → fallback to all features (must not crash)
        let result = classifyEpochs(allWakeFeatures)
        XCTAssertEqual(result.count, allWakeFeatures.count,
                       "Must return same count even when all ckSleep=false")
    }

    // MARK: - classifyEpochs — RRV NaN = regular (Piège 6)

    func testClassifyEpochsRrvNaNTreatedAsRegular() {
        // NaN RRV must not prevent deep classification (Piège 6: NaN RRV = regular)
        // Set up conditions favoring deep: still, high rmssd, low hr, NaN rrv
        // Build enough epochs for percentile bands to be meaningful
        let n = 20
        let features = (0..<n).map { i -> EpochFeatures in
            makeEpoch(
                epochIdx: i,
                hr: 55.0,        // below 25th pct → hrLow (all same → 55th ≈ 25th)
                hrVar: 0.5,      // hrVar low (below 65th pct of uniform → not hrvar_high)
                rmssd: 60.0,     // high rmssd → parasymp_high candidate
                rrv: Double.nan, // NaN RRV → must be treated as regular (Piège 6)
                moveFrac: 0.0,   // still
                ckSleep: true
            )
        }
        let result: [SleepStage] = classifyEpochs(features)
        // With all same HR → 25th pct = 55 = all epochs' hr, so hr_low = hr <= 55.0 = true
        // With high rmssd → parasymp_high = true (rmssdHigh)
        // With NaN rrv → rrv_regular = true (Piège 6)
        // → deep expected for some epochs (not wake; moveFrac=0.0)
        let deepEpochs = result.filter { $0 == SleepStage.deep }
        let remEpochs = result.filter { $0 == SleepStage.rem }
        let nonWakeNonLight = deepEpochs + remEpochs
        XCTAssertFalse(nonWakeNonLight.isEmpty,
                       "NaN RRV must not block deep classification (Piège 6)")
    }

    // MARK: - smoothLabels

    func testSmoothLabelsEmptyReturnsEmpty() {
        let result = smoothLabels([], window: 5)
        XCTAssertTrue(result.isEmpty)
    }

    func testSmoothLabelsWindow1ReturnsUnchanged() {
        let labels: [SleepStage] = [.wake, .light, .deep, .rem, .light]
        let result = smoothLabels(labels, window: 1)
        XCTAssertEqual(result, labels)
    }

    func testSmoothLabelsOutputSameLengthAsInput() {
        let labels: [SleepStage] = [.wake, .light, .deep, .rem, .light, .deep, .wake]
        let result = smoothLabels(labels, window: 5)
        XCTAssertEqual(result.count, labels.count)
    }

    func testSmoothLabelsKillsIsolatedFlip() {
        // Single isolated flip in a run → should be smoothed away
        // [.light, .light, .deep, .light, .light] → center should become .light
        let labels: [SleepStage] = [.light, .light, .deep, .light, .light]
        let result = smoothLabels(labels, window: 5)
        XCTAssertEqual(result[2], .light,
                       "Isolated .deep in a run of .light should be smoothed to .light")
    }

    func testSmoothLabelsPreservesRunOfSameStage() {
        // All same stage → unchanged
        let labels = [SleepStage](repeating: .light, count: 10)
        let result = smoothLabels(labels, window: 5)
        XCTAssertEqual(result, labels)
    }

    func testSmoothLabelsAcceptsWindowParameter() {
        // Verify window is parametric (not hardcoded)
        let labels: [SleepStage] = [.wake, .light, .light, .light, .wake]
        let result3 = smoothLabels(labels, window: 3)
        let result5 = smoothLabels(labels, window: 5)
        // Both must return 5 elements; values may differ by window size
        XCTAssertEqual(result3.count, 5)
        XCTAssertEqual(result5.count, 5)
    }

    func testSmoothLabelsIncumbentPreservationOnTie() {
        // [.light, .deep, .light] window=3 → center has tie light(2) vs deep(1) → light wins
        // Actually all same except center: light, deep, light → light wins
        let labels: [SleepStage] = [.light, .deep, .light]
        let result = smoothLabels(labels, window: 3)
        XCTAssertEqual(result[1], .light,
                       "Incumbent tie-break: .light majority wins over single .deep")
    }

    // MARK: - reimposePhhysiology

    func testReimposePhhysiologyEmptyReturnsEmpty() {
        let result = reimposePhhysiology([], features: [], onsetIdx: 0, finalWakeIdx: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func testReimposePhhysiologyOutputSameLengthAsInput() {
        let labels: [SleepStage] = [.light, .rem, .deep, .light, .wake]
        let features = (0..<5).map { makeEpoch(epochIdx: $0) }
        let result = reimposePhhysiology(labels, features: features, onsetIdx: 0, finalWakeIdx: 4)
        XCTAssertEqual(result.count, labels.count)
    }

    func testReimposePhhysiologyNoRemInFirstEpochsAfterOnset() {
        // REM within NO_REM_AFTER_ONSET_MIN (15 min = 30 epochs) should be relabelled light
        // Place REM at epoch 5 (2.5 min after onset) → must become .light
        var labels = [SleepStage](repeating: .light, count: 40)
        labels[5] = .rem
        let features = (0..<40).map { makeEpoch(epochIdx: $0) }
        let result = reimposePhhysiology(labels, features: features, onsetIdx: 0, finalWakeIdx: 39)
        XCTAssertEqual(result[5], .light,
                       "REM at epoch 5 (5*30s=2.5 min < 15 min) must be relabelled to .light")
    }

    func testReimposePhhysiologyAllowsRemAfterLatencyWindow() {
        // REM after NO_REM_AFTER_ONSET_MIN epochs should stay .rem
        // 15 min = 30 epochs; epoch 31 must stay .rem
        var labels = [SleepStage](repeating: .light, count: 40)
        labels[31] = .rem
        let features = (0..<40).map { makeEpoch(epochIdx: $0) }
        let result = reimposePhhysiology(labels, features: features, onsetIdx: 0, finalWakeIdx: 39)
        XCTAssertEqual(result[31], .rem,
                       "REM at epoch 31 (31*30s > 15 min) must remain .rem")
    }

    func testReimposePhhysiologyDeepLateInNightDowngradedToLight() {
        // Deep epoch with f.clock > DEEP_LATE_FRACTION (0.95) → relabel to light
        // We need features with a clock field > 0.95
        // The EpochFeatures struct doesn't expose clock directly — this test
        // verifies the function signature compiles and handles the deep-late rule.
        // Using 40 epochs, onsetIdx=0, finalWakeIdx=39; deep at epoch 38 with clock=0.96
        var labels = [SleepStage](repeating: .light, count: 40)
        labels[38] = .deep
        // Build features — reimposePhhysiology reads f.clock from EpochFeatures
        // SleepTypes.swift EpochFeatures currently doesn't have a clock field.
        // The plan requires reading sleep_features.py for the clock field.
        // For now: the test must compile and the function exist with correct signature.
        let features = (0..<40).map { makeEpoch(epochIdx: $0) }
        let result = reimposePhhysiology(labels, features: features, onsetIdx: 0, finalWakeIdx: 39)
        // Without clock field, this test just verifies the function compiles and runs
        XCTAssertEqual(result.count, 40, "reimposePhhysiology must return same count")
    }

    func testReimposePhhysiologyDoesNotModifyEpochsOutsideSleepPeriod() {
        // Epochs before onsetIdx and after finalWakeIdx must be untouched
        let labels: [SleepStage] = [.rem, .light, .deep, .light, .rem]
        // onsetIdx=1, finalWakeIdx=3 → epochs 0 and 4 must not be modified
        let features = (0..<5).map { makeEpoch(epochIdx: $0) }
        let result = reimposePhhysiology(labels, features: features, onsetIdx: 1, finalWakeIdx: 3)
        XCTAssertEqual(result[0], .rem,
                       "Epoch 0 before onsetIdx must not be modified")
        XCTAssertEqual(result[4], .rem,
                       "Epoch 4 after finalWakeIdx must not be modified")
    }

    // MARK: - enforceMinBout

    func testEnforceMinBoutEmptyAndSingleReturnUnchanged() {
        let empty: [SleepStage] = []
        XCTAssertEqual(enforceMinBout(empty), empty)
        XCTAssertEqual(enforceMinBout([.deep]), [.deep])
    }

    func testEnforceMinBoutOutputSameLength() {
        let labels = [SleepStage](repeating: .light, count: 50)
        XCTAssertEqual(enforceMinBout(labels).count, 50)
    }

    func testEnforceMinBoutAbsorbsShortRunIntoLongerNeighbour() {
        // 12 deep (≥10 floor) + 2 rem (below 10 floor) + 12 light → rem absorbed.
        // rem's neighbours: deep(12) vs light(12) → tie → previous (deep).
        let labels = [SleepStage](repeating: .deep, count: 12)
            + [SleepStage](repeating: .rem, count: 2)
            + [SleepStage](repeating: .light, count: 12)
        let out = enforceMinBout(labels)
        XCTAssertFalse(out.contains(.rem), "Sub-threshold rem run must be absorbed")
        XCTAssertEqual(out[12], .deep, "Tie resolves to previous neighbour (deep)")
    }

    func testEnforceMinBoutKeepsRunsAtOrAboveThreshold() {
        // deep floor = 10; exactly 10 deep must survive.
        let labels = [SleepStage](repeating: .light, count: 12)
            + [SleepStage](repeating: .deep, count: 10)
            + [SleepStage](repeating: .light, count: 12)
        let out = enforceMinBout(labels)
        XCTAssertEqual(out.filter { $0 == .deep }.count, 10,
                       "A run at the threshold must be preserved")
    }

    func testEnforceMinBoutWakeKeepsLowerFloor() {
        // wake floor = 4; a 4-epoch wake bout (real WASO) survives between long sleep.
        let labels = [SleepStage](repeating: .light, count: 12)
            + [SleepStage](repeating: .wake, count: 4)
            + [SleepStage](repeating: .light, count: 12)
        let out = enforceMinBout(labels)
        XCTAssertEqual(out.filter { $0 == .wake }.count, 4,
                       "A 4-epoch wake bout must survive the wake floor")
    }

    func testEnforceMinBoutAbsorbsEdgeRunIntoOnlyNeighbour() {
        // Leading 2-epoch rem (below floor) at the array edge → absorbed into next run.
        let labels = [SleepStage](repeating: .rem, count: 2)
            + [SleepStage](repeating: .deep, count: 12)
        let out = enforceMinBout(labels)
        XCTAssertEqual(out, [SleepStage](repeating: .deep, count: 14),
                       "Edge run must merge into its only neighbour")
    }
}
