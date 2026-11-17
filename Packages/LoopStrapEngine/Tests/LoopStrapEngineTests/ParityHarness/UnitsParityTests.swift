import XCTest
@testable import LoopStrapEngine
import Foundation

// MARK: - Parity harness self-test

/// Validates the ParityHarness infrastructure and runs oracle parity tests for all 10
/// units.py public functions using fixture JSON files from Resources/fixtures/units/.
///
/// Harness self-tests (testHarness*) validate the fixture loading infrastructure.
/// Oracle parity tests (test*Parity) compare Swift function output against Python oracle values.
final class UnitsParityTests: XCTestCase {

    // MARK: - Harness self-test

    func testHarnessLoadsMetaFixture() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "meta_test", withExtension: "json"),
            "missing meta_test.json — expected at Tests/Resources/fixtures/units/meta_test.json"
        )
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.function, "meta_test")
        XCTAssertEqual(fixture.cases.count, 4)
    }

    func testHarnessNormalFloatCase() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "meta_test", withExtension: "json"),
            "missing meta_test.json"
        )
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        let normalCase = try XCTUnwrap(fixture.cases.first(where: { $0.name == "normal_float" }))
        let expected = try XCTUnwrap(normalCase.output?.doubleValue)
        assertParity(actual: 1.5, expected: expected, tolerance: ToleranceSpec(mode: .absolute, epsilon: 1e-12))
    }

    func testHarnessNaNSentinel() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "meta_test", withExtension: "json"),
            "missing meta_test.json"
        )
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        let nanCase = try XCTUnwrap(fixture.cases.first(where: { $0.name == "nan_output" }))
        let expected = try XCTUnwrap(nanCase.output?.doubleValue)
        // JSONDouble must have decoded the "NaN" string to Double.nan.
        XCTAssertTrue(expected.isNaN, "Expected Double.nan decoded from \"NaN\" sentinel but got \(expected)")
        assertParity(actual: Double.nan, expected: expected, tolerance: ToleranceSpec(mode: .absolute, epsilon: 1e-9))
    }

    func testHarnessNoneOutput() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "meta_test", withExtension: "json"),
            "missing meta_test.json"
        )
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        let noneCase = try XCTUnwrap(fixture.cases.first(where: { $0.name == "none_output" }))
        XCTAssertEqual(noneCase.outputIsNone, true)
        XCTAssertNil(noneCase.output)
    }

    func testHarnessToleranceConfigLoads() throws {
        let config = try ToleranceConfig.load()
        // fit_spo2 must use relative mode at 1e-6.
        let fitSpo2 = config.spec(for: "fit_spo2")
        XCTAssertEqual(fitSpo2.mode, .relative)
        XCTAssertEqual(fitSpo2.epsilon, 1e-6, accuracy: 1e-15)
        // Unknown function falls back to default.
        let unknown = config.spec(for: "unknown_function")
        XCTAssertEqual(unknown.mode, config.default.mode)
    }

    // MARK: - Oracle parity tests

    // MARK: spo2Percent parity

    func testSpo2PercentParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("spo2_percent", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let red = testCase.inputs["red"]?.doubleValue,
                  let ir  = testCase.inputs["ir"]?.doubleValue else {
                XCTFail("\(testCase.name): missing red/ir inputs")
                continue
            }
            if testCase.raises != nil {
                XCTAssertThrowsError(
                    try spo2Percent(red: red, ir: ir),
                    "\(testCase.name): expected throw but got no error"
                )
            } else {
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                do {
                    let actual = try spo2Percent(red: red, ir: ir)
                    assertParity(actual: actual, expected: expected, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: spo2FeatureWindow parity

    func testSpo2FeatureWindowParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("spo2_feature_window", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let reds = testCase.inputs["reds"]?.arrayOfDoubles,
                  let irs  = testCase.inputs["irs"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing reds/irs inputs")
                continue
            }

            // Parse optional kwargs (detrend, reject_motion); defaults match Python defaults
            let detrend: Bool
            let rejectMotion: Bool
            if let kw = testCase.kwargs {
                if case .bool(let v) = kw["detrend"] { detrend = v } else { detrend = true }
                if case .bool(let v) = kw["reject_motion"] { rejectMotion = v } else { rejectMotion = true }
            } else {
                detrend = true
                rejectMotion = true
            }

            if testCase.raises != nil {
                XCTAssertThrowsError(
                    try spo2FeatureWindow(reds: reds, irs: irs, detrend: detrend, rejectMotion: rejectMotion),
                    "\(testCase.name): expected throw"
                )
            } else if testCase.outputIsNone == true {
                do {
                    let result = try spo2FeatureWindow(reds: reds, irs: irs, detrend: detrend, rejectMotion: rejectMotion)
                    XCTAssertNil(result, "\(testCase.name): expected nil (Python returned None) but got \(result as Any)")
                } catch {
                    XCTFail("\(testCase.name): unexpected throw for None-output case: \(error)")
                }
            } else {
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                do {
                    let result = try spo2FeatureWindow(reds: reds, irs: irs, detrend: detrend, rejectMotion: rejectMotion)
                    let actual = try XCTUnwrap(result, "\(testCase.name): expected Double but got nil")
                    assertParity(actual: actual, expected: expected, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: spo2PercentWindow parity

    func testSpo2PercentWindowParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("spo2_percent_window", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let reds = testCase.inputs["reds"]?.arrayOfDoubles,
                  let irs  = testCase.inputs["irs"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing reds/irs inputs")
                continue
            }
            if testCase.raises != nil {
                XCTAssertThrowsError(
                    try spo2PercentWindow(reds: reds, irs: irs),
                    "\(testCase.name): expected throw"
                )
            } else {
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                do {
                    let actual = try spo2PercentWindow(reds: reds, irs: irs)
                    assertParity(actual: actual, expected: expected, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: skinTempCelsius parity

    func testSkinTempCelsiusParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("skin_temp_celsius", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let raw = testCase.inputs["raw"]?.doubleValue else {
                XCTFail("\(testCase.name): missing raw input")
                continue
            }
            // Parse optional slope/offset kwargs
            let slope:  Double = testCase.kwargs?["slope"]?.doubleValue  ?? _skinTempSlopeDefault
            let offset: Double = testCase.kwargs?["offset"]?.doubleValue ?? _skinTempOffsetDefault
            let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                         "\(testCase.name): missing output value")
            let actual = skinTempCelsius(raw: raw, slope: slope, offset: offset)
            assertParity(actual: actual, expected: expected, tolerance: tolerance)
        }
    }

    // MARK: skinTempDeviation parity

    func testSkinTempDeviationParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("skin_temp_deviation", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let rawSeries  = testCase.inputs["raw_series"]?.arrayOfDoubles,
                  let baselineRaw = testCase.inputs["baseline_raw"]?.doubleValue else {
                XCTFail("\(testCase.name): missing raw_series or baseline_raw")
                continue
            }
            let slope: Double = testCase.kwargs?["slope"]?.doubleValue ?? _skinTempSlopeDefault

            guard let outputVal = testCase.output, case .array(let elements) = outputVal else {
                XCTFail("\(testCase.name): expected array output")
                continue
            }
            let expected = elements.compactMap { $0.doubleValue }
            let actual   = skinTempDeviation(rawSeries: rawSeries, baselineRaw: baselineRaw, slope: slope)

            XCTAssertEqual(actual.count, expected.count, "\(testCase.name): array length mismatch")
            for (_, (a, e)) in zip(actual, expected).enumerated() {
                assertParity(actual: a, expected: e, tolerance: tolerance,
                             file: #filePath, line: #line)
            }
        }
    }

    // MARK: respRateBpm parity

    func testRespRateBpmParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("resp_rate_bpm", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let raw = testCase.inputs["raw"]?.doubleValue else {
                XCTFail("\(testCase.name): missing raw input")
                continue
            }
            let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                         "\(testCase.name): missing output value")
            let actual = respRateBpm(raw: raw)
            assertParity(actual: actual, expected: expected, tolerance: tolerance)
        }
    }

    // MARK: respRateFromSignal parity

    func testRespRateFromSignalParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("resp_rate_from_signal", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let signal = testCase.inputs["signal"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing signal input")
                continue
            }

            // Parse optional kwargs
            let fs: Double
            let nperseg: Int
            let method: String
            if let kw = testCase.kwargs {
                fs      = kw["fs"]?.doubleValue ?? 1.0
                nperseg = kw["nperseg"].flatMap { v -> Int? in
                    if case .double(let d) = v { return Int(d) } else { return nil }
                } ?? _respNpersegDefault
                if case .string(let m) = kw["method"] { method = m } else { method = "welch" }
            } else {
                fs = 1.0; nperseg = _respNpersegDefault; method = "welch"
            }

            if testCase.outputIsNone == true {
                do {
                    let result = try respRateFromSignal(signal: signal, fs: fs, nperseg: nperseg, method: method)
                    XCTAssertNil(result, "\(testCase.name): expected nil (Python returned None) but got \(result as Any)")
                } catch {
                    XCTFail("\(testCase.name): unexpected throw for None-output case: \(error)")
                }
            } else {
                let expected = try XCTUnwrap(testCase.output?.doubleValue,
                                             "\(testCase.name): missing output value")
                do {
                    let result = try respRateFromSignal(signal: signal, fs: fs, nperseg: nperseg, method: method)
                    let actual = try XCTUnwrap(result, "\(testCase.name): expected Double but got nil")
                    assertParity(actual: actual, expected: expected, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: fitSpo2 parity

    func testFitSpo2Parity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("fit_spo2", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let R    = testCase.inputs["R_values"]?.arrayOfDoubles,
                  let spo2 = testCase.inputs["whoop_spo2"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing R_values or whoop_spo2")
                continue
            }
            // Parse quadratic kwarg
            let quadratic: Bool
            if let kw = testCase.kwargs, case .bool(let q) = kw["quadratic"] { quadratic = q }
            else { quadratic = false }

            if testCase.raises != nil {
                XCTAssertThrowsError(
                    try fitSpo2(R: R, spo2: spo2, quadratic: quadratic),
                    "\(testCase.name): expected throw"
                )
            } else {
                // Output encoded as {"a": intercept, "b": slope}
                guard let outputObj = testCase.output,
                      case .object(let obj) = outputObj,
                      let expectedA = obj["a"]?.doubleValue,
                      let expectedB = obj["b"]?.doubleValue else {
                    XCTFail("\(testCase.name): missing or malformed output {a, b}")
                    continue
                }
                do {
                    let fit = try fitSpo2(R: R, spo2: spo2, quadratic: quadratic)
                    assertParity(actual: fit.a, expected: expectedA, tolerance: tolerance)
                    assertParity(actual: fit.b, expected: expectedB, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: fitSkinTemp parity

    func testFitSkinTempParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("fit_skin_temp", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let raw = testCase.inputs["raw_values"]?.arrayOfDoubles,
                  let y   = testCase.inputs["whoop_celsius"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing raw_values or whoop_celsius")
                continue
            }
            // Parse fit_offset kwarg (default true)
            let fitOffset: Bool
            if let kw = testCase.kwargs, case .bool(let fo) = kw["fit_offset"] { fitOffset = fo }
            else { fitOffset = true }

            if testCase.raises != nil {
                XCTAssertThrowsError(
                    try fitSkinTemp(raw: raw, y: y, fitOffset: fitOffset),
                    "\(testCase.name): expected throw"
                )
            } else {
                // Output encoded as {"a": slope, "b": offset}
                guard let outputObj = testCase.output,
                      case .object(let obj) = outputObj,
                      let expectedA = obj["a"]?.doubleValue,
                      let expectedB = obj["b"]?.doubleValue else {
                    XCTFail("\(testCase.name): missing or malformed output {a, b}")
                    continue
                }
                do {
                    let fit = try fitSkinTemp(raw: raw, y: y, fitOffset: fitOffset)
                    // Fixture "a" = slope, "b" = offset
                    assertParity(actual: fit.slope, expected: expectedA, tolerance: tolerance)
                    assertParity(actual: fit.offset, expected: expectedB, tolerance: tolerance)
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }

    // MARK: leaveOneNightOut parity

    func testLeaveOneNightOutParity() throws {
        let config = try ToleranceConfig.load()
        let url = try resourceURL("leave_one_night_out", "json")
        let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 0)
        let tolerance = config.spec(for: fixture.function)

        for testCase in fixture.cases {
            guard let features = testCase.inputs["features"]?.arrayOfDoubles,
                  let labels   = testCase.inputs["labels"]?.arrayOfDoubles else {
                XCTFail("\(testCase.name): missing features or labels")
                continue
            }
            guard case .array(let nightIdsArr) = testCase.inputs["night_ids"] else {
                XCTFail("\(testCase.name): missing night_ids")
                continue
            }
            let nightIds = nightIdsArr.compactMap { v -> Int? in
                if case .double(let d) = v { return Int(d) } else { return nil }
            }
            guard nightIds.count == nightIdsArr.count else {
                XCTFail("\(testCase.name): night_ids decode dropped \(nightIdsArr.count - nightIds.count) elements — check that all night_id values are encoded as numbers")
                continue
            }

            // Parse n_params kwarg (default 2)
            let nParams: Int
            if let kw = testCase.kwargs, case .double(let np) = kw["n_params"] { nParams = Int(np) }
            else { nParams = 2 }

            if testCase.raises != nil {
                XCTAssertThrowsError(
                    try leaveOneNightOut(features: features, labels: labels, nightIds: nightIds, nParams: nParams),
                    "\(testCase.name): expected throw"
                )
            } else {
                guard let outputObj = testCase.output,
                      case .object(let obj) = outputObj else {
                    XCTFail("\(testCase.name): missing or malformed output dict")
                    continue
                }
                do {
                    let result = try leaveOneNightOut(features: features, labels: labels, nightIds: nightIds, nParams: nParams)

                    // Assert n_nights
                    if case .double(let expectedN) = obj["n_nights"] {
                        XCTAssertEqual(result.nNights, Int(expectedN), "\(testCase.name): n_nights mismatch")
                    }
                    // Assert mean_mae (may be NaN — assertParity handles NaN).
                    // For near-zero values (< 1e-10), use absolute tolerance to avoid relative
                    // error inflation from normal-equations vs SVD floating-point differences.
                    if let maeFV = obj["mean_mae"], let expectedMae = maeFV.doubleValue {
                        if expectedMae.isNaN {
                            XCTAssertTrue(result.meanMae.isNaN, "\(testCase.name): mean_mae should be NaN")
                        } else if abs(expectedMae) < 1e-10 {
                            XCTAssertEqual(result.meanMae, expectedMae, accuracy: 1e-10,
                                           "\(testCase.name): mean_mae near-zero mismatch")
                        } else {
                            assertParity(actual: result.meanMae, expected: expectedMae, tolerance: tolerance)
                        }
                    }
                    // Assert mean_rmse (may be NaN)
                    if let rmseFV = obj["mean_rmse"], let expectedRmse = rmseFV.doubleValue {
                        if expectedRmse.isNaN {
                            XCTAssertTrue(result.meanRmse.isNaN, "\(testCase.name): mean_rmse should be NaN")
                        } else if abs(expectedRmse) < 1e-10 {
                            XCTAssertEqual(result.meanRmse, expectedRmse, accuracy: 1e-10,
                                           "\(testCase.name): mean_rmse near-zero mismatch")
                        } else {
                            assertParity(actual: result.meanRmse, expected: expectedRmse, tolerance: tolerance)
                        }
                    }
                    // Assert per-night MAEs
                    // Note: when expected values are effectively zero (< 1e-10), use absolute
                    // comparison at 1e-10 rather than relative — tiny floating-point differences
                    // in normal-equations vs SVD polyfit produce huge relative errors near zero.
                    if case .array(let expectedMaesArr) = obj["night_maes"] {
                        let expectedMaes = expectedMaesArr.compactMap { $0.doubleValue }
                        XCTAssertEqual(result.nightMaes.count, expectedMaes.count,
                                       "\(testCase.name): night_maes length mismatch")
                        for (i, (a, e)) in zip(result.nightMaes, expectedMaes).enumerated() {
                            let absErr = abs(a - e)
                            let thresh = abs(e) < 1e-10 ? 1e-10 : tolerance.epsilon * max(abs(e), 1e-12)
                            if absErr > thresh {
                                XCTFail("\(testCase.name).nightMaes[\(i)]: actual=\(a) expected=\(e) absErr=\(absErr)")
                            }
                        }
                    }
                } catch {
                    XCTFail("\(testCase.name): unexpected throw \(error)")
                }
            }
        }
    }
}
