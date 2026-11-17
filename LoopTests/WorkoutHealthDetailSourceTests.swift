import CoreLocation
import HealthKit
import XCTest
import WhoopStore
@testable import Loop

/// Parties pures de la source HealthKit (le tracé et l'autorisation réels se vérifient sur iPhone).
final class WorkoutHealthDetailSourceTests: XCTestCase {
    func testLocationMappingDropsInvalidAccuracies() {
        let valid = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.85, longitude: 2.35),
                               altitude: 35, horizontalAccuracy: 5, verticalAccuracy: 3,
                               timestamp: Date(timeIntervalSince1970: 1_000))
        let p = HealthKitWorkoutDetailSource.point(from: valid)
        XCTAssertEqual(p, WorkoutRoutePoint(timestamp: 1_000, latitude: 48.85, longitude: 2.35,
                                            altitude: 35, horizontalAccuracy: 5))

        let noAltitude = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 2),
                                    altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
                                    timestamp: Date(timeIntervalSince1970: 0))
        let q = HealthKitWorkoutDetailSource.point(from: noAltitude)
        XCTAssertNil(q.altitude)
        XCTAssertNil(q.horizontalAccuracy)
    }

    func testAuthorizationErrorsMapToNotAuthorized() {
        let denied = HKError(.errorAuthorizationDenied)
        XCTAssertEqual(HealthKitWorkoutDetailSource.mapped(denied) as? WorkoutDetailSourceError, .notAuthorized)
        let undetermined = HKError(.errorAuthorizationNotDetermined)
        XCTAssertEqual(HealthKitWorkoutDetailSource.mapped(undetermined) as? WorkoutDetailSourceError, .notAuthorized)
        let other = HKError(.errorDatabaseInaccessible)
        XCTAssertNil(HealthKitWorkoutDetailSource.mapped(other) as? WorkoutDetailSourceError)
    }

    func testReadTypesNeverIncludeWrite() {
        XCTAssertTrue(HealthKitWorkoutDetailSource.readTypes(for: .route).contains(HKSeriesType.workoutRoute()))
        XCTAssertTrue(HealthKitWorkoutDetailSource.readTypes(for: .heart).contains(HKQuantityType(.heartRate)))
        XCTAssertTrue(HealthKitImporter.requestedReadTypes.contains(HKSeriesType.workoutRoute()))
    }
}
