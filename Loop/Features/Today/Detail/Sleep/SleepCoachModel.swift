import SwiftUI

// MARK: - SleepCoachModel

/// Derives every value the sleep-detail UI renders from a `DailySnapshot` (plus an
/// optional matching `SleepSession` and a sliding history window for sleep debt).
/// Kept free of view code so components stay dumb and previewable. The page's single
/// accent comes from `band`; everything else renders monochrome.
struct SleepCoachModel {
    let metric: DailySnapshot
    let session: SleepSession?
    /// Recent days (any order) used to accumulate the rolling 7-day sleep debt. The
    /// current day is matched out of this list, so passing the full cache is fine.
    let history: [DailySnapshot]

    /// Real per-epoch stages decoded from `session?.stages` once at init, or nil when
    /// no session/stages are available or the payload is undecodable. No chart is invented.
    private let realSegments: [DecodedStageSegment]?

    init(metric: DailySnapshot, session: SleepSession? = nil, history: [DailySnapshot] = []) {
        self.metric = metric
        self.session = session
        self.history = history
        self.realSegments = Self.decodeStages(session?.stages)
    }

    /// True when a real per-epoch hypnogram is available for the selected night.
    var hasRealStages: Bool { realSegments != nil }

    // MARK: - Score & band

    var score: Int {
        let value = normalizedScore(metric.sleepScore)
            ?? durationScore
            ?? normalizedScore(metric.efficiency)
            ?? 0
        return Int(value.rounded())
    }

    /// The page's one accent. Driven by the score, never by decoration.
    var band: SleepBand { SleepBand(score: score) }

    var headline: String {
        if score >= 85 { return String(localized: "today.tres.bonne.nuit.garde.le.rythme", table: "Today") }
        if score >= 70 { return String(localized: "today.bonne.base.un.levier.a.corriger", table: "Today") }
        if score >= 55 { return String(localized: "today.nuit.utile.dette.pas.totalement.payee", table: "Today") }
        return String(localized: "today.ta.dette.de.recuperation.monte", table: "Today")
    }

    var qualityLabel: String {
        if score >= 85 { return "Excellent" }
        if score >= 70 { return String(localized: "today.bon", table: "Today") }
        if score >= 55 { return "Correct" }
        return String(localized: "today.a.ameliorer", table: "Today")
    }

    /// Prose for the "ce que ça veut dire" inset under the drivers.
    var simpleSummary: String {
        if durationGapMinutes > 45 {
            return TodayL.text("today.sleep.insight.short")
        }
        if (metric.disturbances ?? 0) >= 6 {
            return TodayL.text("today.sleep.insight.fragmented")
        }
        if score >= 85 {
            return TodayL.text("today.sleep.insight.good")
        }
        return TodayL.text("today.sleep.insight.moderate")
    }

    // MARK: - Duration (foregrounded metric)

    var sleepDurationText: String { formatDuration(metric.totalSleepMin) }
    var sleepNeedText: String { formatDuration(metric.sleepTargetMin) }

    var durationGapMinutes: Double {
        guard let target = metric.sleepTargetMin, let total = metric.totalSleepMin else { return 0 }
        return target - total
    }

    /// `true` only when the deficit is large enough to warrant a warning tint.
    var durationWarning: Bool { durationGapMinutes > 45 }

    /// Fill fraction for the WHOOP-style duration bar, allowed to overshoot the
    /// target (clamped to 1.5) so over-sleep reads as "past the tick".
    var durationFraction: Double {
        guard let target = metric.sleepTargetMin, target > 0, let total = metric.totalSleepMin else { return 0 }
        return min(max(total / target, 0), 1.5)
    }

    var durationCaptionText: String {
        let gap = durationGapMinutes
        if abs(gap) < 5 { return TodayL.text("today.sleep.target.exact") }
        if gap > 0 { return "−\(formatShortDuration(gap)) vs objectif" }
        return "+\(formatShortDuration(-gap)) vs objectif"
    }

    // MARK: - Secondary facts

    var deepText: String { formatDuration(metric.deepMin) }
    var remText: String { formatDuration(metric.remMin) }
    var lightText: String { formatDuration(metric.lightMin) }

    var deepFraction: Double { stageFraction(metric.deepMin) }
    var remFraction: Double { stageFraction(metric.remMin) }
    var lightFraction: Double { stageFraction(metric.lightMin) }

    var totalStageMinutes: Double {
        [metric.lightMin, metric.deepMin, metric.remMin].compactMap { $0 }.reduce(0, +)
    }

    /// Awake minutes summed from the hypnogram when available, else nil.
    var awakeText: String {
        let minutes = ribbonSegments.filter { $0.stage == .awake }.reduce(0) { $0 + $1.durationMinutes }
        guard minutes > 0 else { return "—" }
        return "\(minutes) min"
    }

