import XCTest
@testable import LoopStrapEngine

final class NumericKitTests: XCTestCase {

    // MARK: - mean

    func testMeanThrowsOnEmpty() {
        XCTAssertThrowsError(try mean([]))
    }

    func testMeanSingleElement() throws {
        XCTAssertEqual(try mean([5.0]), 5.0)
    }

    func testMeanMultiple() throws {
        XCTAssertEqual(try mean([1.0, 2.0, 3.0]), 2.0, accuracy: 1e-12)
    }

    // MARK: - std

    func testStdThrowsOnEmpty() {
        XCTAssertThrowsError(try std([]))
    }

    func testStdSingleElement() throws {
        XCTAssertEqual(try std([5.0]), 0.0)
    }

    func testStdKnown() throws {
        // numpy: np.std([2,4,4,4,5,5,7,9], ddof=1) ≈ 2.138089935299395
        // Note: ddof=1 (sample std) divides by n-1=7, not n=8.
        // The population std (ddof=0) would be 2.0; the plan spec uses ddof=1.
        let result = try std([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])
        XCTAssertEqual(result, 2.138089935299395, accuracy: 1e-12)
    }

    // MARK: - median

    func testMedianThrowsOnEmpty() {
        XCTAssertThrowsError(try median([]))
    }

    func testMedianOdd() throws {
        XCTAssertEqual(try median([1.0, 3.0, 2.0]), 2.0)
    }

    func testMedianEven() throws {
        XCTAssertEqual(try median([1.0, 2.0, 3.0, 4.0]), 2.5)
    }

    // MARK: - percentile

    func testPercentileThrowsOnEmpty() {
        XCTAssertThrowsError(try percentile([], 50.0))
    }

    func testPercentileLinearInterp() throws {
        // numpy: np.percentile([1,2,3,4], 75) == 3.25 (linear interpolation, A1 method)
        XCTAssertEqual(try percentile([1.0, 2.0, 3.0, 4.0], 75.0), 3.25, accuracy: 1e-12)
    }

    func testPercentileSingleElement() throws {
        XCTAssertEqual(try percentile([5.0], 50.0), 5.0)
    }

    func testPercentileQ0() throws {
        XCTAssertEqual(try percentile([1.0, 2.0, 3.0, 4.0], 0.0), 1.0)
    }

    func testPercentileQ100() throws {
        XCTAssertEqual(try percentile([1.0, 2.0, 3.0, 4.0], 100.0), 4.0)
    }

    func testPercentileIQRPath() throws {
        // Constant array: IQR fallback yields 0 spread, percentile returns element value.
        XCTAssertEqual(try percentile([5.0, 5.0, 5.0, 5.0], 25.0), 5.0)
        XCTAssertEqual(try percentile([5.0, 5.0, 5.0, 5.0], 75.0), 5.0)
    }

    // MARK: - polyfit / polyval

    func testPolyfitThrowsOnEmpty() {
        XCTAssertThrowsError(try polyfit([], [], deg: 1))
    }

    func testPolyfitUnderdetermined() {
        // n=1 < deg+1=2 → underdetermined
        XCTAssertThrowsError(try polyfit([0.0], [1.0], deg: 1))
    }

    func testPolyfitDeg1() throws {
        // y = 2x + 1 → coefficients [2.0, 1.0]
        let coeffs = try polyfit([0.0, 1.0, 2.0], [1.0, 3.0, 5.0], deg: 1)
        XCTAssertEqual(coeffs.count, 2)
        XCTAssertEqual(coeffs[0], 2.0, accuracy: 1e-10)
        XCTAssertEqual(coeffs[1], 1.0, accuracy: 1e-10)
    }

    func testPolyvalDeg2() {
        // 2x^2 - 3x + 1 at x=1 → 2 - 3 + 1 = 0
        XCTAssertEqual(polyval([2.0, -3.0, 1.0], 1.0), 0.0, accuracy: 1e-12)
    }

    func testPolyvalEmpty() {
        XCTAssertEqual(polyval([], 5.0), 0.0)
    }

    func testPolyfit1RoundTrip() throws {
        let x = [0.0, 1.0, 2.0]
        let y = [1.0, 3.0, 5.0]
        let coeffs = try polyfit(x, y, deg: 1)
        XCTAssertEqual(polyval(coeffs, x[1]), y[1], accuracy: 1e-10)
    }

