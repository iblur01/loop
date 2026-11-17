import Foundation
import XCTest
@testable import LoopStrapEngine

final class TrainingAdviceInvariantsTests: XCTestCase {
    private let today = TrainingFixtures.today

    private let knownCodes: Set<String> = [
        TrainingInsightCode.loadRatio, TrainingInsightCode.monotony, TrainingInsightCode.regularity,
        TrainingInsightCode.sleepTrend, TrainingInsightCode.sleepRecoveryConflict,
        TrainingInsightCode.feelingRecoveryConflict, TrainingInsightCode.volumeRun,
        TrainingInsightCode.volumeSwim, TrainingInsightCode.volumeStrength, TrainingInsightCode.changeLoad,
        TrainingInsightCode.changeSleep, TrainingInsightCode.changeRecovery, TrainingInsightCode.linkLoadSleep,
        TrainingInsightCode.linkLoadRecovery, TrainingInsightCode.linkSleepRecovery,
        TrainingInsightCode.linkEfficiencyRecovery
    ]

    /// A scenario set exercising most rules.
    private func scenarios() -> [TrainingInputs] {
        var conflict = TrainingFixtures.rich()
        conflict.sleep = conflict.sleep.map { n in
            var m = n
            if n.day >= today - 1 { m.durationMinutes = 300 }
            return m
        }
        conflict.recovery = conflict.recovery.map { r in
            var m = r
            if r.day == today { m.score = 88; m.experimentalLabel = "expérimental" }
            return m
        }
        conflict.feelings = [TrainingFeelingDay(day: today, value: 1)]
        var shifted = TrainingFixtures.rich()
        shifted.dailyLoads = shifted.dailyLoads.map { l in
            var m = l
            if l.day > today - 10 { m.value = 25 }
            return m
        }
        return [TrainingFixtures.rich(), conflict, shifted,
                TrainingFixtures.rich(asOf: today + 11, span: 20)]
    }

    func testEveryInsightIsTraceableLocalisedAndWellFormed() {
        var seen = 0
        for input in scenarios() {
            for i in TrainingAdviceEngine.insights(for: input) {
                seen += 1
                XCTAssertTrue(knownCodes.contains(i.code), i.code)
                XCTAssertFalse(i.contributors.isEmpty, i.code)
                XCTAssertFalse(i.facts.isEmpty, i.code)
                XCTAssertTrue(i.facts.allSatisfy { $0.value.isFinite }, i.code)
                XCTAssertEqual(Set(i.facts.map { $0.key }).count, i.facts.count, "duplicate fact keys in \(i.code)")
                assertNumbersTraceable(i)
                assertAllKeysLocalised(i)
            }
        }
        XCTAssertGreaterThan(seen, 20)
    }

    func testCodesAreUniquePerRunAndStableAcrossRuns() {
        for input in scenarios() {
            let codes = TrainingAdviceEngine.insights(for: input).map { $0.code }
            XCTAssertEqual(Set(codes).count, codes.count)
            XCTAssertEqual(codes, TrainingAdviceEngine.insights(for: input).map { $0.code })
        }
    }

    func testTextsNeverGiveCategoricalOrMedicalStatements() {
        let forbidden = ["devez", "doit ", "obligatoire", "blessure", "maladie", "surentraînement",
                         "diagnostic médical", "sans danger", "risque de"]
        for input in scenarios() {
            for i in TrainingAdviceEngine.insights(for: input) {
                let text = (TrainingInsightRenderer.short(i) + " " + TrainingInsightRenderer.detail(i)).lowercased()
                for word in forbidden {
                    XCTAssertFalse(text.contains(word), "\(i.code) contains '\(word)'")
                }
                if i.isExperimental {
                    XCTAssertTrue(i.detailNoteKeys.contains("training.note.experimental_recovery"), i.code)
                }
            }
        }
    }

    func testEveryTemplatePlaceholderIsResolvableOrIntentionallyAbsent() {
        // No template may contain a literal digit: numbers must come from facts.
        for (key, text) in TrainingInsightStrings.fr {
            XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), "literal digit in \(key)")
            XCTAssertEqual(text.filter { $0 == "{" }.count, text.filter { $0 == "}" }.count, key)
        }
    }

    func testTraceabilityHelperDetectsFabricatedNumbers() {
        let strings = ["k.short": "Valeur 42 et {a}.", "k.detail": "Détail {a}."]
        let bad = TrainingInsight(code: "X", state: .ok, confidence: .low,
                                  facts: [TrainingFact(key: "a", value: 3.14159, decimals: 1)],
                                  contributors: ["c"], shortKey: "k.short", detailKey: "k.detail",
                                  detailNoteKeys: [], isExperimental: false)
        XCTAssertEqual(untraceableNumbers(in: bad, strings: strings), ["42"])
        let missing = TrainingInsight(code: "X", state: .ok, confidence: .low, facts: [],
                                      contributors: ["c"], shortKey: "k.detail", detailKey: "k.detail",
                                      detailNoteKeys: [], isExperimental: false)
        XCTAssertFalse(untraceableNumbers(in: missing, strings: strings).isEmpty)
        XCTAssertEqual(TrainingFact(key: "a", value: 3.14159, decimals: 1).formatted, "3,1")
    }

    func testNumbersInInsightsMatchInputsNotInventedValues() throws {
        // Facts derived from a hand-checkable input.
        var input = TrainingInputs(asOfDay: today)
        input.dailyLoads = TrainingFixtures.loads((today - 27)...today) { _ in 12 }
        let load = try XCTUnwrap(TrainingAdviceEngine.insights(for: input).first { $0.code == TrainingInsightCode.loadRatio })
        XCTAssertEqual(try XCTUnwrap(load.fact("acute")?.value), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(load.fact("chronic")?.value), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(load.fact("ratio")?.value), 1, accuracy: 1e-9)
        XCTAssertEqual(load.shortKey, "training.load_ratio.stable.short")
    }

    func testReusingAReportGivesTheSameInsights() {
        let input = TrainingFixtures.rich()
        XCTAssertEqual(TrainingAdviceEngine.insights(for: input),
                       TrainingAdviceEngine.insights(for: input, report: TrainingStats.compute(input)))
    }

    func testInsightAndReportRoundTripThroughCodable() throws {
        let input = TrainingFixtures.rich()
        let insights = TrainingAdviceEngine.insights(for: input)
        let decoded = try JSONDecoder().decode([TrainingInsight].self, from: JSONEncoder().encode(insights))
        XCTAssertEqual(decoded, insights)
        let report = TrainingStats.compute(input)
        XCTAssertEqual(try JSONDecoder().decode(TrainingStatsReport.self, from: JSONEncoder().encode(report)), report)
    }
}
