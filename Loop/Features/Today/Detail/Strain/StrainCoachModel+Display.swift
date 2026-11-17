import Foundation
import LoopStrapEngine

/// Display mapping for the redesigned Strain page (hero + dynamic widgets). Pure presentation of
/// values already computed by the engine / `StrainCoachModel`: no new metric is derived here.
extension StrainCoachModel {

    // MARK: Formatting

    static let frLocale = Locale.current

    static func format(_ value: Double, decimals: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(decimals)).locale(frLocale))
    }

    static func signed(_ value: Double, decimals: Int = 1) -> String {
        let rounded = (value * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        return (rounded > 0 ? "+" : rounded < 0 ? "−" : "") + format(abs(rounded), decimals: decimals)
    }

    /// Hero value with a French decimal comma, or "--" while calibrating.
    var heroValueText: String { strain.map { Self.format($0) } ?? "--" }

    // MARK: Target relation

    enum TargetRelation { case below, aligned, above, noTarget, calibrating }

    var targetRelation: TargetRelation {
        guard let strain else { return .calibrating }
        guard let target = targetStrain else { return .noTarget }
        if strain > target * 1.1 { return .above }
        if strain < target * 0.7 { return .below }
        return .aligned
    }

    /// Hero state: always a word + a symbol. Above target is "fair" (amber), not an alarm; the
    /// real overload alert comes from the acute:chronic ratio.
    var heroState: (state: HealthState, text: String) {
        switch targetRelation {
        case .calibrating: return (.neutral, "Calibrage")
        case .noTarget:    return (.neutral, "Effort \(qualityLabel.lowercased())")
        case .below:       return (.neutral, "Sous la cible")
        case .aligned:     return (.good, "Dans la cible")
        case .above:       return (.fair, TodayL.text("today.target.above"))
        }
    }

    var heroContext: String {
        switch targetRelation {
        case .calibrating:
            return tense.pick(TodayL.text("today.ton.strain.s.affiche.des.que.le.bracelet.a.mesure.assez.de.frequence.cardia"),
                              past: TodayL.text("today.pas.assez.de.frequence.cardiaque.mesuree.ce.jour.la"))
        case .noTarget:
            return String(localized: "today.pas.de.cible.calculee.pour.ce.jour", table: "Today")
        default:
            return "Effort \(qualityLabel.lowercased()) · cible \(targetStrain.map { Self.format($0) } ?? "--")"
        }
    }

    /// Provisional result from the fast express pass.
    var heroPartialNote: String? {
        metric.isExpress && strain != nil ? TodayL.text("today.calcul.provisoire.le.calcul.complet.n.est.pas.termine") : nil
    }

    // MARK: Day load vs reference

    var hasDayLoad: Bool { strain != nil && (targetStrain != nil || effortBaselineDelta != nil) }

    /// Strain minus the 30-day mean (from the effort row), nil without a baseline.
    var effortBaselineDelta: Double? { metrics.first { $0.kind == .effort }?.delta }

    /// Numeric gap to the target, French formatting ("Encore 3,2 avant la cible").
    var targetGapText: String? {
        guard let strain, let target = targetStrain else { return nil }
        let gap = target - strain
        if abs(gap) <= target * 0.1 { return "Cible atteinte (\(Self.signed(-gap)))" }
        if gap > 0 { return tense.pick("Encore \(Self.format(gap)) avant la cible", past: "\(Self.format(gap)) sous la cible") }
        return TodayL.format("today.strain.over.amount", Self.format(-gap))
    }

    var isTargetLowConfidence: Bool { targetStrain != nil && metric.targetStrainConfidence == "low" }

    var targetSegments: [SegmentedCursorBar.Segment] {
        guard let target = targetStrain else { return [] }
        return [
            .init(upperBound: target * 0.7, label: "Sous"),
            .init(upperBound: min(target * 1.1, 21), label: "Cible"),
            .init(upperBound: 21, label: "Au-dessus")
        ]
    }

    // MARK: Acute:chronic

    var acwrState: (state: HealthState, text: String) {
        switch acwrZone {
        case .optimal:    return (.good, "Zone optimale")
        case .ramping:    return (.fair, "En hausse")
        case .high:       return (.poor, "Charge haute")
        case .detraining: return (.neutral, "En baisse")
        case .unknown:    return (.neutral, "Calibrage")
        }
    }

    static let acwrSegments: [SegmentedCursorBar.Segment] = [
        .init(upperBound: 0.8, label: "Baisse"),
        .init(upperBound: 1.3, label: "Optimale"),
        .init(upperBound: 1.5, label: "Hausse"),
        .init(upperBound: 2.0, label: "Haute")
    ]

    // MARK: Advice

    /// The day reads calm against the target while the 7-day load is far above habit.
    var adviceContradiction: String? {
        guard acwrZone == .high, targetRelation == .below || targetRelation == .aligned else { return nil }
        return tense.pick(TodayL.text("today.strain.contradiction"),
                          past: TodayL.text("today.strain.contradiction.past"))
    }

    var adviceTitle: String { adviceContradiction == nil ? manageTitle : TodayL.text("today.journee.legere.semaine.chargee") }

    var adviceMessage: String {
        guard adviceContradiction != nil else { return manageMessage }
        return tense.pick(TodayL.text("today.strain.contradiction.advice"),
                          past: TodayL.text("today.strain.contradiction.past.advice"))
    }

    /// Overline of the advice block: advice today, recap on a past day.
    var adviceOverline: String { tense.pick(TodayL.text("today.remaining.strain.advice"), past: TodayL.text("today.remaining.strain.summary")) }

    // MARK: Heart-rate zones

    var zones: HeartRateZoneBreakdown? {
        guard let z = metric.heartRateZones, z.totalMinutes > 0 else { return nil }
        return z
    }

    /// Minutes in zones 1…5 only (the active time). Zone 0 is reported apart.
    var activeZoneRows: [(zone: HeartRateZone, minutes: Double)] {
        guard let z = zones else { return [] }
        return HeartRateZone.allCases.filter { $0 != .below }.map { ($0, z.zoneMinutes[$0.rawValue - 1]) }
    }

    /// Base of the zone shares: minutes in zones 1 to 5, never the whole day.
    var activeZoneMinutes: Double { activeZoneRows.reduce(0) { $0 + $1.minutes } }

    /// "45 min", "1 h 05", "23 h 09".
    static func durationText(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    // MARK: 7-day trend

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let letterFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = frLocale; f.dateFormat = "EEEEE"; return f
    }()

    private static let spokenFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = frLocale; f.setLocalizedDateFormatFromTemplate("EEEE d MMMM"); return f
    }()

    /// The 7 calendar days ending on the selected day; missing days stay in place with no value.
    var weekDays: [DayBarsChart.Day] {
        guard let end = Self.dayParser.date(from: metric.date) else { return [] }
        let byDate = Dictionary(history.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
        let cal = Calendar(identifier: .gregorian)
        return (0..<7).reversed().compactMap { offset -> DayBarsChart.Day? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: end) else { return nil }
            let key = Self.dayParser.string(from: date)
            let raw = byDate[key]?.strain
            let value = raw.flatMap { $0.isFinite && $0 > 0 ? min($0, 21) : nil }
            return DayBarsChart.Day(
                id: key,
                label: Self.letterFormatter.string(from: date).uppercased(),
                spokenLabel: Self.spokenFormatter.string(from: date),
                value: value,
                valueText: value.map { Self.format($0) } ?? "",
                isCurrent: offset == 0
            )
        }
    }

    var hasWeekTrend: Bool { weekDays.filter { $0.value != nil }.count >= 3 }

    var weeklyDeltaText: String? {
        guard let d = weeklyTrendDelta else { return nil }
        return Self.signed(d)
    }
}
