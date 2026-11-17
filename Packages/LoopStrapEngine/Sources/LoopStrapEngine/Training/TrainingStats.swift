import Foundation

// MARK: - Report types

public enum TrendDirection: String, Codable, Sendable, Hashable {
    case up
    case down
    case stable
}

public enum TrainingDataStatus: String, Codable, Sendable, Hashable {
    case ok
    case insufficientData
}

/// Weekly volume and intensity for one sport. Weeks are Monday-based (`TrainingCalendar`).
public struct WeeklySportVolume: Codable, Equatable, Sendable {
    public let weekIndex: Int
    public let weekStartDay: Int
    public let sport: TrainingSport
    public let sessionCount: Int
    public let activeDays: Int
    /// Sessions whose duration is known (and counted in `totalMinutes`).
    public let sessionsWithDuration: Int
    /// Sum of known durations; `nil` when no session has a known duration.
    public let totalMinutes: Double?
    /// Sum of session cardio loads. `nil` for swim and strength (no heart-rate claim) or when absent.
    public let cardioLoadSum: Double?
    /// Cardio load per hour over sessions having both load and duration. `nil` for swim/strength.
    public let cardioLoadPerHour: Double?
    /// Mean perceived exertion (0...10) over sessions that provide it.
    public let meanPerceivedExertion: Double?
    /// Sum of sRPE x duration over sessions that provide both (arbitrary units).
    public let srpeLoadSum: Double?
    /// True when the whole week lies on or before `asOfDay`.
    public let isComplete: Bool
}

public struct RegularityStats: Codable, Equatable, Sendable {
    public let status: TrainingDataStatus
    public let windowDays: Int
    /// Days of the window already covered by the data history (from the first known data day).
    public let trackedDays: Int
    public let activeDays: Int
    public let activeShare: Double?
    /// Days between consecutive active days (>= 1), oldest first.
    public let intervals: [Int]
    public let meanInterval: Double?
    public let maxInterval: Int?
    public let intervalStdDev: Double?
    /// Days since the last session ever recorded (not limited to the window).
    public let daysSinceLastSession: Int?
}

public enum LoadRatioStatus: String, Codable, Sendable, Hashable {
    case noData
    /// Fewer than `LoadStats.requiredDays` days of data: "calibration".
    case calibration
    case noRecentData
    case chronicNearZero
    case available
}

public struct LoadStats: Codable, Equatable, Sendable {
    public static let acuteDays = 7
    public static let chronicDays = 28
    public static let requiredDays = 21

    public let status: LoadRatioStatus
    public let acuteEWMA: Double?
    public let chronicEWMA: Double?
    /// Only set when `status == .available`.
    public let ratio: Double?
    /// Days with a known load within the last `chronicDays` days.
    public let dataDays: Int
    public let daysSinceLastLoad: Int?
    /// Share of loads (within the chronic window) whose confidence is `.low`; `nil` if none carry a confidence.
    public let lowConfidenceShare: Double?
}

public enum MonotonyStatus: String, Codable, Sendable, Hashable {
    case insufficientData
    /// All known days identical: standard deviation is 0, monotony undefined.
    case undefined
    case ok
}

public struct MonotonyStats: Codable, Equatable, Sendable {
    public static let windowDays = 7
    public static let minimumKnownDays = 5

    public let status: MonotonyStatus
    public let knownDays: Int
    public let meanLoad: Double?
    public let standardDeviation: Double?
    /// mean / standard deviation over the known days of the window.
    public let monotony: Double?
    /// standard deviation / mean (relative variation).
    public let coefficientOfVariation: Double?
}

public struct TrendStat: Codable, Equatable, Sendable {
    public let metric: TrainingMetric
    public let status: TrainingDataStatus
    public let recentDays: Int
    public let referenceDays: Int
    public let recentCount: Int
    public let referenceCount: Int
    public let recentMedian: Double?
    public let referenceCenter: Double?
    /// MAD used to scale the gap (own window MAD floored, or the personal reference).
    public let scaleMAD: Double?
    public let delta: Double?
    public let deltaInMAD: Double?
    public let direction: TrendDirection?
    public let confidence: TrainingConfidence
    public let usedPersonalReference: Bool
}