    var efficiencyText: String {
        guard let value = normalizedScore(metric.efficiency ?? session?.efficiency), value > 0 else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    var restingHrText: String {
        if let hr = session?.restingHr { return "\(hr) bpm" }
        if let hr = metric.restingHR, hr.isFinite, hr > 0 { return "\(Int(hr.rounded())) bpm" }
        return "—"
    }

    var avgHrvText: String {
        if let hrv = session?.avgHrv ?? metric.avgHrv, hrv.isFinite, hrv > 0 {
            return "\(Int(hrv.rounded())) ms"
        }
        return "—"
    }

    /// Sleep latency: time from the night's start to the first deep segment. Only
    /// meaningful with a real hypnogram, else "—".
    var latencyText: String {
        guard hasRealStages,
              let first = ribbonSegments.first,
              let firstDeep = ribbonSegments.first(where: { $0.stage == .deep }) else { return "—" }
        let minutes = max(Int(firstDeep.from.timeIntervalSince(first.from) / 60), 0)
        return "\(minutes) min"
    }

    // MARK: - Sleep debt & tonight plan

    /// Rolling deficit over the last 7 recorded days ending on the selected day:
    /// Σ(target − total). Positive = accumulated debt, negative/zero = caught up.
    var sleepDebt7d: Double {
        let window = history
            .filter { $0.date <= metric.date }
            .sorted { $0.date > $1.date }
            .prefix(7)
        return window.reduce(0.0) { acc, day in
            guard let target = day.sleepTargetMin, let total = day.totalSleepMin else { return acc }
            return acc + (target - total)
        }
    }

    var sleepNeededTonight: Double {
        let target = metric.sleepTargetMin ?? 480
        return target + max(0, sleepDebt7d / 4)
    }

    var debtText: String {
        let debt = sleepDebt7d
        if debt <= 5 { return String(localized: "today.dette.a.jour", table: "Today") }
        return "Dette : −\(formatShortDuration(debt))"
    }

    var neededText: String {
        "Besoin ce soir : \(formatDuration(sleepNeededTonight))"
    }

    /// Prescriptive bed time = wake target − tonight's need − a small wind-down buffer.
    var bedtimeText: String {
        let buffer: Double = durationGapMinutes > 20 ? 28 : 18
        let bed = Self.wakeReference.addingTimeInterval(-(sleepNeededTonight + buffer) * 60)
        return Self.timeFormatter.string(from: bed)
    }

    var wakeText: String {
        Self.timeFormatter.string(from: Self.wakeReference)
    }

    /// Today's target wake `Date`, read straight from UserDefaults so the model stays
    /// nonisolated (the `UserPreferences` class is `@MainActor`). Falls back to 07:00.
    private static var wakeReference: Date {
        let defaults = UserDefaults.standard
        let hour = defaults.object(forKey: "userPreferences.wakeHour") as? Int ?? 7
        let minute = defaults.object(forKey: "userPreferences.wakeMinute") as? Int ?? 0
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    var coachingMessage: String {
        if durationGapMinutes > 45 {
            return TodayL.text("today.sleep.plan.duration")
        }
        if (metric.disturbances ?? 0) >= 6 {
            return TodayL.text("today.sleep.plan.fragmented")
        }
        if let efficiency = normalizedScore(metric.efficiency), efficiency < 85 {
            return TodayL.text("today.sleep.plan.efficiency")
        }
        return TodayL.text("today.sleep.plan.good")
    }

    // MARK: - Drivers (why this score)

    var drivers: [SleepDriver] {
        [durationDriver, efficiencyDriver, disturbanceDriver]
    }

    /// One-line dominant driver for the disclosure header.
    var dominantDriverSummary: String {
        if durationGapMinutes > 45 { return TodayL.format("today.final.sleep.missing.duration", formatShortDuration(durationGapMinutes)) }
        if (metric.disturbances ?? 0) >= 6 { return TodayL.format("today.final.sleep.awakenings", String(metric.disturbances ?? 0)) }
        if let efficiency = normalizedScore(metric.efficiency), efficiency < 85 {
            return TodayL.format("today.final.sleep.percent", String(Int(efficiency.rounded())))
        }
        return String(localized: "today.duree.equilibree", table: "Today")
    }

    var stageRows: [SleepStageRow] {
        [
            SleepStageRow(stage: .deep, minutes: metric.deepMin ?? 0),
            SleepStageRow(stage: .rem, minutes: metric.remMin ?? 0),
            SleepStageRow(stage: .light, minutes: metric.lightMin ?? 0)
        ]
    }

    /// Absolute-timeline segments for the hypnogram. With real stages, each decoded
    /// segment keeps its true bounds. Without stage data the chart remains empty.
    var ribbonSegments: [SleepRibbonSegment] {
        if let real = realSegments {
            return real.enumerated().map { index, segment in
                SleepRibbonSegment(id: index, stage: segment.stage, from: segment.start, to: segment.end)
            }
        }
        // A duration without stages cannot justify an invented hypnogram.
        return []
    }

    var ribbonTimeRange: String {
        guard let first = ribbonSegments.first, let last = ribbonSegments.last else { return "" }
        return "\(Self.timeFormatter.string(from: first.from)) - \(Self.timeFormatter.string(from: last.to))"
    }

    private var estimatedRibbonSegments: [SleepRibbonSegment] {
        let raw = SleepStageSegment.makeEstimatedSegments(
            lightMinutes: metric.lightMin ?? 240,
            deepMinutes: metric.deepMin ?? 85,
            remMinutes: metric.remMin ?? 95,
            disturbanceCount: metric.disturbances ?? 3
        )
        let totalMinutes = raw.reduce(0) { $0 + $1.minutes }
        let start = Self.wakeReference.addingTimeInterval(-totalMinutes * 60)

        var cursor = start
        return raw.enumerated().map { index, segment in
            let end = cursor.addingTimeInterval(segment.minutes * 60)
            defer { cursor = end }
            return SleepRibbonSegment(id: index, stage: segment.stage, from: cursor, to: end)
        }
    }

    // MARK: - Private helpers

    private var durationScore: Double? {
        guard let total = metric.totalSleepMin, let target = metric.sleepTargetMin, target > 0 else { return nil }
        return min(max((total / target) * 100, 0), 100)
    }

    private var durationDriver: SleepDriver {
        let over = durationGapMinutes > 45
        return SleepDriver(
            title: over ? TodayL.text("today.sleep.driver.debt") : TodayL.text("today.sleep.driver.duration"),
            message: over
                ? TodayL.format("today.sleep.driver.missing", formatShortDuration(durationGapMinutes))
                : TodayL.format("today.sleep.driver.met", sleepDurationText, sleepNeedText),
            systemImage: over ? "clock.badge.exclamationmark" : "clock.fill",
            weight: 0.5
        )
    }

    private var efficiencyDriver: SleepDriver {
        let efficiency = normalizedScore(metric.efficiency) ?? 0
        return SleepDriver(
            title: String(localized: "today.efficacite", table: "Today"),
            message: efficiency > 0
                ? TodayL.format("today.sleep.driver.efficiency", String(Int(efficiency.rounded())))
                : TodayL.text("today.pas.encore.de.signal.d.efficacite"),
            systemImage: "gauge.with.dots.needle.67percent",
            weight: 0.3
        )
    }

    private var disturbanceDriver: SleepDriver {
        let count = metric.disturbances ?? 0
        let calm = count <= 3
        return SleepDriver(
            title: calm ? TodayL.text("today.sleep.driver.continuity") : TodayL.text("today.sleep.driver.fragmentation"),
            message: calm ? TodayL.format("today.sleep.driver.calm", String(count)) : TodayL.format("today.sleep.driver.disturbed", String(count)),
            systemImage: calm ? "waveform" : "waveform.badge.exclamationmark",
            weight: 0.2
        )
    }

    private func stageFraction(_ minutes: Double?) -> Double {
        guard let minutes, totalStageMinutes > 0 else { return 0 }
        return min(max(minutes / totalStageMinutes, 0), 1)
    }

    private func normalizedScore(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if value <= 1 { return min(max(value * 100, 0), 100) }
        return min(max(value, 0), 100)
    }

    private func formatDuration(_ minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes > 0 else { return "--" }
        let rounded = Int(minutes.rounded())
        return "\(rounded / 60)h \(String(format: "%02d", rounded % 60))m"
    }

    private func formatShortDuration(_ minutes: Double) -> String {
        let rounded = max(Int(minutes.rounded()), 0)
        if rounded >= 60 { return "\(rounded / 60)h \(String(format: "%02d", rounded % 60))" }
        return "\(rounded)m"
    }

    /// Decode the server's `[{start,end,stage}]` JSON (epoch seconds + lowercase stage
    /// names) into typed segments. Any failure yields nil → estimated fallback.
    private static func decodeStages(_ data: Data?) -> [DecodedStageSegment]? {
        guard let data,
              let dtos = try? JSONDecoder().decode([StageDTO].self, from: data),
              !dtos.isEmpty else { return nil }
        let mapped = dtos.compactMap { dto -> DecodedStageSegment? in
            guard let stage = SleepStage(serverName: dto.stage) else { return nil }
            return DecodedStageSegment(
                start: Date(timeIntervalSince1970: dto.start),
                end: Date(timeIntervalSince1970: dto.end),
                stage: stage
            )
        }
        return mapped.isEmpty ? nil : mapped
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Supporting value types

struct SleepDriver: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let systemImage: String
    /// Rough share of the score this driver carries — drives the contribution bar.
    let weight: Double
}

struct SleepStageRow: Identifiable {
    let id = UUID()
    let stage: SleepStage
    let minutes: Double

    var durationText: String {
        let rounded = Int(minutes.rounded())
        return "\(rounded / 60)h \(String(format: "%02d", rounded % 60))m"
    }
}

/// A segment placed on an absolute timeline, consumed by the hypnogram chart.
struct SleepRibbonSegment: Identifiable {
    let id: Int
    let stage: SleepStage
    let from: Date
    let to: Date

    var durationMinutes: Int { max(Int(to.timeIntervalSince(from) / 60), 0) }
}

struct SleepStageSegment: Identifiable {
    let id = UUID()
    let stage: SleepStage
    let minutes: Double

    static func makeEstimatedSegments(
        lightMinutes: Double,
        deepMinutes: Double,
        remMinutes: Double,
        disturbanceCount: Int
    ) -> [SleepStageSegment] {
        let wakes = max(2, min(disturbanceCount, 6))
        let deepUnit = max(deepMinutes / 3, 8)
        let remUnit = max(remMinutes / 4, 10)
        let lightUnit = max(lightMinutes / 8, 12)

        var segments: [SleepStageSegment] = [
            SleepStageSegment(stage: .awake, minutes: 7),
            SleepStageSegment(stage: .light, minutes: lightUnit),
            SleepStageSegment(stage: .deep, minutes: deepUnit * 1.15),
            SleepStageSegment(stage: .light, minutes: lightUnit * 1.2),
            SleepStageSegment(stage: .deep, minutes: deepUnit),
            SleepStageSegment(stage: .light, minutes: lightUnit),
            SleepStageSegment(stage: .rem, minutes: remUnit * 0.8),
            SleepStageSegment(stage: .light, minutes: lightUnit),
            SleepStageSegment(stage: .deep, minutes: deepUnit * 0.85),
            SleepStageSegment(stage: .light, minutes: lightUnit * 1.2),
            SleepStageSegment(stage: .rem, minutes: remUnit),
            SleepStageSegment(stage: .light, minutes: lightUnit),
            SleepStageSegment(stage: .rem, minutes: remUnit * 1.15),
            SleepStageSegment(stage: .light, minutes: lightUnit),
            SleepStageSegment(stage: .rem, minutes: remUnit * 1.05),
            SleepStageSegment(stage: .awake, minutes: 6)
        ]

        for index in 0..<wakes {
            let insertion = min(3 + index * 3, max(segments.count - 2, 1))
            segments.insert(SleepStageSegment(stage: .awake, minutes: 3), at: insertion)
        }

        return segments
    }
}

/// Wire shape of one element of `SleepSession.stages`: `{start, end, stage}` with
/// epoch-second bounds and a lowercase server stage name.
private struct StageDTO: Decodable {
    let start: Double
    let end: Double
    let stage: String
}

/// A real per-epoch stage segment decoded onto an absolute timeline.
struct DecodedStageSegment {
    let start: Date
    let end: Date
    let stage: SleepStage
}

enum SleepStage: CaseIterable, Identifiable {
    case awake
    case light
    case rem
    case deep

    /// Map a server stage name ("wake"|"light"|"deep"|"rem") to a case. Unknown names
    /// return nil so they can be filtered out of a decoded hypnogram.
    init?(serverName: String) {
        switch serverName {
        case "wake": self = .awake
        case "light": self = .light
        case "deep": self = .deep
        case "rem": self = .rem
        default: return nil
        }
    }

    var id: String { title }

    /// Top-to-bottom row order of the hypnogram, matching Apple Health
    /// (Awake on top, Deep at the bottom).
    static var ribbonRows: [SleepStage] { [.awake, .rem, .light, .deep] }

    var rowIndex: Int {
        switch self {
        case .awake: return 0
        case .rem: return 1
        case .light: return 2
        case .deep: return 3
        }
    }

    var title: String {
        switch self {
        case .awake: return String(localized: "today.eveil", table: "Today")
        case .light: return String(localized: "today.leger", table: "Today")
        case .rem: return "REM"
        case .deep: return "Profond"
        }
    }

    /// Monochrome ink shades — stages are differentiated by their row position, not
    /// by hue (DESIGN.md: one accent per page, no rainbow).
    var color: Color {
        switch self {
        case .awake: return .primary.opacity(0.35)
        case .rem: return .primary.opacity(0.55)
        case .light: return .primary.opacity(0.78)
        case .deep: return .primary
        }
    }
}
