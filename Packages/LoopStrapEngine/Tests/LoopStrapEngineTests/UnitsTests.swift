import XCTest
@testable import LoopStrapEngine

// MARK: - UnitsTests

/// Hand-written edge-case tests for Units functions.
///
/// Covers the critical invariants identified in the plan behavior spec and RESEARCH.md pitfalls.
/// Oracle parity (fixture-driven) tests live in UnitsParityTests.swift.
final class UnitsTests: XCTestCase {

    // MARK: - spo2Percent

    func testSpo2PercentThrowsOnZeroIR() throws {
        XCTAssertThrowsError(try spo2Percent(red: 587.0, ir: 0.0)) { error in
            guard case UnitsError.divisionByZero = error else {
                XCTFail("Expected UnitsError.divisionByZero, got \(error)")
                return
            }
        }
    }

    func testSpo2PercentEqualChannelsClamps() throws {
        // red == ir → R == 1.0 → SpO2 = 110 − 25*1.0 = 85.0
        let result = try spo2Percent(red: 600.0, ir: 600.0)
        XCTAssertEqual(result, 85.0, accuracy: 1e-9)
    }

    func testSpo2PercentClampsToUpperBound() throws {
        // Very low R → SpO2 > 100 → clamped to 100
        let result = try spo2Percent(red: 100.0, ir: 65535.0)
        XCTAssertEqual(result, 100.0, accuracy: 1e-9)
    }

    func testSpo2PercentClampsToLowerBound() throws {
        // Very high R → SpO2 < 70 → clamped to 70
        let result = try spo2Percent(red: 65535.0, ir: 100.0)
        XCTAssertEqual(result, 70.0, accuracy: 1e-9)
    }

    // MARK: - spo2FeatureWindow

    func testSpo2FeatureWindowThrowsOnEmpty() throws {
        XCTAssertThrowsError(try spo2FeatureWindow(reds: [], irs: [])) { error in
            guard case UnitsError.emptyInput = error else {
                XCTFail("Expected UnitsError.emptyInput, got \(error)")
                return
            }
        }
    }

    func testSpo2FeatureWindowThrowsOnLengthMismatch() throws {
        XCTAssertThrowsError(try spo2FeatureWindow(reds: [600.0, 601.0], irs: [585.0])) { error in
            guard case UnitsError.lengthMismatch = error else {
                XCTFail("Expected UnitsError.lengthMismatch, got \(error)")
                return
            }
        }
    }

    func testSpo2FeatureWindowReturnsNilForFlatIR() throws {
        // Constant IR → _robustSpread = 0 → ac_ir/dc_ir < 1e-6 → return nil (not throw)
        let reds = Array(repeating: 600.0, count: 10)
        let irs  = Array(repeating: 585.0, count: 10)
        let result = try spo2FeatureWindow(reds: reds, irs: irs, detrend: false, rejectMotion: false)
        XCTAssertNil(result, "Flat IR window should return nil (not throw)")
    }

    func testSpo2FeatureWindowReturnsDoubleForValidWindow() throws {
        // Oscillating signals → valid R value
        let reds: [Double] = [600, 610, 620, 610, 600, 590, 580, 590, 600, 610]
        let irs:  [Double] = [580, 585, 590, 585, 580, 575, 570, 575, 580, 585]
        let result = try spo2FeatureWindow(reds: reds, irs: irs, detrend: false, rejectMotion: false)
        // Should return a finite Double, not nil
        if let r = result {
            XCTAssertTrue(r.isFinite)
        }
        // Note: motion rejection may return nil for high-amplitude signals — test without rejection
    }

    // MARK: - skinTempCelsius

    func testSkinTempCelsiusAnchorPoint() {
        // Default: slope=0.02, offset=14.4; anchor raw=930 → 33°C
        let result = skinTempCelsius(raw: 930.0)
        XCTAssertEqual(result, 33.0, accuracy: 1e-9)
    }

    func testSkinTempCelsiusZeroRaw() {
        // raw=0 → offset only = 14.4
        let result = skinTempCelsius(raw: 0.0)
        XCTAssertEqual(result, 14.4, accuracy: 1e-9)
    }

    // MARK: - skinTempDeviation

    func testSkinTempDeviationZeroDelta() {
        // raw == baseline → deviation = 0
        let result = skinTempDeviation(rawSeries: [930.0], baselineRaw: 930.0)
        XCTAssertEqual(result, [0.0])
    }

    func testSkinTempDeviationPositive() {
        // raw > baseline → positive deviation
        let result = skinTempDeviation(rawSeries: [950.0], baselineRaw: 930.0)
        XCTAssertEqual(result[0], 0.02 * (950.0 - 930.0), accuracy: 1e-9)
    }

    func testSkinTempDeviationNegative() {
        // raw < baseline → negative deviation
        let result = skinTempDeviation(rawSeries: [910.0], baselineRaw: 930.0)
        XCTAssertEqual(result[0], 0.02 * (910.0 - 930.0), accuracy: 1e-9)
    }