    // MARK: - leastSquares

    func testLeastSquaresThrowsOnEmpty() {
        XCTAssertThrowsError(try leastSquares(X: [], y: []))
    }

    func testLeastSquaresSimpleOLS() throws {
        // Design matrix for intercept + slope: X[i] = [1, x[i]]
        // x=[0,1,2], y=[1,3,5] → intercept=1, slope=2
        let X: [[Double]] = [[1.0, 0.0], [1.0, 1.0], [1.0, 2.0]]
        let y: [Double] = [1.0, 3.0, 5.0]
        let coeffs = try leastSquares(X: X, y: y)
        XCTAssertEqual(coeffs.count, 2)
        XCTAssertEqual(coeffs[0], 1.0, accuracy: 1e-10)
        XCTAssertEqual(coeffs[1], 2.0, accuracy: 1e-10)
    }

    // MARK: - diff

    func testDiffEmpty() {
        XCTAssertEqual(diff([]), [])
    }

    func testDiffSingle() {
        XCTAssertEqual(diff([5.0]), [])
    }

    func testDiffKnown() {
        XCTAssertEqual(diff([1.0, 4.0, 9.0]), [3.0, 5.0])
    }

    // MARK: - interp

    func testInterpEmpty() {
        XCTAssertEqual(interp([], [0.0, 1.0], [0.0, 1.0]), [])
    }

    func testInterpMidpoint() {
        XCTAssertEqual(interp([0.5], [0.0, 1.0], [0.0, 10.0]), [5.0])
    }

    func testInterpLeftClamp() {
        XCTAssertEqual(interp([-1.0], [0.0, 1.0], [0.0, 10.0]), [0.0])
    }

    func testInterpRightClamp() {
        XCTAssertEqual(interp([2.0], [0.0, 1.0], [0.0, 10.0]), [10.0])
    }

    // MARK: - convolve

    func testConvolveFull() {
        // numpy: np.convolve([1,2,3], [0,1,0.5]) = [0, 1, 2.5, 4, 1.5]
        let result = convolve([1.0, 2.0, 3.0], [0.0, 1.0, 0.5], mode: "full")
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result[0], 0.0, accuracy: 1e-12)
        XCTAssertEqual(result[1], 1.0, accuracy: 1e-12)
        XCTAssertEqual(result[2], 2.5, accuracy: 1e-12)
        XCTAssertEqual(result[3], 4.0, accuracy: 1e-12)
        XCTAssertEqual(result[4], 1.5, accuracy: 1e-12)
    }

    func testConvolveValid() {
        // numpy: np.convolve([1,2,3,4], [1,1], mode='valid') = [3, 5, 7]
        let result = convolve([1.0, 2.0, 3.0, 4.0], [1.0, 1.0], mode: "valid")
        XCTAssertEqual(result, [3.0, 5.0, 7.0])
    }

    func testConvolveEmptyInput() {
        XCTAssertEqual(convolve([], [1.0], mode: "full"), [])
    }

    // MARK: - findPeaks

    func testFindPeaksEmpty() {
        XCTAssertEqual(findPeaks([]).indices, [])
    }

    func testFindPeaksSingleton() {
        XCTAssertEqual(findPeaks([5.0]).indices, [])
    }

    func testFindPeaksBasic() {
        // Peaks at indices 1 (value 3) and 3 (value 5)
        XCTAssertEqual(findPeaks([1.0, 3.0, 2.0, 5.0, 1.0]).indices, [1, 3])
    }

    func testFindPeaksHeight() {
        // Only peak at index 3 (value 5) meets height >= 4.0
        XCTAssertEqual(findPeaks([1.0, 3.0, 2.0, 5.0, 1.0], height: 4.0).indices, [3])
    }

    func testFindPeaksDistance() {
        // Peaks at index 1 (value 5) and index 3 (value 6); distance=3 means abs(3-1)=2 < 3.
        // Greedy highest-first: index 3 (value 6) wins over index 1 (value 5).
        XCTAssertEqual(findPeaks([1.0, 5.0, 1.0, 6.0, 1.0], distance: 3).indices, [3])
    }
}
