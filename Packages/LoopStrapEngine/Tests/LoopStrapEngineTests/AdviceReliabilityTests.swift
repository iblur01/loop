import Foundation
import XCTest
@testable import LoopStrapEngine

final class AdviceReliabilityTests: XCTestCase {
    func testEffortAdviceKeepsUnknownDistinctFromNoOverloadAndReportsBaselineConfidence() throws {
        let recovery = RecoveryResult(score: nil, band: nil, confidence: "low", zHrv: nil, zRhr: nil, zResp: nil)
        func signal(_ baseline: BaselineState?, _ recent: [Double?]) throws -> (AdviceSignal, [String: Any]) {
            let result = AdviceEngine.compute(recovery: recovery, sleepHistory: [], durationBaseline: nil,
                bedtimeBaseline: nil, tonightBedtimeOffset: nil, strainBaseline: baseline,
                recentStrainHistory: recent)
            let signal = try XCTUnwrap(result.secondary.first { $0.code == AdviceCode.effortTarget.rawValue })
            let params = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(signal.paramsJSON.utf8)) as? [String: Any])
            return (signal, params)
        }
        let unknown = try signal(nil, [])
        XCTAssertNil(unknown.1["recent_overload"])
        XCTAssertEqual(unknown.0.confidence, "low")
        let provisional = BaselineState(baseline: 10, spread: 2, nValid: 4, nightsSinceUpdate: 0, status: .provisional)
        let known = try signal(provisional, [9, 11])
        XCTAssertEqual(known.1["recent_overload"] as? Bool, true)
        XCTAssertEqual(known.0.confidence, "medium")
        XCTAssertNil(try signal(provisional, [nil]).1["recent_overload"])
    }
}
