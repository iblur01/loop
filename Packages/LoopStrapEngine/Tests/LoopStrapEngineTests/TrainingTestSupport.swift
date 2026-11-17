import Foundation
import XCTest
@testable import LoopStrapEngine

/// Synthetic, deterministic fixtures. No real health data.
enum TrainingFixtures {
    static let today = 20_000

    /// Deterministic pseudo-random integer in 0..<mod (as Double).
    static func pseudo(_ i: Int, _ mod: Int) -> Double {
        Double(((abs(i) &* 7919) &+ 13) % mod)
    }

    static func loads(_ days: ClosedRange<Int>, confidence: TrainingConfidence? = .medium,
                      _ value: (Int) -> Double?) -> [TrainingDailyLoad] {
        days.map { TrainingDailyLoad(day: $0, value: value($0), confidence: confidence, source: "band") }
    }

    static func sleep(_ days: ClosedRange<Int>, _ minutes: (Int) -> Double?) -> [TrainingSleepNight] {
        days.map { TrainingSleepNight(day: $0, durationMinutes: minutes($0), efficiency: 0.9,
                                      awakenings: 1, coverage: 0.95, source: "band") }
    }

    /// Sixty days of plausible-looking synthetic data for every input family.
    static func rich(asOf: Int = today, span: Int = 60) -> TrainingInputs {
        var input = TrainingInputs(asOfDay: asOf)
        for d in (asOf - span)...asOf {
            let i = d - (asOf - span)
            input.dailyLoads.append(TrainingDailyLoad(day: d, value: 8 + pseudo(i, 7) * 0.5,
                                                      confidence: .medium, source: "band"))
            input.sleep.append(TrainingSleepNight(day: d, durationMinutes: 420 + pseudo(i, 9) * 5,
                                                  efficiency: 0.85 + pseudo(i, 5) * 0.01,
                                                  awakenings: Int(pseudo(i, 4)), coverage: 0.95, source: "band"))
            input.recovery.append(TrainingRecoveryDay(day: d, score: 50 + pseudo(i, 13) * 2, confidence: .medium))
            let t0 = Double(d) * 86_400 + 7 * 3_600
            if i % 3 == 0 {
                input.sessions.append(TrainingSession(id: "run-\(d)", day: d, sport: .run, startTime: t0,
                                                      durationMinutes: 40 + pseudo(i, 5), cardioLoad: 6, source: "band"))
            }
            if i % 4 == 1 {
                input.sessions.append(TrainingSession(id: "str-\(d)", day: d, sport: .strength,
                                                      startTime: t0 + 36_000, durationMinutes: 50,
                                                      perceivedExertion: 7, source: "manual"))
            }
            if i % 7 == 2 {
                input.sessions.append(TrainingSession(id: "swim-\(d)", day: d, sport: .swim, startTime: t0 + 3_600,
                                                      durationMinutes: 30, source: "band"))
            }
        }
        return input
    }

    /// Deterministic reordering of every array of the input.
    static func reordered(_ input: TrainingInputs) -> TrainingInputs {
        func shuffle<T>(_ a: [T]) -> [T] {
            guard a.count > 2 else { return a.reversed() }
            let k = a.count / 3
            return Array(a.reversed().dropFirst(k)) + Array(a.reversed().prefix(k))
        }
        var o = input
        o.dailyLoads = shuffle(input.dailyLoads)
        o.sessions = shuffle(input.sessions)
        o.sleep = shuffle(input.sleep)
        o.recovery = shuffle(input.recovery)
        o.feelings = shuffle(input.feelings)
        return o
    }
}

/// Numbers (and unresolved placeholders) in an insight's rendered texts that are not backed by its facts.
/// An empty result means every cited number exists in `insight.facts`.
func untraceableNumbers(in insight: TrainingInsight,
                        strings: [String: String] = TrainingInsightStrings.fr) -> [String] {
    let allowed = Set(insight.facts.map {
        TrainingFact(key: $0.key, value: abs($0.value), decimals: $0.decimals).formatted
    })
    let texts = [TrainingInsightRenderer.short(insight, strings: strings),
                 TrainingInsightRenderer.detail(insight, strings: strings)]
    guard let regex = try? NSRegularExpression(pattern: "[0-9]+(?:,[0-9]+)?") else { return ["regex"] }
    var offenders: [String] = []
    for text in texts {
        if text.contains("{") || text.contains("n/d") { offenders.append("unresolved:\(text)") }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: m.range)
            if !allowed.contains(token) { offenders.append(token) }
        }
    }
    return offenders
}

func assertNumbersTraceable(_ insight: TrainingInsight, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(untraceableNumbers(in: insight), [], "Untraceable numbers in \(insight.code)",
                   file: file, line: line)
}

func assertAllKeysLocalised(_ insight: TrainingInsight, file: StaticString = #filePath, line: UInt = #line) {
    for key in [insight.shortKey, insight.detailKey] + insight.detailNoteKeys {
        XCTAssertNotNil(TrainingInsightStrings.fr[key], "Missing string \(key)", file: file, line: line)
    }
}
