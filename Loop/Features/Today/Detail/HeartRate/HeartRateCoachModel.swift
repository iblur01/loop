import SwiftUI
import LoopStrapEngine

/// Pure-logic model behind the heart-rate page. Turns raw BLE HR samples plus the daily
/// snapshots into the figures the UI reads: range stats, a resting baseline and its trend,
/// and the engine's heart-rate zone breakdown (read as is, never recomputed). Value type, unit-testable, no view state.
struct HeartRateCoachModel {

    enum Range: String, CaseIterable, Identifiable {
        case sixHours = "6 h"
        case day      = "24 h"
        case threeDays = "3 j"
        case week      = "7 j"

        var id: String { rawValue }

        var seconds: TimeInterval {
            switch self {
            case .sixHours:  return 6 * 3600
            case .day:       return 24 * 3600
            case .threeDays: return 3 * 24 * 3600
            case .week:      return 7 * 24 * 3600
            }
        }
    }

    let samples: [HeartRateSample]
    let metrics: [DailySnapshot]
    let range: Range

    init(samples: [HeartRateSample], metrics: [DailySnapshot], range: Range) {
        self.samples = samples.sorted { $0.ts < $1.ts }
        self.metrics = metrics.sorted { $0.date < $1.date }
        self.range = range
    }

    var accent: Color { Pop.red }

    // MARK: - Range window

    private var cutoffTs: Int {
        Int(Date().addingTimeInterval(-range.seconds).timeIntervalSince1970)
    }

    var visibleSamples: [HeartRateSample] {
        samples.filter { $0.ts >= cutoffTs }
    }

    struct ChartSegment: Identifiable {
        let id: Int
        let samples: [HeartRateSample]
    }

    /// Keep the extrema in each time bucket while breaking the line at missing-data gaps.
    /// The complete series remains available for the figures and selection.
    static func chartSegments(_ samples: [HeartRateSample], bucketSeconds: Int, gapSeconds: Int = 300) -> [ChartSegment] {
        guard !samples.isEmpty else { return [] }
        var segments: [ChartSegment] = []
        var points: [HeartRateSample] = []
        var bucket: [HeartRateSample] = []
        var previous: HeartRateSample?
        func flushBucket() {
            guard let first = bucket.first, let last = bucket.last,
                  let low = bucket.min(by: { $0.bpm < $1.bpm }),
                  let high = bucket.max(by: { $0.bpm < $1.bpm }) else { return }
            var seen = Set<Int>()
            points.append(contentsOf: [first, low, high, last].sorted { $0.ts < $1.ts }.filter { seen.insert($0.ts).inserted })
            bucket.removeAll(keepingCapacity: true)
        }
        for sample in samples {
            if let previous {
                if sample.ts - previous.ts > gapSeconds {
                    flushBucket()
                    if !points.isEmpty { segments.append(ChartSegment(id: segments.count, samples: points)) }
                    points = []
                } else if sample.ts / bucketSeconds != previous.ts / bucketSeconds {
                    flushBucket()
                }
            }
            bucket.append(sample)
            previous = sample
        }
        flushBucket()
        if !points.isEmpty { segments.append(ChartSegment(id: segments.count, samples: points)) }
        return segments
    }

    var hasData: Bool { visibleSamples.count >= 2 }

    // MARK: - Range stats

    var latestBpm: Int? { visibleSamples.last?.bpm ?? samples.last?.bpm }
    var latestTs: Int? { visibleSamples.last?.ts ?? samples.last?.ts }

    var avgBpm: Int? {
        let v = visibleSamples.map(\.bpm)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / v.count
    }
    var minBpm: Int? { visibleSamples.map(\.bpm).min() }
    var maxBpm: Int? { visibleSamples.map(\.bpm).max() }
    var amplitudeBpm: Int? {
        guard let lo = minBpm, let hi = maxBpm else { return nil }
        return hi - lo
    }

    // MARK: - Resting baseline

    /// Resting HR from the latest daily snapshot that has one, falling back to the 5th
    /// percentile of all cached samples (a robust stand-in for the nightly floor).
    var restingBpm: Int? {
        if let r = metrics.reversed().compactMap(\.restingHR).first, r.isFinite {
            return Int(r.rounded())
        }
        return percentile(0.05, of: samples.map(\.bpm))
    }

    // MARK: - Zone distribution (engine)

    /// Latest day whose snapshot carries engine zone minutes (daily load window). The view never
    /// computes a zone: minutes, bounds and references all come from LoopStrapEngine.
    private var zonesSnapshot: DailySnapshot? {
        metrics.last { $0.heartRateZones != nil }
    }

