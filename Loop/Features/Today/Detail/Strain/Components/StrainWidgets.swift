import SwiftUI
import LoopStrapEngine

// MARK: - Day load vs reference

/// Today's strain against the day's target (segmented bar + cursor) and against the 30-day mean.
/// Hidden by the grid when there is no strain or no reference at all.
struct StrainDayLoadWidget: View {
    let model: StrainCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(symbol: "target", title: String(localized: "today.charge.du.jour", table: "Today"), tint: Metric.strain.tint,
                         trailing: model.targetStrain.map { "cible \(StrainCoachModel.format($0))" })

            if let strain = model.strain {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(StrainCoachModel.format(strain))
                        .font(LoopType.cardValue)
                        .monospacedDigit()
                        .foregroundStyle(LoopColor.textPrimary)
                    Text("/ 21")
                        .font(LoopType.cardUnit)
                        .foregroundStyle(Metric.strain.tint)
                }
                .accessibilityElement(children: .combine)

                if model.targetStrain != nil {
                    SegmentedCursorBar(
                        range: 0...21,
                        segments: model.targetSegments,
                        value: strain,
                        activeColor: model.targetRelation == .above ? HealthState.fair.color : Metric.strain.tint,
                        showsLabels: false,
                        valueText: "Strain \(StrainCoachModel.format(strain)), \(model.heroState.text)"
                    )
                    // État en grand sous la barre (même style que le héros), rien posé sur la barre.
                    let s = model.heroState
                    StateLabel(state: s.state, text: s.text, font: LoopType.heroState)
                    if let gap = model.targetGapText {
                        Text(gap)
                            .font(LoopType.label)
                            .monospacedDigit()
                            .foregroundStyle(LoopColor.textSecondary)
                    }
                }

                if let delta = model.effortBaselineDelta {
                    Label {
                        Text(TodayL.format("today.final.strain.delta", StrainCoachModel.signed(delta)))
                    } icon: {
                        Image(systemName: delta > 0.05 ? "arrow.up.right" : delta < -0.05 ? "arrow.down.right" : "equal")
                            .accessibilityHidden(true)
                    }
                    .font(LoopType.label)
                    .foregroundStyle(LoopColor.textSecondary)
                }

                if model.isTargetLowConfidence {
                    PartialNote(text: "Cible peu fiable : confiance basse.")
                }
            }
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard()
    }
}

// MARK: - Acute:chronic tile

/// 7-day vs 28-day load ratio. Only rendered once the engine ratio is calibrated.
struct StrainAcuteChronicTile: View {
    let model: StrainCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(symbol: "chart.line.uptrend.xyaxis", title: "Charge 7 j / 28 j", tint: Metric.strain.tint)

            if let ratio = model.acwrRatio {
                let s = model.acwrState
                Text(StrainCoachModel.format(ratio, decimals: 2))
                    .font(LoopType.tileValue)
                    .monospacedDigit()
                    .foregroundStyle(LoopColor.textPrimary)
                StateLabel(state: s.state, text: s.text)
                SegmentedCursorBar(
                    range: 0...2,
                    segments: StrainCoachModel.acwrSegments,
                    value: ratio,
                    activeColor: s.state == .neutral ? Metric.strain.tint : s.state.color,
                    showsLabels: false,
                    valueText: "Ratio \(StrainCoachModel.format(ratio, decimals: 2))"
                )
            }
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .loopCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint(TodayL.text("today.final.strain.ratio.hint"))
    }
}

// MARK: - Week vs previous week tile

/// Mean strain of the last 7 days vs the 7 before (existing weekly delta). Neutral direction:
/// more load is not good or bad by itself.
struct StrainWeeklyDeltaTile: View {
    let model: StrainCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WidgetHeader(symbol: "calendar", title: "Semaine", tint: Metric.strain.tint)

            if let delta = model.weeklyTrendDelta, let text = model.weeklyDeltaText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: delta > 0.05 ? "arrow.up.right" : delta < -0.05 ? "arrow.down.right" : "equal")
                        .font(LoopType.tileUnit)
                        .foregroundStyle(Metric.strain.tint)
                        .accessibilityHidden(true)
                    Text(text)
                        .font(LoopType.tileValue)
                        .monospacedDigit()
                        .foregroundStyle(LoopColor.textPrimary)
                }
                Text("today.strain.moyen.par.rapport.a.la.semaine.precedente", tableName: "Today")
                    .font(LoopType.label)
                    .foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .loopCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Heart-rate zones

