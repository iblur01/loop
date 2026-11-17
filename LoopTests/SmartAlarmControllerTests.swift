import XCTest
@testable import Loop

final class SmartAlarmControllerTests: XCTestCase {

    /// Calendrier déterministe (grégorien, UTC) pour des dates reproductibles indépendamment de la
    /// timezone de la machine de test.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Construit une `Date` UTC depuis ses composantes.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    // 2026-06-19 est un VENDREDI (weekday 6 selon Calendar : 1=dim...7=sam).

    func testOneShotLaterToday() {
        let now = date(2026, 6, 19, 6, 0) // vendredi 06:00
        let fire = AlarmScheduler.nextFireDate(hour: 7, minute: 0, weekdays: [], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 19, 7, 0))
    }

    func testOneShotPassedTodayRollsToTomorrow() {
        let now = date(2026, 6, 19, 8, 0) // vendredi 08:00, 07:00 déjà passé
        let fire = AlarmScheduler.nextFireDate(hour: 7, minute: 0, weekdays: [], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 20, 7, 0)) // samedi
    }

    func testWeekdaysMonToFriFromFridayBeforeFire() {
        let now = date(2026, 6, 19, 6, 0) // vendredi, lun-ven = {2,3,4,5,6}
        let fire = AlarmScheduler.nextFireDate(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 19, 7, 0)) // vendredi même jour
    }

    func testWeekdaysMonToFriFromFridayAfterFireSkipsWeekend() {
        let now = date(2026, 6, 19, 8, 0) // vendredi après 07:00 → prochain = lundi
        let fire = AlarmScheduler.nextFireDate(hour: 7, minute: 0, weekdays: [2, 3, 4, 5, 6], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 22, 7, 0)) // lundi
    }

    func testWeekdaysSundayOnly() {
        let now = date(2026, 6, 19, 6, 0) // vendredi → prochain dimanche (weekday 1)
        let fire = AlarmScheduler.nextFireDate(hour: 9, minute: 30, weekdays: [1], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 21, 9, 30)) // dimanche
    }

    func testWeekdayTomorrow() {
        let now = date(2026, 6, 19, 6, 0) // vendredi → samedi (weekday 7)
        let fire = AlarmScheduler.nextFireDate(hour: 7, minute: 0, weekdays: [7], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 20, 7, 0)) // samedi
    }

    func testTodayActiveButTimePassedPicksNextWeek() {
        let now = date(2026, 6, 19, 8, 0) // vendredi 08:00, seul jour actif = vendredi, 07:00 passé
        let fire = AlarmScheduler.nextFireDate(hour: 7, minute: 0, weekdays: [6], from: now, calendar: calendar)
        XCTAssertEqual(fire, date(2026, 6, 26, 7, 0)) // vendredi suivant
    }

    func testInvalidHourReturnsNil() {
        let now = date(2026, 6, 19, 6, 0)
        XCTAssertNil(AlarmScheduler.nextFireDate(hour: 24, minute: 0, weekdays: [], from: now, calendar: calendar))
    }
}
