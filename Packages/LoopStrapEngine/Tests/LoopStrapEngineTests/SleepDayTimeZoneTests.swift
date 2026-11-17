import Foundation
import XCTest
@testable import LoopStrapEngine

final class SleepDayTimeZoneTests: XCTestCase {
    private func makeSession(ending date: String) -> SleepSession {
        let end = ISO8601DateFormatter().date(from: date)!.timeIntervalSince1970
        let start = end - 3600
        return SleepSession(start: start, end: end,
                            stages: [StageSegment(start: start, end: end, stage: .light)],
                            efficiency: 1, tst: 60, sol: 0, waso: 0,
                            restingHR: 60, avgRmssd: 50, nDisturbances: 0)
    }

    func testUTCDefaultDoesNotAttributeParisMidnightToTheNextDay() {
        let session = makeSession(ending: "2026-11-13T23:30:00Z")
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-11-13").totalSleepMin, 60)
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-11-14").totalSleepMin, 0)
        let paris = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-11-14", timeZone: paris).totalSleepMin, 60)
    }

    func testExplicitTimeZoneHonorsDaylightSavingTime() {
        let paris = TimeZone(identifier: "Europe/Paris")!
        // After the DST jump, 22:30 UTC is 00:30 the following local day, not 23:30.
        let session = makeSession(ending: "2026-03-29T22:30:00Z")
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-03-29").totalSleepMin, 60)
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-03-30", timeZone: paris).totalSleepMin, 60)
        // After the autumn transition the same UTC time is still on the same local day.
        let autumn = makeSession(ending: "2026-10-25T22:30:00Z")
        XCTAssertEqual(dailySleepSummary(sessions: [autumn], date: "2026-10-25", timeZone: paris).totalSleepMin, 60)
    }

    // MARK: - Local day policy

    private let paris = TimeZone(identifier: "Europe/Paris")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func instant(_ iso: String) -> Double { ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 }

    func testSpringAndAutumnDSTDaysLast23And25Hours() {
        let schedule = LocalDaySchedule(currentZone: paris, now: Date(timeIntervalSince1970: instant("2026-11-14T12:00:00Z")))
        let spring = schedule.bounds("2026-03-29")
        XCTAssertEqual(Double(spring.from), instant("2026-03-28T23:00:00Z"))
        XCTAssertEqual(spring.to - spring.from + 1, 23 * 3600)
        let autumn = schedule.bounds("2026-10-25")
        XCTAssertEqual(Double(autumn.from), instant("2026-10-24T22:00:00Z"))
        XCTAssertEqual(autumn.to - autumn.from + 1, 25 * 3600)
        // Consecutive days tile time without gaps or overlaps across both transitions.
        var day = "2026-03-27"
        while day < "2026-10-27" {
            let next = LocalDay.adding(1, to: day)
            XCTAssertEqual(schedule.bounds(day).to + 1, schedule.bounds(next).from, day)
            day = next
        }
    }

