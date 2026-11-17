import XCTest
@testable import Loop

final class ProfileLogicTests: XCTestCase {
    private typealias F = BodyProfileFormatting
    private let fr = Locale(identifier: "fr_FR")

    func testFeetAndInches() {
        let r = F.feetAndInches(fromCm: 175)   // 68,9 in -> 69 in = 5'9"
        XCTAssertEqual(r.feet, 5)
        XCTAssertEqual(r.inches, 9)
        let r2 = F.feetAndInches(fromCm: 182.88) // 72 in = 6'0"
        XCTAssertEqual(r2.feet, 6)
        XCTAssertEqual(r2.inches, 0)
    }

    func testRoundTrips() {
        for kg in stride(from: 20.0, through: 400.0, by: 12.3) {
            XCTAssertEqual(F.lbToKg(F.kgToLb(kg)), kg, accuracy: 0.05)
        }
        for cm in stride(from: 100.0, through: 250.0, by: 7.7) {
            XCTAssertEqual(F.inchesToCm(F.cmToInches(cm)), cm, accuracy: 0.05)
        }
        XCTAssertEqual(F.cm(feet: 5, inches: 9), 175.26, accuracy: 0.01)
    }

    func testDisplay() {
        XCTAssertEqual(F.heightText(cm: 175, units: .metric, locale: fr), "175 cm")
        XCTAssertEqual(F.heightText(cm: 175, units: .imperial, locale: fr), "5′9″")
        XCTAssertEqual(F.weightText(kg: 72.5, units: .metric, locale: fr), "72,5 kg")
        XCTAssertEqual(F.weightText(kg: 72.5, units: .imperial, locale: fr), "159,8 lb")
    }

    func testValidationBounds() {
        XCTAssertNil(F.validatedAge(9))
        XCTAssertEqual(F.validatedAge(10), 10)
        XCTAssertEqual(F.validatedAge(100), 100)
        XCTAssertNil(F.validatedAge(101))
        XCTAssertNil(F.validatedHeightCm(99.9, units: .metric))
        XCTAssertEqual(F.validatedHeightCm(100, units: .metric), 100)
        XCTAssertEqual(F.validatedHeightCm(250, units: .metric), 250)
        XCTAssertNil(F.validatedHeightCm(250.1, units: .metric))
        XCTAssertNotNil(F.validatedHeightCm(69, units: .imperial))   // 175,26 cm
        XCTAssertNil(F.validatedHeightCm(30, units: .imperial))      // 76 cm
        XCTAssertNil(F.validatedWeightKg(19.9, units: .metric))
        XCTAssertEqual(F.validatedWeightKg(400, units: .metric), 400)
        XCTAssertNil(F.validatedWeightKg(400.1, units: .metric))
        XCTAssertNil(F.validatedWeightKg(1000, units: .imperial))    // ~453 kg
        XCTAssertEqual(F.validatedWeightKg(160, units: .imperial) ?? 0, 72.57, accuracy: 0.01)
    }

    func testMaxHeartRateLabels() {
        XCTAssertEqual(F.maxHeartRateLabel(bpm: 184, provenance: .ageEstimate), "Auto ≈ 184 bpm")
        XCTAssertEqual(F.maxHeartRateLabel(bpm: 190, provenance: .manual), "Manuelle 190 bpm")
    }

    func testTanakaFormulaOnlyWhenAuto() {
        XCTAssertEqual(UserMaxHeartRate.ageEstimate(age: 34), 184)
        XCTAssertEqual(F.maxHeartRateFormula(provenance: .ageEstimate, age: 34), "208 − 0,7 × 34 ans (Tanaka)")
        XCTAssertNil(F.maxHeartRateFormula(provenance: .manual, age: 34))
        XCTAssertNil(F.maxHeartRateFormula(provenance: .measured, age: 34))
    }
}
