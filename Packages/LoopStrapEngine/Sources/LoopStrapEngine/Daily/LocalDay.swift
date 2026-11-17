import Foundation

// MARK: - Local calendar day policy

/// Calendar-day arithmetic for the "local day" policy shared by every layer (sleep night
/// attribution, daily strain, stress, workouts, "today", cache keys and fingerprints).
///
/// A day key is an ISO "YYYY-MM-DD" string. It names a calendar date, never an instant, so
/// adding days is pure Gregorian arithmetic and does not depend on any time zone.
public enum LocalDay {
    private static let utc = TimeZone(secondsFromGMT: 0)!

    private static func gregorian(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    /// Calendar date of `ts` (Unix seconds) in `zone`.
    public static func key(_ ts: Double, in zone: TimeZone) -> String {
        let comps = gregorian(zone).dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
    }

    /// Parses a strict "YYYY-MM-DD" key.
    public static func components(_ day: String) -> (year: Int, month: Int, day: Int)? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        // Reject impossible dates such as 2026-02-30.
        guard adding(0, toValid: (y, m, d)) == String(format: "%04d-%02d-%02d", y, m, d) else { return nil }
        return (y, m, d)
    }

    private static func adding(_ n: Int, toValid c: (Int, Int, Int)) -> String? {
        let cal = gregorian(utc)
        guard let base = cal.date(from: DateComponents(year: c.0, month: c.1, day: c.2, hour: 12)),
              let shifted = cal.date(byAdding: .day, value: n, to: base) else { return nil }
        return key(shifted.timeIntervalSince1970, in: utc)
    }

    /// `day` shifted by `n` calendar days. Returns `day` unchanged when it is not a valid key.
    public static func adding(_ n: Int, to day: String) -> String {
        guard let c = components(day) else { return day }
        return adding(n, toValid: (c.year, c.month, c.day)) ?? day
    }

    /// First instant (Unix seconds) of `day` in `zone`. DST-aware: a day may last 23 h or 25 h,
    /// and a zone whose midnight is skipped starts at the first valid local time.
    public static func start(_ day: String, in zone: TimeZone) -> Int? {
        guard let c = components(day) else { return nil }
        let cal = gregorian(zone)
        guard let noon = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)) else { return nil }
        return Int(cal.startOfDay(for: noon).timeIntervalSince1970)
    }

    /// The device zone, re-read on every call so a change in Settings or a trip is observed.
    public static var deviceZone: TimeZone {
        TimeZone(identifier: TimeZone.autoupdatingCurrent.identifier) ?? TimeZone.current
    }
}

// MARK: - Day schedule

/// Contiguous partition of time into local days, each with its own time zone.
///
/// - Today and future days use `currentZone`.
/// - A past day keeps the zone recorded when it was computed (`frozen`), so travelling or a
///   change of device zone never silently moves an already computed day.
/// - Day `D` starts where day `D-1` ends: at midnight of `D` in the zone of `D-1` (or of `D`
///   when `D-1` has no known zone) and ends at midnight of `D+1` in its own zone. Days therefore
///   never overlap nor leave gaps; a travel day may be shorter or longer than 24 h.
public struct LocalDaySchedule: Sendable, Equatable {
    public let currentZone: TimeZone
    public let frozen: [String: String]
    public let today: String

    public init(currentZone: TimeZone, frozen: [String: String] = [:], now: Date) {
        self.currentZone = currentZone
        self.today = LocalDay.key(now.timeIntervalSince1970, in: currentZone)
        self.frozen = frozen
    }

    /// Zone recorded for a past day, or the current zone for today and later days.
    private func explicitZone(_ day: String) -> TimeZone? {
        if day >= today { return currentZone }
        return frozen[day].flatMap(TimeZone.init(identifier:))
    }

    /// Zone that defines the end of `day` (and the start of the next day).
    public func zone(for day: String) -> TimeZone {
        explicitZone(day) ?? currentZone
    }

    public func zoneIdentifier(for day: String) -> String { zone(for: day).identifier }

    /// First second of `day`.
    public func start(of day: String) -> Int {
        let previous = LocalDay.adding(-1, to: day)
        let boundaryZone = explicitZone(previous) ?? zone(for: day)
        return LocalDay.start(day, in: boundaryZone) ?? 0
    }

    /// `[from, to]` in Unix seconds, `to` inclusive (= next day's start - 1), matching the
    /// historical `dayBounds` contract. A zero-length travel day yields `to == from - 1`.
    public func bounds(_ day: String) -> (from: Int, to: Int) {
        let from = start(of: day)
        let next = start(of: LocalDay.adding(1, to: day))
        return (from, max(from, next) - 1)
    }

    /// Local day containing `ts`.
    public func day(containing ts: Double) -> String {
        let guess = LocalDay.key(ts, in: currentZone)
        for offset in [0, -1, 1, -2, 2] {
            let candidate = LocalDay.adding(offset, to: guess)
            let b = bounds(candidate)
            if ts >= Double(b.from) && ts < Double(b.to) + 1 { return candidate }
        }
        return guess
    }

    /// `count` consecutive day keys ending today, oldest first.
    public func days(count: Int) -> [String] {
        guard count > 0 else { return [] }
        return (0..<count).reversed().map { LocalDay.adding(-$0, to: today) }
    }

    /// Zones to persist for `days`, merged over the previous registry. Entries older than
    /// `keepDays` before today are dropped to keep the cache bounded.
    public func registry(recording days: [String], keepDays: Int = 400) -> [String: String] {
        var out = frozen
        for day in days { out[day] = zoneIdentifier(for: day) }
        let oldest = LocalDay.adding(-keepDays, to: today)
        return out.filter { $0.key >= oldest }
    }

    /// UTC calendar days intersecting `[from, to]`, used to map per-UTC-day input revisions
    /// (stored by SQLite triggers) onto local days without rewriting the store.
    public static func utcDays(from: Int, to: Int) -> [String] {
        guard to >= from else { return [] }
        let utc = TimeZone(secondsFromGMT: 0)!
        let first = LocalDay.key(Double(from), in: utc)
        let last = LocalDay.key(Double(to), in: utc)
        var out = [first]
        var day = first
        while day < last && out.count < 8 {
            day = LocalDay.adding(1, to: day)
            out.append(day)
        }
        return out
    }
}