    func testNightCrossingMidnightIsAttributedToItsLocalEndDay() {
        let schedule = LocalDaySchedule(currentZone: paris, now: Date(timeIntervalSince1970: instant("2026-11-14T12:00:00Z")))
        // Ends at 00:30 local on 14 Nov (23:30Z on the 13th).
        let session = makeSession(ending: "2026-11-13T23:30:00Z")
        XCTAssertEqual(schedule.day(containing: session.end), "2026-11-14")
        let b14 = schedule.bounds("2026-11-14"), b13 = schedule.bounds("2026-11-13")
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-11-14",
                                         endWindow: (Double(b14.from), Double(b14.to) + 1)).totalSleepMin, 60)
        XCTAssertEqual(dailySleepSummary(sessions: [session], date: "2026-11-13",
                                         endWindow: (Double(b13.from), Double(b13.to) + 1)).totalSleepMin, 0)
        // After the spring jump, 22:30Z is 00:30 local the next day.
        let spring = makeSession(ending: "2026-03-29T22:30:00Z")
        XCTAssertEqual(schedule.day(containing: spring.end), "2026-03-30")
    }

    func testEarlyMorningActivityBelongsToTheLocalDay() {
        let schedule = LocalDaySchedule(currentZone: paris, now: Date(timeIntervalSince1970: instant("2026-11-14T12:00:00Z")))
        // 00:00 → 02:00 local on 13 Nov is 23:00Z (12 Nov) → 01:00Z.
        for iso in ["2026-11-12T23:00:00Z", "2026-11-12T23:59:59Z", "2026-11-13T00:59:59Z"] {
            XCTAssertEqual(schedule.day(containing: instant(iso)), "2026-11-13", iso)
        }
        XCTAssertEqual(schedule.day(containing: instant("2026-11-12T22:59:59Z")), "2026-11-12")
        XCTAssertEqual(schedule.today, "2026-11-14")
        XCTAssertEqual(schedule.days(count: 3), ["2026-11-12", "2026-11-13", "2026-11-14"])
    }

    func testTravelKeepsFrozenZonesAndTilesTime() {
        // 12 Nov was computed in Paris; the user is now in New York on the 13th.
        let now = Date(timeIntervalSince1970: instant("2026-11-14T01:00:00Z"))  // 20:00 NY, 13 Nov
        let schedule = LocalDaySchedule(currentZone: newYork,
                                        frozen: ["2026-11-11": "Europe/Paris", "2026-11-12": "Europe/Paris"], now: now)
        XCTAssertEqual(schedule.today, "2026-11-13")
        XCTAssertEqual(schedule.zoneIdentifier(for: "2026-11-12"), "Europe/Paris")
        XCTAssertEqual(schedule.zoneIdentifier(for: "2026-11-13"), "America/New_York")
        let paris12 = schedule.bounds("2026-11-12")
        XCTAssertEqual(Double(paris12.from), instant("2026-11-11T23:00:00Z"))
        XCTAssertEqual(Double(paris12.to + 1), instant("2026-11-12T23:00:00Z"))
        let travel = schedule.bounds("2026-11-13")
        XCTAssertEqual(travel.from, paris12.to + 1)
        XCTAssertEqual(Double(travel.to + 1), instant("2026-11-14T05:00:00Z"))
        // 03:00 NY on 13 Nov is in the travel day, 23:30 Paris on 12 Nov stays on the 12th.
        XCTAssertEqual(schedule.day(containing: instant("2026-11-13T08:00:00Z")), "2026-11-13")
        XCTAssertEqual(schedule.day(containing: instant("2026-11-12T22:30:00Z")), "2026-11-12")
        let registry = schedule.registry(recording: schedule.days(count: 3))
        XCTAssertEqual(registry["2026-11-12"], "Europe/Paris")
        XCTAssertEqual(registry["2026-11-13"], "America/New_York")
        // Eastward trip: a past New York day followed by Paris today stays contiguous.
        let east = LocalDaySchedule(currentZone: paris, frozen: ["2026-11-12": "America/New_York"],
                                    now: Date(timeIntervalSince1970: instant("2026-11-13T12:00:00Z")))
        XCTAssertEqual(east.bounds("2026-11-12").to + 1, east.bounds("2026-11-13").from)
        XCTAssertEqual(east.bounds("2026-11-13").to - east.bounds("2026-11-13").from + 1, 18 * 3600)
    }

    func testDayKeyArithmeticAndUTCRevisionMapping() {
        XCTAssertEqual(LocalDay.adding(1, to: "2026-02-28"), "2026-03-01")
        XCTAssertEqual(LocalDay.adding(-1, to: "2026-01-01"), "2025-12-31")
        XCTAssertNil(LocalDay.components("2026-02-30"))
        XCTAssertNil(LocalDay.components("2026-1-01"))
        let schedule = LocalDaySchedule(currentZone: paris, now: Date(timeIntervalSince1970: instant("2026-11-14T12:00:00Z")))
        let b = schedule.bounds("2026-11-13")
        XCTAssertEqual(LocalDaySchedule.utcDays(from: b.from, to: b.to), ["2026-11-12", "2026-11-13"])
    }
}