public enum ChangeStatus: String, Codable, Sendable, Hashable {
    case insufficientData
    case noChange
    case changeDetected
}

public struct ChangeDetection: Codable, Equatable, Sendable {
    public let metric: TrainingMetric
    public let status: ChangeStatus
    public let direction: TrendDirection?
    public let onsetDay: Int?
    public let recentCount: Int
    public let referenceCount: Int
    public let recentDays: Int
    /// Largest CUSUM statistic reached, in robust standard deviations.
    public let statistic: Double?
    public let threshold: Double
    public let confidence: TrainingConfidence
}

public enum TrainingLinkPair: String, Codable, Sendable, CaseIterable, Hashable {
    /// Daily cardio load of day d vs sleep duration of the night waking on d + 1.
    case loadToNextSleepDuration
    /// Daily cardio load of day d vs recovery score of day d + 1.
    case loadToNextRecovery
    /// Sleep duration vs recovery score, same day.
    case sleepDurationToRecovery
    /// Sleep efficiency vs recovery score, same day.
    case sleepEfficiencyToRecovery

    var involvesRecovery: Bool {
        self != .loadToNextSleepDuration
    }
}

public enum LinkStatus: String, Codable, Sendable, Hashable {
    case insufficientData
    /// Enough pairs, but a series is constant: no coefficient.
    case undefined
    case ok
}

/// Exploratory rank correlation between two series. Never a causal claim.
public struct LinkStat: Codable, Equatable, Sendable {
    public static let minimumPairs = 14
    public static let windowDays = 60
    /// Localisation key of the mandatory caveat ("corrélation exploratoire, pas une causalité").
    public static let noteKey = "training.note.exploratory_link"

    public let pair: TrainingLinkPair
    public let status: LinkStatus
    public let pairCount: Int
    public let spearman: Double?
    public let intervalLow: Double?
    public let intervalHigh: Double?
    /// -1, 0 or +1 (nil without coefficient).
    public let sign: Int?
}

public struct SleepStats: Codable, Equatable, Sendable {
    public static let windowDays = 7
    public let nights: Int
    public let medianDurationMinutes: Double?
    public let medianEfficiency: Double?
    public let medianAwakenings: Double?
    public let medianCoverage: Double?
}

public struct TrainingStatsReport: Codable, Equatable, Sendable {
    public let asOfDay: Int
    public let weeklyVolumes: [WeeklySportVolume]
    public let regularity: RegularityStats
    public let load: LoadStats
    public let monotony: MonotonyStats
    public let sleep: SleepStats
    public let trends: [TrendStat]
    public let changes: [ChangeDetection]
    public let links: [LinkStat]

    public func trend(_ metric: TrainingMetric) -> TrendStat? {
        trends.first { $0.metric == metric }
    }

    public func change(_ metric: TrainingMetric) -> ChangeDetection? {
        changes.first { $0.metric == metric }
    }

    public func link(_ pair: TrainingLinkPair) -> LinkStat? {
        links.first { $0.pair == pair }
    }
}

// MARK: - Computation

public enum TrainingStats {
    /// Deviation (in MAD) from which a gap is called notable.
    public static let notableDeviationMAD = 2.0
    public static let regularityWindowDays = 28
    public static let regularityMinimumTrackedDays = 14
    public static let weeksBack = 8

    public static func compute(_ inputs: TrainingInputs) -> TrainingStatsReport {
        compute(TrainingDataset(inputs))
    }