/// Minutes in zones 1…5 over the day's load window, read from the engine breakdown. Bar and
/// shares are relative to the active minutes (zones 1 to 5), not the whole day: the time below
/// zone 1 (rest, low intensity) is one discrete line. Each zone is labelled.
struct StrainZonesWidget: View {
    let model: StrainCoachModel

    var body: some View {
        if let zones = model.zones, model.activeZoneMinutes > 0 {
            let rows = model.activeZoneRows
            let total = model.activeZoneMinutes
            VStack(alignment: .leading, spacing: 12) {
                WidgetHeader(symbol: "heart.fill", title: "Zones FC", tint: Metric.cardio.tint,
                             trailing: TodayL.format("today.final.zone.duration", StrainCoachModel.durationText(total)))

                stackedBar(rows, total: total)

                VStack(spacing: 6) {
                    ForEach(rows.reversed(), id: \.zone.id) { row in
                        zoneRow(row.zone, minutes: row.minutes, total: total)
                    }
                }

                if zones.belowZoneMinutes >= 1 {
                    Text(TodayL.format("today.final.zone.rest", StrainCoachModel.durationText(zones.belowZoneMinutes)))
                        .font(LoopType.footnote)
                        .foregroundStyle(LoopColor.textSecondary)
                }

                Text(TodayL.format("today.final.zone.description", String(Int(zones.restingHR.rounded())), String(Int(zones.maxHR.rounded())), sourceLabel(zones.maxHRSource)))
                    .font(LoopType.footnote)
                    .foregroundStyle(LoopColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(LoopMeasure.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .loopCard()
        }
    }

    private func stackedBar(_ rows: [(zone: HeartRateZone, minutes: Double)], total: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(rows, id: \.zone.id) { row in
                    if row.minutes > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(row.zone.color)
                            .frame(width: max(geo.size.width * CGFloat(row.minutes / total) - 2, 3))
                    }
                }
            }
        }
        .frame(height: 14)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func zoneRow(_ zone: HeartRateZone, minutes: Double, total: Double) -> some View {
        let share = Int((minutes / total * 100).rounded())
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(minutes > 0 ? zone.color : LoopColor.trackEmpty)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(zone.label)
                .font(LoopType.label)
                .foregroundStyle(minutes > 0 ? LoopColor.textPrimary : LoopColor.textSecondary)
            Spacer(minLength: 8)
            Text(StrainCoachModel.durationText(minutes))
                .font(LoopType.label.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(minutes > 0 ? LoopColor.textPrimary : LoopColor.textSecondary)
            Text("\(share) %")
                .font(LoopType.footnote)
                .monospacedDigit()
                .foregroundStyle(LoopColor.textSecondary)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .loopCard(.nested, cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TodayL.format("today.remaining.zone.spoken", zone.label, StrainCoachModel.durationText(minutes), String(share)))
    }

    private func sourceLabel(_ source: MaxHeartRateSource) -> String {
        switch source {
        case .personal: return "personnelle"
        case .estimated: return TodayL.text("today.strain.source.estimated")
        case .replay: return TodayL.text("today.strain.source.set")
        }
    }
}

// MARK: - 7-day trend

/// Last 7 calendar days: rounded bars with the value above, current day highlighted, missing
/// days as a dash. Hidden by the grid under 3 days of data.
struct StrainWeekTrendWidget: View {
    let model: StrainCoachModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(symbol: "chart.bar.fill", title: String(localized: "today.7.derniers.jours", table: "Today"), tint: Metric.strain.tint,
                         trailing: model.weeklyTrendDelta == nil ? nil : model.trendText)
            DayBarsChart(days: model.weekDays, maxValue: 21, tint: Metric.strain.tint)
        }
        .padding(LoopMeasure.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loopCard()
    }
}

// MARK: - Previews

#Preview("Widgets") {
    let model = StrainCoachModel.preview(strain: 15.2)
    return ScrollView {
        VStack(spacing: 12) {
            StrainDayLoadWidget(model: model)
            HStack(alignment: .top, spacing: 12) {
                StrainAcuteChronicTile(model: model)
                StrainWeeklyDeltaTile(model: model)
            }
            .fixedSize(horizontal: false, vertical: true)
            StrainWeekTrendWidget(model: model)
        }
        .padding(16)
    }
    .appBackground()
}
