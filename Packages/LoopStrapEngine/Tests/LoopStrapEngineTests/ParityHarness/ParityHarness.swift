import XCTest
@testable import LoopStrapEngine
import Foundation

// MARK: - JSONDouble

/// Codable wrapper for Double that handles JSON NaN/Infinity sentinels.
///
/// The Python oracle serializes float NaN as the JSON string "NaN" and Infinity as
/// "Infinity" / "-Infinity" (not raw JSON tokens, which are not valid JSON per RFC 8259).
/// This type decodes both forms and re-encodes NaN/Infinity as strings.
public struct JSONDouble: Codable {
    public let value: Double

    public init(_ value: Double) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try numeric first (most common path).
        if let d = try? container.decode(Double.self) {
            value = d
            return
        }
        // Fall back to string sentinel ("NaN", "Infinity", "-Infinity").
        let s = try container.decode(String.self)
        switch s {
        case "NaN":       value = .nan
        case "Infinity":  value = .infinity
        case "-Infinity": value = -.infinity
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONDouble: unexpected string sentinel '\(s)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if value.isNaN {
            try container.encode("NaN")
        } else if value.isInfinite {
            try container.encode(value > 0 ? "Infinity" : "-Infinity")
        } else {
            try container.encode(value)
        }
    }
}

// MARK: - FixtureValue

/// Generic JSON value for heterogeneous fixture inputs and outputs.
///
/// Decoding order matters: Bool must precede Double to prevent `true`/`false`
/// from being silently coerced to 1.0/0.0 by JSONDouble.
public indirect enum FixtureValue: Codable {
    case double(Double)
    case string(String)
    case bool(Bool)
    case array([FixtureValue])
    case object([String: FixtureValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Bool before Double — JSON booleans must not be decoded as numbers.
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        // JSONDouble handles "NaN"/"Infinity"/"-Infinity" sentinels.
        if let jd = try? container.decode(JSONDouble.self) {
            self = .double(jd.value)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? container.decode([FixtureValue].self) {
            self = .array(arr)
            return
        }
        if let obj = try? container.decode([String: FixtureValue].self) {
            self = .object(obj)
            return
        }
        if container.decodeNil() {
            self = .null
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "FixtureValue: cannot decode token"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .double(let d): try container.encode(JSONDouble(d))
        case .string(let s): try container.encode(s)
        case .bool(let b):   try container.encode(b)
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null:          try container.encodeNil()
        }
    }

    // MARK: - Convenience accessors

    /// Extracts the underlying Double value from `.double(_)`.
    public var doubleValue: Double? {
        guard case .double(let d) = self else { return nil }
        return d
    }

    /// Extracts an array of Doubles from `.array([.double(...), ...])`.
    public var arrayOfDoubles: [Double]? {
        guard case .array(let arr) = self else { return nil }
        var result = [Double]()
        for element in arr {
            guard case .double(let d) = element else { return nil }
            result.append(d)
        }
        return result
    }
}

// MARK: - FixtureFile

/// Top-level structure of a fixture JSON file produced by export_unit_fixtures.py.
public struct FixtureFile: Codable {
    public let module: String
    public let function: String
    public let oracleGitSha: String
    public let cases: [FixtureCase]

    // oracle_versions and exported_at decoded but unused by the harness.
    public let oracleVersions: [String: String]?
    public let exportedAt: String?

    private enum CodingKeys: String, CodingKey {
        case module
        case function
        case oracleGitSha  = "oracle_git_sha"
        case cases
        case oracleVersions = "oracle_versions"
        case exportedAt     = "exported_at"
    }
}

// MARK: - FixtureCase

/// One input/output pair within a fixture file.
public struct FixtureCase: Codable {
    public let name: String
    public let inputs: [String: FixtureValue]
    public let kwargs: [String: FixtureValue]?
    /// `nil` when the Python function returned `None` (output_is_none: true).
    public let output: FixtureValue?
    /// `true` when the Python function returned `None` (distinct from raising).
    public let outputIsNone: Bool?
    /// Optional Python exception class name for error-path cases.
    public let raises: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case inputs
        case kwargs
        case output
        case outputIsNone = "output_is_none"
        case raises
    }
}

// MARK: - Helpers

/// Loads a test resource URL from `Bundle.module`, failing the test with a descriptive
/// message if the resource is missing (e.g., oracle fixtures not yet copied).
func resourceURL(_ name: String, _ ext: String) throws -> URL {
    try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: ext),
        "missing \(name).\(ext) — run export_unit_fixtures.py in server/ingest and copy fixtures/units/*.json to Tests/Resources/fixtures/units/"
    )
}

// MARK: - Parity Assertion