    static func compute(_ data: TrainingDataset) -> TrainingStatsReport {
        let asOf = data.asOfDay
        let loadSeries = data.series(.cardioLoad)
        let sleepSeries = data.series(.sleepDuration)
        let effSeries = data.series(.sleepEfficiency)
        let recSeries = data.series(.recoveryScore)

        let trends: [TrendStat] = [
            trend(metric: .cardioLoad, series: loadSeries, asOfDay: asOf, reference: data.references.cardioLoad),
            trend(metric: .sleepDuration, series: sleepSeries, asOfDay: asOf, reference: data.references.sleepDuration),
            trend(metric: .sleepEfficiency, series: effSeries, asOfDay: asOf),
            trend(metric: .recoveryScore, series: recSeries, asOfDay: asOf)
        ]
        let changes: [ChangeDetection] = [
            detectChange(metric: .cardioLoad, series: loadSeries, asOfDay: asOf),
            detectChange(metric: .sleepDuration, series: sleepSeries, asOfDay: asOf),
            detectChange(metric: .recoveryScore, series: recSeries, asOfDay: asOf)
        ]
        let links: [LinkStat] = TrainingLinkPair.allCases.map { link($0, data: data) }

        return TrainingStatsReport(
            asOfDay: asOf,
            weeklyVolumes: weeklyVolumes(data),
            regularity: regularity(data),
            load: loadStats(data),
            monotony: monotony(loadSeries, asOfDay: asOf),
            sleep: sleepStats(data),
            trends: trends,
            changes: changes,
            links: links)
    }

    // MARK: Weekly volume

    static func weeklyVolumes(_ data: TrainingDataset) -> [WeeklySportVolume] {
        let asOf = data.asOfDay
        let currentWeek = TrainingCalendar.weekIndex(forDay: asOf)
        let firstWeek = currentWeek - (weeksBack - 1)
        var groups: [String: [TrainingSession]] = [:]
        var keys: [String: (week: Int, sport: TrainingSport)] = [:]
        for s in data.sessions {
            let week = TrainingCalendar.weekIndex(forDay: s.day)
            guard week >= firstWeek, week <= currentWeek else { continue }
            let key = "\(week)|\(s.sport.rawValue)"
            groups[key, default: []].append(s)
            keys[key] = (week, s.sport)
        }
        var result: [WeeklySportVolume] = []
        for (key, sessions) in groups {
            guard let k = keys[key] else { continue }
            let durations = sessions.compactMap { $0.durationMinutes }
            let hrApplies = k.sport.usesHeartRateIntensity
            let loadSessions = sessions.filter { $0.cardioLoad != nil }
            let loadWithDuration = sessions.filter { $0.cardioLoad != nil && $0.durationMinutes != nil }
            let hours = TrainingMath.sum(loadWithDuration.compactMap { $0.durationMinutes }) / 60
            let loadForRate = TrainingMath.sum(loadWithDuration.compactMap { $0.cardioLoad })
            let rpes = sessions.compactMap { $0.perceivedExertion }
            let srpes = sessions.compactMap { $0.srpeLoad }
            let weekStart = TrainingCalendar.weekStartDay(forWeek: k.week)
            result.append(WeeklySportVolume(
                weekIndex: k.week,
                weekStartDay: weekStart,
                sport: k.sport,
                sessionCount: sessions.count,
                activeDays: Set(sessions.map { $0.day }).count,
                sessionsWithDuration: durations.count,
                totalMinutes: durations.isEmpty ? nil : TrainingMath.sum(durations),
                cardioLoadSum: hrApplies && !loadSessions.isEmpty
                    ? TrainingMath.sum(loadSessions.compactMap { $0.cardioLoad }) : nil,
                cardioLoadPerHour: hrApplies && hours > 0 ? loadForRate / hours : nil,
                meanPerceivedExertion: TrainingMath.mean(rpes),
                srpeLoadSum: srpes.isEmpty ? nil : TrainingMath.sum(srpes),
                isComplete: weekStart + 6 <= asOf))
        }
        return result.sorted {
            $0.weekIndex != $1.weekIndex ? $0.weekIndex < $1.weekIndex : $0.sport.rawValue < $1.sport.rawValue
        }
    }

    // MARK: Regularity

