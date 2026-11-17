import SwiftUI

/// The day's headline — what to actually do today, derived from recovery / sleep / overload. The
/// most prominent widget. Carries one small recovery-band dot (the only colour), the rest is type.
struct FocusWidget: View {
    let metric: DailySnapshot?
    let strainTarget: Double

    private var focus: TodayFocus { TodayFocus.make(metric: metric, strainTarget: strainTarget) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let dot = focus.dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                }
                Text(focus.kicker)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            Text(focus.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(focus.message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .widgetSurface()
    }
}

/// Coach copy, ported from the original CoachCard rules into a sober value type.
struct TodayFocus {
    let kicker: String
    let title: String
    let message: String
    let dot: Color?

    static func make(metric: DailySnapshot?, strainTarget: Double) -> TodayFocus {
        guard let metric else {
            return TodayFocus(kicker: String(localized: "today.aujourd.hui", table: "Today"), title: String(localized: "today.pas.encore.de.donnees", table: "Today"),
                              message: String(localized: "today.tire.vers.le.bas.pour.rafraichir.et.recuperer.les.metriques.du.jour", table: "Today"), dot: nil)
        }

        if metric.isExpress {
            let strainLine = metric.strain.map { String(format: TodayL.text("today.focus.current.strain"), $0) } ?? ""
            return TodayFocus(kicker: TodayL.text("today.focus.calculating"), title: String(localized: "today.on.prepare.ta.journee", table: "Today"),
                              message: TodayL.format("today.focus.calculating.message", strainLine).trimmingCharacters(in: .whitespaces),
                              dot: nil)
        }

        let recovery = score(metric.recovery) ?? 0
        let sleepScore = score(metric.sleepScore) ?? score(metric.efficiency) ?? 0
        let target = String(format: "%.1f", metric.targetStrain ?? strainTarget)
        let band: Color = recovery >= 67 ? Pop.green : recovery >= 34 ? Pop.amber : Pop.red
        // Jour passé : bilan factuel au passé, sans impératif ni « demain » (AdviceTense).
        let t = AdviceTense.of(day: metric.date)
        let kicker = t.pick(TodayL.text("today.focus.today"), past: TodayL.text("today.focus.past.day"))

        if metric.recentOverload == true {
            return TodayFocus(kicker: kicker, title: t.pick(TodayL.text("today.focus.moderate"), past: TodayL.text("today.focus.recent.high")),
                              message: t.pick(TodayL.format("today.focus.overload", target),
                                              past: TodayL.format("today.focus.overload.past", target)),
                              dot: Pop.orange)
        }
        if recovery >= 67 {
            return TodayFocus(kicker: String(localized: "today.recuperation.haute", table: "Today"), title: t.pick(TodayL.text("today.focus.push"), past: TodayL.text("today.focus.green")),
                              message: t.pick(TodayL.format("today.focus.green.message", target),
                                              past: TodayL.format("today.focus.green.past", target)),
                              dot: band)
        }
        if recovery >= 34 {
            return TodayFocus(kicker: String(localized: "today.recuperation.moderee", table: "Today"), title: t.pick(TodayL.text("today.focus.measured"), past: TodayL.text("today.focus.recovery.moderate")),
                              message: t.pick(TodayL.format("today.focus.moderate.message", target),
                                              past: TodayL.format("today.focus.moderate.past", target)),
                              dot: band)
        }
        if sleepScore < 60 {
            return TodayFocus(kicker: String(localized: "today.sommeil.court", table: "Today"), title: t.pick(TodayL.text("today.focus.prioritize.sleep"), past: TodayL.text("today.focus.short.sleep")),
                              message: t.pick(TodayL.format("today.focus.sleep.message", String(Int(sleepScore.rounded()))),
                                              past: TodayL.format("today.focus.sleep.past", String(Int(sleepScore.rounded())))),
                              dot: band)
        }
        return TodayFocus(kicker: String(localized: "today.recuperation.basse", table: "Today"), title: t.pick(TodayL.text("today.focus.rest"), past: TodayL.text("today.focus.recovery.low")),
                          message: t.pick(TodayL.format("today.focus.rest.message", target),
                                          past: TodayL.format("today.focus.rest.past", target)),
                          dot: band)
    }

    private static func score(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        if value <= 1 { return min(max(value * 100, 0), 100) }
        return min(max(value, 0), 100)
    }
}

#Preview {
    VStack {
        FocusWidget(metric: nil, strainTarget: 15.5)
    }
    .padding()
}