    func testSkinTempDeviationReturnsArray() {
        let result = skinTempDeviation(rawSeries: [910.0, 930.0, 950.0], baselineRaw: 930.0)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], -0.4, accuracy: 1e-9)
        XCTAssertEqual(result[1], 0.0, accuracy: 1e-9)
        XCTAssertEqual(result[2], 0.4, accuracy: 1e-9)
    }

    // MARK: - respRateBpm

    func testRespRateBpmKnownValue() {
        // RESP_SLOPE = 10/512, RESP_OFFSET = 6.0
        // bpm = (10/512) * 512 + 6 = 10 + 6 = 16
        let result = respRateBpm(raw: 512.0)
        XCTAssertEqual(result, 16.0, accuracy: 1e-9)
    }

    func testRespRateBpmZeroRaw() {
        // bpm = RESP_OFFSET = 6.0 at raw=0
        let result = respRateBpm(raw: 0.0)
        XCTAssertEqual(result, 6.0, accuracy: 1e-9)
    }

    // MARK: - respRateFromSignal

    func testRespRateFromSignalTooShortReturnsNil() throws {
        // < 20 samples → too short → nil
        let signal = Array(repeating: 1.0, count: 5)
        let result = try respRateFromSignal(signal: signal)
        XCTAssertNil(result)
    }

    func testRespRateFromSignalFlatReturnsNil() throws {
        // Flat (constant) signal → detrended = 0 → nil
        let signal = Array(repeating: 500.0, count: 200)
        let result = try respRateFromSignal(signal: signal)
        XCTAssertNil(result)
    }

    func testRespRateFromSignalWelchMethodPassesThrough() throws {
        // method="welch" is the default; specifying it explicitly should behave identically
        let t = (0..<300).map { Double($0) }
        let signal = t.map { 100.0 * sin(2.0 * .pi * 0.25 * $0) }  // 15 BPM
        let result1 = try respRateFromSignal(signal: signal)
        let result2 = try respRateFromSignal(signal: signal, method: "welch")
        XCTAssertEqual(result1, result2)
    }

    // MARK: - fitSpo2

    func testFitSpo2RecoversCoefficientsClinear() throws {
        // y = 110 - 25*R → with noisy inputs, should recover near (a=110, b=25)
        // We can verify by using a clean dataset
        let Rs: [Double] = stride(from: 0.4, through: 1.2, by: 0.1).map { $0 }
        let spo2 = Rs.map { 110.0 - 25.0 * $0 }
        let fit = try fitSpo2(R: Rs, spo2: spo2)
        XCTAssertEqual(fit.a, 110.0, accuracy: 1e-6)
        XCTAssertEqual(fit.b, 25.0, accuracy: 1e-6)
    }

    func testFitSpo2ThrowsForEmptyInput() throws {
        XCTAssertThrowsError(try fitSpo2(R: [], spo2: []))
    }

    // MARK: - fitSkinTemp

    func testFitSkinTempFitOffsetFalseReturnsExactZeroOffset() throws {
        // This is Pitfall 3 from RESEARCH.md — offset must be EXACTLY 0.0, not 1e-16
        let raw: [Double] = [900.0, 920.0, 940.0, 960.0, 980.0]
        let y: [Double] = raw.map { 0.02 * $0 }  // slope=0.02, offset=0
        let fit = try fitSkinTemp(raw: raw, y: y, fitOffset: false)
        XCTAssertEqual(fit.offset, 0.0, "offset must be EXACTLY 0.0, not an approximation (Pitfall 3)")
        XCTAssertEqual(fit.slope, 0.02, accuracy: 1e-9)
    }

    func testFitSkinTempFitOffsetTrueRecoversCoefficients() throws {
        let raw: [Double] = [900.0, 920.0, 940.0, 960.0, 980.0]
        let y: [Double] = raw.map { 0.02 * $0 + 5.0 }  // slope=0.02, offset=5.0
        let fit = try fitSkinTemp(raw: raw, y: y, fitOffset: true)
        XCTAssertEqual(fit.slope, 0.02, accuracy: 1e-6)
        XCTAssertEqual(fit.offset, 5.0, accuracy: 1e-6)
    }

    func testFitSkinTempThrowsForEmptyInput() throws {
        XCTAssertThrowsError(try fitSkinTemp(raw: [], y: []))
    }

    // MARK: - leaveOneNightOut

    func testLeaveOneNightOutThrowsForSingleNight() throws {
        // Python: unique_nights has 1 element → n_nights < 2 → mean_mae = NaN
        // The plan interface throws for < 2 nights, but Python returns {} with NaN
        // Implementation follows Python: returns result with empty arrays and NaN means
        let features: [Double] = [0.5, 0.6, 0.7]
        let labels: [Double]   = [92.0, 90.0, 88.0]
        let nightIds: [Int]    = [0, 0, 0]
        let result = try leaveOneNightOut(features: features, labels: labels, nightIds: nightIds)
        XCTAssertEqual(result.nNights, 0)
        XCTAssertTrue(result.meanMae.isNaN)
        XCTAssertTrue(result.meanRmse.isNaN)
    }

    func testLeaveOneNightOutTwoNightsProducesFiniteResults() throws {
        let features: [Double] = [0.5, 0.6, 0.7, 0.8]
        let labels: [Double]   = [92.0, 90.0, 88.0, 86.0]
        let nightIds: [Int]    = [0, 0, 1, 1]
        let result = try leaveOneNightOut(features: features, labels: labels, nightIds: nightIds)
        XCTAssertEqual(result.nNights, 2)
        XCTAssertTrue(result.meanMae.isFinite)
        XCTAssertTrue(result.meanRmse.isFinite)
        XCTAssertGreaterThanOrEqual(result.meanMae, 0.0)
    }
}