    static func regularity(_ data: TrainingDataset) -> RegularityStats {
        let asOf = data.asOfDay
        let windowStart = asOf - regularityWindowDays + 1
        let tracked: Int
        if let first = data.firstDay {
            tracked = max(0, asOf - max(first, windowStart) + 1)
        } else {
            tracked = 0
        }
        let activeSet = Set(data.sessions.map { $0.day }.filter { $0 >= windowStart && $0 <= asOf })
        let active = activeSet.sorted()
        var intervals: [Int] = []
        if active.count >= 2 {
            for i in 1..<active.count { intervals.append(active[i] - active[i - 1]) }
        }
        let doubles = intervals.map { Double($0) }
        let lastSession = data.sessions.map { $0.day }.max()
        return RegularityStats(
            status: tracked >= regularityMinimumTrackedDays ? .ok : .insufficientData,
            windowDays: regularityWindowDays,
            trackedDays: tracked,
            activeDays: active.count,
            activeShare: tracked > 0 ? Double(active.count) / Double(tracked) : nil,
            intervals: intervals,
            meanInterval: TrainingMath.mean(doubles),
            maxInterval: intervals.max(),
            intervalStdDev: intervals.count >= 2 ? TrainingMath.sampleStdDev(doubles) : nil,
            daysSinceLastSession: lastSession.map { asOf - $0 })
    }

    // MARK: Acute / chronic load

    /// Time-aware EWMA: a gap of g days applies the smoothing g times, so unknown days
    /// are neither zeros nor carried values.
    static func ewma(_ series: [Int: Double], span: Int) -> Double? {
        let days = series.keys.sorted()
        guard let first = days.first, let seed = series[first] else { return nil }
        let alpha = 2.0 / (Double(span) + 1)
        var state = seed
        var prev = first
        for day in days.dropFirst() {
            guard let v = series[day] else { continue }
            let gap = Double(day - prev)
            let eff = 1 - pow(1 - alpha, gap)
            state += eff * (v - state)
            prev = day
        }
        return state.isFinite ? state : nil
    }

    static func loadStats(_ data: TrainingDataset) -> LoadStats {
        let asOf = data.asOfDay
        let series = data.series(.cardioLoad)
        let windowStart = asOf - LoadStats.chronicDays + 1
        let inWindow = series.keys.filter { $0 >= windowStart && $0 <= asOf }
        let dataDays = inWindow.count
        let lastDay = series.keys.max()
        let acute = ewma(series, span: LoadStats.acuteDays)
        let chronic = ewma(series, span: LoadStats.chronicDays)

        let confs = inWindow.compactMap { data.loads[$0]?.confidence }
        let lowShare: Double? = confs.isEmpty
            ? nil : Double(confs.filter { $0 == .low }.count) / Double(confs.count)

        var status: LoadRatioStatus
        var ratio: Double? = nil
        if series.isEmpty {
            status = .noData
        } else if let lastDay, asOf - lastDay >= LoadStats.acuteDays {
            status = .noRecentData
        } else if dataDays < LoadStats.requiredDays {
            status = .calibration
        } else if let acute, let chronic, chronic > 1e-6 {
            status = .available
            let r = acute / chronic
            ratio = r.isFinite ? r : nil
            if ratio == nil { status = .chronicNearZero }
        } else {
            status = .chronicNearZero
        }
        return LoadStats(status: status, acuteEWMA: acute, chronicEWMA: chronic, ratio: ratio,
                         dataDays: dataDays, daysSinceLastLoad: lastDay.map { asOf - $0 },
                         lowConfidenceShare: lowShare)
    }

    // MARK: Monotony

    static func monotony(_ loads: [Int: Double], asOfDay: Int) -> MonotonyStats {
        let start = asOfDay - MonotonyStats.windowDays + 1
        let values = loads.filter { $0.key >= start && $0.key <= asOfDay }.map { $0.value }
        let known = values.count
        guard known >= MonotonyStats.minimumKnownDays,
              let mean = TrainingMath.mean(values),
              let sd = TrainingMath.populationStdDev(values) else {
            return MonotonyStats(status: .insufficientData, knownDays: known, meanLoad: TrainingMath.mean(values),
                                 standardDeviation: nil, monotony: nil, coefficientOfVariation: nil)
        }
        let monotony: Double? = sd > 1e-9 ? mean / sd : nil
        let cv: Double? = mean > 1e-9 ? sd / mean : nil
        return MonotonyStats(status: monotony == nil ? .undefined : .ok, knownDays: known, meanLoad: mean,
                             standardDeviation: sd, monotony: monotony, coefficientOfVariation: cv)
    }

    // MARK: Sleep