/// Asserts that `actual` matches `expected` within the given `tolerance`.
///
/// - NaN: asserts `actual.isNaN` (both sides must be NaN).
/// - Infinite: asserts exact equality (sign matters).
/// - `.absolute`: `|actual - expected| ≤ ε`.
/// - `.relative`: `|actual - expected| / max(|expected|, 1e-12) ≤ ε`.
/// - `.rankOrder`: placeholder — logs and passes (implemented in Phase 5).
public func assertParity(
    actual: Double,
    expected: Double,
    tolerance: ToleranceSpec,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if expected.isNaN {
        XCTAssertTrue(actual.isNaN, "Expected NaN but got \(actual)", file: file, line: line)
        return
    }
    if expected.isInfinite {
        XCTAssertEqual(actual, expected, "Expected \(expected) but got \(actual)", file: file, line: line)
        return
    }
    switch tolerance.mode {
    case .absolute:
        XCTAssertEqual(actual, expected, accuracy: tolerance.epsilon, file: file, line: line)
    case .relative:
        let scale = max(abs(expected), 1e-12)
        let relErr = abs(actual - expected) / scale
        XCTAssertLessThanOrEqual(
            relErr, tolerance.epsilon,
            "Relative error \(relErr) exceeds ε=\(tolerance.epsilon) (actual=\(actual), expected=\(expected))",
            file: file, line: line
        )
    case .rankOrder:
        // Rank-order parity is validated at the array level via assertSpearmanParity().
        // Per-value comparison is not meaningful for rank-order mode — callers must use
        // assertSpearmanParity(actual:expected:rhoMin:) directly. No-op here.
        break
    }
}

// MARK: - Spearman parity assertion

/// Assert that the Spearman rank correlation between `actual` and `expected` meets `rhoMin`.
///
/// This function complements `assertParity(mode: .rankOrder)` for scenarios where parity
/// is evaluated across a full array of values rather than element-by-element.
/// NaN values in `expected` are excluded from the comparison (they represent epochs where
/// the Python oracle returned no valid output — not meaningful for rank-order comparison).
///
/// - Parameters:
///   - actual:   Swift-computed values in the same order as `expected`.
///   - expected: Python oracle values; NaN entries are filtered out before computing ρ.
///   - rhoMin:   Minimum acceptable Spearman ρ (default 0.90 per D-04).
///   - message:  Optional context string appended to failure messages.
public func assertSpearmanParity(
    actual: [Double],
    expected: [Double],
    rhoMin: Double = 0.90,
    message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    precondition(actual.count == expected.count,
                 "assertSpearmanParity: actual.count (\(actual.count)) != expected.count (\(expected.count))")

    // Filter pairs — skip "no data" epochs on either side, fail hard when oracle is finite
    // but Swift produced NaN (that is a real implementation divergence, not a data gap).
    var filteredActual   = [Double]()
    var filteredExpected = [Double]()
    for (a, e) in zip(actual, expected) {
        if e.isNaN {
            // Valid "no data" epoch in oracle — skip.
            continue
        }
        if a.isNaN {
            // Swift returned NaN where oracle returned finite — count as a hard failure.
            XCTFail("Swift produced NaN where oracle returned \(e). \(message)",
                    file: file, line: line)
            continue
        }
        filteredActual.append(a)
        filteredExpected.append(e)
    }

    guard filteredActual.count >= 2 else {
        XCTFail("assertSpearmanParity: fewer than 2 valid (non-NaN) pairs — cannot compute ρ. \(message)",
                file: file, line: line)
        return
    }

    let rho = spearmanRho(filteredActual, filteredExpected)
    XCTAssertGreaterThanOrEqual(
        rho, rhoMin,
        "Spearman ρ=\(rho) < rhoMin=\(rhoMin). \(message)",
        file: file, line: line
    )
}

// MARK: - Helpers

/// Spearman rank correlation coefficient between two equal-length arrays.
///
/// Uses the rank-averaging formula for tied values. Returns `.nan` for fewer than 2 elements.
///
/// Implementation note: computes the Pearson correlation of the rank arrays rather than the
/// simplified `1 - 6*sumD2/(n*(n^2-1))` shortcut. The shortcut is algebraically equivalent
/// only when all ranks are distinct integers (no ties). `_ranks` produces fractional averaged
/// ranks for tied values, so the Pearson formulation is required for correctness.
private func spearmanRho(_ x: [Double], _ y: [Double]) -> Double {
    precondition(x.count == y.count)
    let n = x.count
    guard n >= 2 else { return .nan }
    let rx = _ranks(x)
    let ry = _ranks(y)
    // Pearson correlation of rank arrays — correctly handles fractional (tied) ranks.
    let nd = Double(n)
    let mx = rx.reduce(0, +) / nd
    let my = ry.reduce(0, +) / nd
    let num = zip(rx, ry).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
    let sx  = rx.reduce(0.0) { $0 + ($1 - mx) * ($1 - mx) }
    let sy  = ry.reduce(0.0) { $0 + ($1 - my) * ($1 - my) }
    guard sx > 0, sy > 0 else { return 1.0 }  // all tied → perfect rank agreement
    return num / (sx * sy).squareRoot()
}

/// Compute fractional ranks for an array, averaging ranks for tied values.
///
/// Example: `[3, 1, 3]` → `[2.5, 1.0, 2.5]`.
private func _ranks(_ xs: [Double]) -> [Double] {
    let sorted = xs.enumerated().sorted { $0.element < $1.element }
    var result = [Double](repeating: 0.0, count: xs.count)
    var i = 0
    while i < sorted.count {
        var j = i
        while j < sorted.count && sorted[j].element == sorted[i].element { j += 1 }
        // Average rank for the tie group (1-based ranks: position i → rank i+1)
        let avgRank = Double(i + j + 1) / 2.0
        for k in i..<j { result[sorted[k].offset] = avgRank }
        i = j
    }
    return result
}
