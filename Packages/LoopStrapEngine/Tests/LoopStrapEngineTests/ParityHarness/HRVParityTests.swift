import XCTest
@testable import LoopStrapEngine
import Foundation

// MARK: - HRV parity tests

/// Oracle parity tests for the Phase 2 HRV time-domain functions using fixture JSON
/// files from Resources/fixtures/hrv/.
final class HRVParityTests: XCTestCase {

    // MARK: filterRR parity

    func testFilterRRParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("filter_rr", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.module, "hrv")
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let rrMs = testCase.inputs["rr_ms"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing rr_ms input")
                continue
            }
            guard let expected = testCase.output?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing or malformed output array")
                continue
            }
            let actual = filterRR(rrMs)
            XCTAssertEqual(actual.count, expected.count, "\(testCase.name): array length mismatch")
            for (a, e) in zip(actual, expected) {
                assertParity(actual: a, expected: e, tolerance: tolerance)
            }
        }
    }

    // MARK: intervalsToPeaks parity

    func testIntervalsToPeaksParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("intervals_to_peaks", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.module, "hrv")
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let intervalsMs = testCase.inputs["intervals_ms"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing intervals_ms input")
                continue
            }
            let samplingRate: Int
            if let kw = testCase.kwargs, case .double(let sr) = kw["sampling_rate"] {
                samplingRate = Int(sr)
            } else {
                samplingRate = 1000
            }
            guard let expected = testCase.output?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing or malformed output array")
                continue
            }
            let actual = intervalsToPeaks(intervalsMs, samplingRate: samplingRate)
            XCTAssertEqual(actual.count, expected.count, "\(testCase.name): array length mismatch")
            for (a, e) in zip(actual, expected) {
                assertParity(actual: a, expected: e, tolerance: tolerance)
            }
        }
    }

    // MARK: rmssd parity

    func testRMSSDParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("rmssd", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.module, "hrv")
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let rrMs = testCase.inputs["rr_ms"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing rr_ms input")
                continue
            }
            if testCase.raises != nil {
                XCTAssertThrowsError(try rmssd(rrMs), "\(testCase.name): expected throw")
            } else if testCase.name == "rmssd_ms_empty_diffs_is_zero" {
                // This fixture case exercises rmssd_ms([800]) directly (a single-element
                // input with no successive differences), not the filtering rmssd(_:) wrapper,
                // which requires >= 2 plausible intervals.
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                let actual = rmssdMs(rrMs)
                assertParity(actual: actual, expected: expected, tolerance: tolerance)
            } else {
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                do {
                    let actual = try rmssd(rrMs)
                    assertParity(actual: actual, expected: expected, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: sdnn parity

    func testSDNNParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("sdnn", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.module, "hrv")
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let rrMs = testCase.inputs["rr_ms"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing rr_ms input")
                continue
            }
            if testCase.raises != nil {
                XCTAssertThrowsError(try sdnn(rrMs), "\(testCase.name): expected throw")
            } else {
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                do {
                    let actual = try sdnn(rrMs)
                    assertParity(actual: actual, expected: expected, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: pnn50 parity

    func testPNN50Parity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("pnn50", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.module, "hrv")
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let rrMs = testCase.inputs["rr_ms"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing rr_ms input")
                continue
            }
            let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                         "\(testCase.name): missing output value")
            let actual = pnn50(rrMs)
            assertParity(actual: actual, expected: expected, tolerance: tolerance)
        }
    }
}

// MARK: - Fixpeaks parity tests

/// Oracle parity tests for Phase 4 cleanRR (kubios signal_fixpeaks port)
/// using fixture JSON from Resources/fixtures/fixpeaks/clean_rr.json.
final class FixpeaksParityTests: XCTestCase {

    // MARK: cleanRR parity

    func testCleanRRParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("clean_rr", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.module, "hrv")
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let rrMs = testCase.inputs["rr_ms"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing rr_ms input")
                continue
            }

            // Cas raises : cleanRR doit lancer une erreur
            if testCase.raises != nil {
                XCTAssertThrowsError(try cleanRR(rrMs), "\(testCase.name): expected throw")
                continue
            }

            // Cas normal : appel et décodage de l'output objet
            let result: CleanRRResult
            do {
                result = try cleanRR(rrMs)
            } catch {
                XCTFail("\(testCase.name): unexpected throw \(error)")
                continue
            }

            guard case .object(let outputObj) = testCase.output,
                  let nnCleanFV = outputObj["nn_clean"],
                  let expectedNnClean = nnCleanFV.arrayOfDoubles,
                  let peaksCleanFV = outputObj["peaks_clean"],
                  let expectedPeaksClean = peaksCleanFV.arrayOfDoubles,
                  case .double(let nBeatsFV) = outputObj["n_beats"],
                  case .double(let nArtifactsFV) = outputObj["n_artifacts"]
            else {
                XCTFail("\(testCase.name): malformed output object")
                continue
            }
            let expectedNBeats = Int(nBeatsFV)
            let expectedNArtifacts = Int(nArtifactsFV)

            // Assertions structurelles (exact, pas de tolérance)
            XCTAssertEqual(result.nBeats, expectedNBeats, "\(testCase.name): nBeats mismatch")
            XCTAssertEqual(result.nArtifacts, expectedNArtifacts, "\(testCase.name): nArtifacts mismatch")
            XCTAssertEqual(result.peaksClean.count, result.nnClean.count + 1, "\(testCase.name): invariant peaksClean.count == nnClean.count + 1 violated")
            XCTAssertEqual(result.nnClean.count, expectedNnClean.count, "\(testCase.name): nnClean length mismatch")
            XCTAssertEqual(result.peaksClean.count, expectedPeaksClean.count, "\(testCase.name): peaksClean length mismatch")

            // Assertions valeur sur nnClean (atol = 0.5 ms, D-07)
            for (a, e) in zip(result.nnClean, expectedNnClean) {
                assertParity(actual: a, expected: e, tolerance: tolerance)
            }

            // Assertions valeur sur peaksClean (tolérance absolue 1.0 sample à 1000 Hz).
            // Les indices de pics sont des entiers en pratique; une déviation > 1 sample
            // indiquerait une erreur de correction de pics.
            let peaksTolerance = ToleranceSpec(mode: .absolute, epsilon: 1.0)
            for (a, e) in zip(result.peaksClean, expectedPeaksClean) {
                assertParity(actual: a, expected: e, tolerance: peaksTolerance)
            }
        }
    }
}