    static func sleepStats(_ data: TrainingDataset) -> SleepStats {
        let start = data.asOfDay - SleepStats.windowDays + 1
        let nights = data.sleep.filter { $0.key >= start && $0.key <= data.asOfDay }.map { $0.value }
        return SleepStats(
            nights: nights.count,
            medianDurationMinutes: TrainingMath.median(nights.compactMap { $0.durationMinutes }),
            medianEfficiency: TrainingMath.median(nights.compactMap { $0.efficiency }),
            medianAwakenings: TrainingMath.median(nights.compactMap { $0.awakenings.map { Double($0) } }),
            medianCoverage: TrainingMath.median(nights.compactMap { $0.coverage }))
    }

    // MARK: Trends against the personal reference

    /// Compares the median of the recent window with the reference (median of the preceding
    /// window, or an existing personal baseline), scaled by the MAD.
    public static func trend(metric: TrainingMetric, series: [Int: Double], asOfDay: Int,
                             recentDays: Int = 7, referenceDays: Int = 28,
                             minRecent: Int = 3, minReference: Int = 10,
                             reference: TrainingReference? = nil) -> TrendStat {
        let clean = series.filter { $0.key <= asOfDay && $0.value.isFinite }
        let recentStart = asOfDay - recentDays + 1
        let refEnd = recentStart - 1
        let refStart = refEnd - referenceDays + 1
        let recent = clean.filter { $0.key >= recentStart }.map { $0.value }
        let refValues = clean.filter { $0.key >= refStart && $0.key <= refEnd }.map { $0.value }
        let recentMedianOpt = TrainingMath.median(recent)

        let centerOpt: Double?
        let scaleOpt: Double?
        let refCount: Int
        let usedReference: Bool
        if let reference, reference.madEquivalent > 0, reference.center.isFinite {
            centerOpt = reference.center
            scaleOpt = max(reference.madEquivalent, 1e-9)
            refCount = reference.nValid
            usedReference = true
        } else {
            let c = TrainingMath.median(refValues)
            centerOpt = c
            if let c, let m = TrainingMath.mad(refValues, center: c) {
                scaleOpt = max(m, metric.minimumMAD)
            } else {
                scaleOpt = nil
            }
            refCount = refValues.count
            usedReference = false
        }

        let enough = recent.count >= minRecent && refCount >= minReference
        guard enough, let recentMedian = recentMedianOpt, let center = centerOpt,
              let scale = scaleOpt, scale > 0 else {
            return TrendStat(metric: metric, status: .insufficientData, recentDays: recentDays,
                             referenceDays: referenceDays, recentCount: recent.count, referenceCount: refCount,
                             recentMedian: recentMedianOpt, referenceCenter: centerOpt, scaleMAD: scaleOpt,
                             delta: nil, deltaInMAD: nil, direction: nil, confidence: .low,
                             usedPersonalReference: usedReference)
        }
        let delta = recentMedian - center
        let dev = delta / scale
        let direction: TrendDirection = dev >= notableDeviationMAD ? .up
            : (dev <= -notableDeviationMAD ? .down : .stable)
        var confidence: TrainingConfidence = (recent.count >= 5 && refCount >= 20) ? .high : .medium
        if let reference, usedReference, !reference.isTrusted { confidence = .medium }
        return TrendStat(metric: metric, status: .ok, recentDays: recentDays, referenceDays: referenceDays,
                         recentCount: recent.count, referenceCount: refCount, recentMedian: recentMedian,
                         referenceCenter: center, scaleMAD: scale, delta: delta, deltaInMAD: dev,
                         direction: direction, confidence: confidence, usedPersonalReference: usedReference)
    }

    // MARK: Change detection (two-sided CUSUM)

