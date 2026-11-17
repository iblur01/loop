import XCTest
@testable import LoopStrapEngine

// MARK: - HRVTests

final class HRVTests: XCTestCase {

    // MARK: - filterRR

    func testFilterRRAllPlausiblePassThrough() {
        XCTAssertEqual(filterRR([400.0, 800.0, 1000.0, 1500.0, 2000.0]), [400.0, 800.0, 1000.0, 1500.0, 2000.0])
    }

    func testFilterRRBoundaryValuesIncluded() {
        XCTAssertEqual(filterRR([rrMinMs, rrMaxMs]), [300.0, 2000.0])
    }

    func testFilterRRBelowMinDropped() {
        XCTAssertEqual(filterRR([100.0, 299.0, 800.0, 900.0]), [800.0, 900.0])
    }

    func testFilterRRAboveMaxDropped() {
        XCTAssertEqual(filterRR([800.0, 900.0, 2001.0, 5000.0]), [800.0, 900.0])
    }

    func testFilterRREmptyInput() {
        XCTAssertEqual(filterRR([]), [])
    }

    func testFilterRRAllImplausible() {
        XCTAssertEqual(filterRR([50.0, 100.0, 3000.0]), [])
    }

    func testFilterRRMixedOutliers() {
        XCTAssertEqual(filterRR([100.0, 300.0, 800.0, 2000.0, 2001.0]), [300.0, 800.0, 2000.0])
    }

    // MARK: - intervalsToPeaks

    func testIntervalsToPeaksEmptyInputReturnsInitialPeak() {
        XCTAssertEqual(intervalsToPeaks([]), [0.0])
    }

    func testIntervalsToPeaksOneIntervalReturnsTwoPeaks() {
        let peaks = intervalsToPeaks([800.0])
        XCTAssertEqual(peaks.count, 2)
        XCTAssertEqual(peaks, [0.0, 800.0])
    }

    func testIntervalsToPeaksStartsAtZeroAndAppendsCumulativeSamples() {
        XCTAssertEqual(intervalsToPeaks([800.0, 820.0], samplingRate: 1000), [0.0, 800.0, 1620.0])
    }

    func testIntervalsToPeaksScalesNonDefaultSamplingRate() {
        XCTAssertEqual(intervalsToPeaks([800.0, 820.0], samplingRate: 500), [0.0, 400.0, 810.0])
    }

    // MARK: - rmssd

    func testRmssdKnownValue() throws {
        let result = try rmssd([800.0, 820.0, 810.0, 830.0])
        XCTAssertEqual(result, 17.320508075688775, accuracy: 1e-12)
    }

    func testRmssdOutlierDroppedEquivalence() throws {
        let clean = [800.0, 820.0, 810.0, 830.0]
        XCTAssertEqual(try rmssd([100.0] + clean + [5000.0]), try rmssd(clean), accuracy: 1e-12)
    }

    func testRmssdThrowsWhenFilteringLeavesFewerThanTwoPlausibleIntervals() {
        XCTAssertThrowsError(try rmssd([800.0, 100.0])) { error in
            XCTAssertEqual(error as? HRVError, .insufficientPlausibleIntervals(function: "rmssd", count: 1))
        }
    }

    // MARK: - sdnn

    func testSdnnKnownSampleStandardDeviationValue() throws {
        let result = try sdnn([800.0, 820.0, 810.0, 830.0])
        XCTAssertEqual(result, 12.909944487358056, accuracy: 1e-12)
    }

    func testSdnnUsesSampleStandardDeviation() throws {
        let result = try sdnn([800.0, 850.0, 900.0, 750.0])
        XCTAssertEqual(result, 64.54972243679029, accuracy: 1e-12)
    }

    func testSdnnOutlierDroppedEquivalence() throws {
        let clean = [800.0, 820.0, 810.0, 830.0]
        XCTAssertEqual(try sdnn([100.0] + clean + [5000.0]), try sdnn(clean), accuracy: 1e-12)
    }

    func testSdnnThrowsWhenFilteringLeavesFewerThanTwoPlausibleIntervals() {
        XCTAssertThrowsError(try sdnn([800.0])) { error in
            XCTAssertEqual(error as? HRVError, .insufficientPlausibleIntervals(function: "sdnn", count: 1))
        }
    }

    // MARK: - pnn50

    func testPnn50ConstantRREqualsZero() {
        XCTAssertEqual(pnn50([800.0, 800.0, 800.0, 800.0]), 0.0, accuracy: 1e-12)
    }

    func testPnn50AlternatingRREqualsOneHundred() {
        XCTAssertEqual(pnn50([800.0, 860.0, 800.0, 860.0]), 100.0, accuracy: 1e-12)
    }

    func testPnn50UsesSuccessiveDiffsDenominator() {
        XCTAssertEqual(pnn50([800.0, 860.0, 860.0, 860.0]), 100.0 / 3.0, accuracy: 1e-12)
    }

    func testPnn50AllImplausibleReturnsNaN() {
        XCTAssertTrue(pnn50([50.0, 100.0, 3000.0]).isNaN)
    }

    func testPnn50FiltersOutliersBeforeComputing() {
        XCTAssertEqual(pnn50([100.0, 800.0, 860.0, 860.0, 860.0, 5000.0]), 100.0 / 3.0, accuracy: 1e-12)
    }
}
