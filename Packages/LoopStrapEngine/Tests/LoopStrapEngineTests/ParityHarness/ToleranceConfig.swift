import Foundation
import XCTest

// MARK: - ToleranceMode

/// Comparison strategy used by `assertParity`.
public enum ToleranceMode: String, Codable {
    case absolute  = "absolute"
    case relative  = "relative"
    case rankOrder = "rank-order"
}

// MARK: - ToleranceSpec

/// Per-function tolerance specification: mode + epsilon value + optional explanatory note.
public struct ToleranceSpec: Codable {
    public let mode: ToleranceMode
    public let epsilon: Double
    public let note: String?

    public init(mode: ToleranceMode, epsilon: Double, note: String? = nil) {
        self.mode = mode
        self.epsilon = epsilon
        self.note = note
    }
}

// MARK: - ToleranceConfig

/// Per-function tolerance table loaded from `tolerance_config.json` at test runtime.
///
/// Provides a `default` spec and per-function overrides. Call `spec(for:)` to
/// retrieve the tightest applicable tolerance for a given function name.
public struct ToleranceConfig: Codable {
    /// Fallback tolerance used when a function has no explicit override.
    public let `default`: ToleranceSpec
    /// Per-function overrides keyed by the Python function name.
    public let functions: [String: ToleranceSpec]

    // MARK: - Accessor

    /// Returns the `ToleranceSpec` for `functionName`, falling back to `default`.
    public func spec(for functionName: String) -> ToleranceSpec {
        functions[functionName] ?? `default`
    }

    // MARK: - Loading

    /// Loads `tolerance_config.json` from `Bundle.module`.
    ///
    /// Throws if the resource is missing or malformed.
    public static func load() throws -> ToleranceConfig {
        let url = try resourceURL("tolerance_config", "json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ToleranceConfig.self, from: data)
    }
}