    var zones: HeartRateZoneBreakdown? { zonesSnapshot?.heartRateZones }
    var zonesDate: String? { zonesSnapshot?.date }

    /// Minutes in zones 1 to 5 (the active time): the base of every zone share. The time below
    /// zone 1 (rest, low intensity) is reported apart, never as a share of the day.
    var activeZoneMinutes: Double { zones?.zoneMinutes.reduce(0, +) ?? 0 }

    /// Minutes below zone 1 (rest or low intensity), nil without engine data.
    var belowZoneMinutes: Double? { zones?.belowZoneMinutes }

    /// Share (of the active minutes) and minutes of zones 1…5; empty without active time.
    var zoneDistribution: [(zone: HeartRateZone, fraction: Double, minutes: Double)] {
        guard let zones, activeZoneMinutes > 0 else { return [] }
        return HeartRateZone.allCases.filter { $0 != .below }.map { z in
            let m = zones.zoneMinutes[z.rawValue - 1]
            return (z, m / activeZoneMinutes, m)
        }
    }

    var dominantZone: HeartRateZone? {
        zoneDistribution.filter { $0.minutes > 0 }.max { $0.fraction < $1.fraction }?.zone
    }

    // MARK: - Resting trend

    struct RestingPoint: Identifiable {
        let id = UUID()
        let date: String
        let bpm: Double
        let isToday: Bool
    }

    /// Last 14 days of resting HR for the trend chart.
    var restingSeries: [RestingPoint] {
        let recent = metrics.suffix(14)
        let lastDate = recent.last?.date
        return recent.compactMap { m in
            guard let r = m.restingHR, r.isFinite else { return nil }
            return RestingPoint(date: m.date, bpm: r, isToday: m.date == lastDate)
        }
    }

    /// Resting HR delta vs the prior week (negative = lower = better recovery).
    var restingWeeklyDelta: Double? {
        let series = restingSeries
        guard series.count >= 4 else { return nil }
        let recent = Array(series.suffix(7))
        let prior = Array(series.dropLast(7).suffix(7))
        guard !recent.isEmpty, !prior.isEmpty else { return nil }
        let r = recent.map(\.bpm).reduce(0, +) / Double(recent.count)
        let p = prior.map(\.bpm).reduce(0, +) / Double(prior.count)
        return r - p
    }

    var restingTrendText: String {
        guard let d = restingWeeklyDelta else { return String(localized: "today.pas.encore.de.tendance", table: "Today") }
        let rounded = (d * 10).rounded() / 10
        if abs(rounded) < 0.5 { return String(localized: "today.stable.vs.semaine.passee", table: "Today") }
        let arrow = rounded < 0 ? "en baisse" : "en hausse"
        let sense = rounded < 0 ? " — bon signe" : ""
        return "FC repos \(arrow) de \(String(format: "%.0f", abs(rounded))) bpm\(sense)"
    }

    // MARK: - Narrative

    var contextLabel: String {
        guard let latest = latestBpm else { return TodayL.text("today.hr.none") }
        // Zone of the latest beat under the engine's references and bounds (none estimated here).
        guard let zones,
              let z = HeartRateZoneBreakdown.zone(forBpm: Double(latest), restingHR: zones.restingHR,
                                                  maxHR: zones.maxHR) else { return String(localized: "today.mesure.recente", table: "Today") }
        switch z {
        case 0:  return TodayL.text("today.hr.resting")
        case 1:  return String(localized: "today.legerement.elevee", table: "Today")
        case 2:  return String(localized: "today.moderee", table: "Today")
        case 3:  return TodayL.text("today.hr.sustained")
        case 4:  return "Intense"
        default: return TodayL.text("today.hr.maximum")
        }
    }

    var headline: String {
        guard let latest = latestBpm, let rest = restingBpm else {
            return String(localized: "today.pas.encore.assez.de.mesures.sur.cette.plage", table: "Today")
        }
        let above = latest - rest
        if above <= 5 { return TodayL.format("today.hr.rest.near", String(rest)) }
        if above <= 20 { return TodayL.format("today.hr.rest.light", String(above)) }
        return TodayL.format("today.hr.rest.effort", String(above))
    }

    var latestTimeText: String {
        guard let ts = latestTs else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - Helpers

    private func percentile(_ p: Double, of values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[Swift.max(0, Swift.min(sorted.count - 1, idx))]
    }
}