    /// Tabular CUSUM of recent points standardised by the preceding reference window
    /// (median and 1.4826 x MAD). Slack k = 0.5, threshold h = 4 robust standard deviations.
    public static func detectChange(metric: TrainingMetric, series: [Int: Double], asOfDay: Int,
                                    recentDays: Int = 14, referenceDays: Int = 28,
                                    minRecent: Int = 6, minReference: Int = 10,
                                    slack: Double = 0.5, threshold: Double = 4.0) -> ChangeDetection {
        let clean = series.filter { $0.key <= asOfDay && $0.value.isFinite }
        let recentStart = asOfDay - recentDays + 1
        let refEnd = recentStart - 1
        let refStart = refEnd - referenceDays + 1
        let recentPoints = clean.filter { $0.key >= recentStart }.sorted { $0.key < $1.key }
        let refValues = clean.filter { $0.key >= refStart && $0.key <= refEnd }.map { $0.value }

        func result(_ status: ChangeStatus, _ dir: TrendDirection?, _ onset: Int?, _ stat: Double?,
                    _ conf: TrainingConfidence) -> ChangeDetection {
            ChangeDetection(metric: metric, status: status, direction: dir, onsetDay: onset,
                            recentCount: recentPoints.count, referenceCount: refValues.count,
                            recentDays: recentDays, statistic: stat, threshold: threshold, confidence: conf)
        }

        guard recentPoints.count >= minRecent, refValues.count >= minReference,
              let center = TrainingMath.median(refValues),
              let rawMAD = TrainingMath.mad(refValues, center: center) else {
            return result(.insufficientData, nil, nil, nil, .low)
        }
        let sigma = max(rawMAD, metric.minimumMAD) * 1.4826
        guard sigma > 0, sigma.isFinite else { return result(.insufficientData, nil, nil, nil, .low) }

        let confidence: TrainingConfidence = (recentPoints.count >= 10 && refValues.count >= 20) ? .high : .medium
        var hi = 0.0, lo = 0.0
        var hiOnset: Int?, loOnset: Int?
        var maxStat = 0.0
        for point in recentPoints {
            let z = (point.value - center) / sigma
            hi = max(0, hi + z - slack)
            lo = max(0, lo - z - slack)
            if hi == 0 { hiOnset = nil } else if hiOnset == nil { hiOnset = point.key }
            if lo == 0 { loOnset = nil } else if loOnset == nil { loOnset = point.key }
            maxStat = max(maxStat, hi, lo)
            if hi >= threshold && hi >= lo {
                return result(.changeDetected, .up, hiOnset, hi, confidence)
            }
            if lo >= threshold {
                return result(.changeDetected, .down, loOnset, lo, confidence)
            }
        }
        return result(.noChange, nil, nil, maxStat, confidence)
    }

    // MARK: Exploratory links

    static func link(_ pair: TrainingLinkPair, data: TrainingDataset) -> LinkStat {
        let x: [Int: Double]
        let y: [Int: Double]
        let lag: Int
        switch pair {
        case .loadToNextSleepDuration:
            x = data.series(.cardioLoad); y = data.series(.sleepDuration); lag = 1
        case .loadToNextRecovery:
            x = data.series(.cardioLoad); y = data.series(.recoveryScore); lag = 1
        case .sleepDurationToRecovery:
            x = data.series(.sleepDuration); y = data.series(.recoveryScore); lag = 0
        case .sleepEfficiencyToRecovery:
            x = data.series(.sleepEfficiency); y = data.series(.recoveryScore); lag = 0
        }
        let windowStart = data.asOfDay - LinkStat.windowDays + 1
        var xs: [Double] = []
        var ys: [Double] = []
        for day in x.keys.sorted() {
            let target = day + lag
            guard target >= windowStart, target <= data.asOfDay,
                  let xv = x[day], let yv = y[target] else { continue }
            xs.append(xv)
            ys.append(yv)
        }
        let n = xs.count
        guard n >= LinkStat.minimumPairs else {
            return LinkStat(pair: pair, status: .insufficientData, pairCount: n, spearman: nil,
                            intervalLow: nil, intervalHigh: nil, sign: nil)
        }
        guard let rho = TrainingMath.spearman(xs, ys) else {
            return LinkStat(pair: pair, status: .undefined, pairCount: n, spearman: nil,
                            intervalLow: nil, intervalHigh: nil, sign: nil)
        }
        let ci = TrainingMath.spearmanInterval(rho: rho, n: n)
        let sign = rho > 1e-9 ? 1 : (rho < -1e-9 ? -1 : 0)
        return LinkStat(pair: pair, status: .ok, pairCount: n, spearman: rho,
                        intervalLow: ci?.low, intervalHigh: ci?.high, sign: sign)
    }
}
