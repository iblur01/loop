import SwiftUI
import Charts
import HealthKit

/// What the Today activity card can show. The causes of an empty card stay distinct: still
/// loading, Apple Health never authorised, the report could not be built, or simply no data that day.
enum TodayHealthState: Equatable {
    case loading
    case needsPermission
    case failed
    case loaded(HealthDayReport)
    /// Apple Health unavailable on this device — the card is not shown at all.
    case hidden
}

/// Ask iOS whether Apple Health read access was ever requested. iOS never reveals whether read
/// access was granted, so "requested" is the best positive signal available.
enum TodayHealthAccess {
    @MainActor static func needsPermission() async -> Bool? {
        guard HealthKitImporter.isAvailable else { return nil }
        let status = try? await HKHealthStore().statusForAuthorizationRequest(toShare: [], read: HealthSampleKind.allReadTypes)
        return status == .shouldRequest
    }
}

/// Activity of the day, graph first: the merged step count (band + Apple Health) as one tabular
/// figure and an hourly bar chart. Everything else the merge knows — every quantity, which source
/// was kept, how sources agree, the merged sessions — sits behind an explicit "Sources et séances"
/// disclosure.
struct HealthDayWidget: View {
    let state: TodayHealthState
    var needsAuthorization = false
    var onAuthorize: () -> Void = {}
    var onRetry: () -> Void = {}

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .hidden:
                EmptyView()
            case .loading:
                skeleton
            case .needsPermission:
                header(value: "—", hasValue: false)
                message(TodayL.text("today.health.disconnected"), action: TodayL.text("today.health.authorize"), perform: onAuthorize)
            case .failed:
                header(value: "—", hasValue: false)
                message(TodayL.text("today.health.failed"), action: TodayL.text("today.health.retry"), perform: onRetry)
            case .loaded(let report):
                loaded(report)
            }
        }
        .widgetSurface()
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loaded(_ report: HealthDayReport) -> some View {
        let steps = report.row(.stepCount)
        let unknown = steps?.conflicts.contains { $0.reason == .unknownProducer } == true
        header(value: steps?.value.map(Self.stepFigure) ?? (unknown ? TodayL.text("today.health.conflict.unknown.name") : "—"), hasValue: steps?.value != nil)
        if let steps, steps.value != nil, let source = steps.source, !source.isEmpty {
            Text(source).font(.caption).foregroundStyle(.secondary)
        }

        if let steps, steps.hasConflicts {
            if steps.isPartial {
                Text(TodayL.text("today.health.steps.partial"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(Self.conflictMessage(steps))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let steps, steps.value != nil, !steps.points.isEmpty {
            hourlyChart(steps.points)
        } else {
            Text(report.hasHealthData ? TodayL.text("today.health.no.steps") : TodayL.text("today.health.no.data"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if needsAuthorization {
            message(TodayL.text("today.health.disconnected"), action: TodayL.text("today.health.authorize"), perform: onAuthorize)
        }

        if !report.activities.isEmpty || hasStepDetail(report) {
            disclosure(report)
        }
    }

    /// Le détail de l'accueil ne montre que les pas (et leur source) : le reste reste dans le moteur.
    private func hasStepDetail(_ report: HealthDayReport) -> Bool {
        guard let steps = report.row(.stepCount) else { return false }
        return steps.value != nil || steps.hasConflicts
    }

    private func header(value: String, hasValue: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("today.pas", tableName: "Today")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(hasValue ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// Steps per hour: discrete hourly counts → bars, hours and unit labelled.
    private func hourlyChart(_ points: [HealthDayPoint]) -> some View {
        Chart(points) { p in
            BarMark(x: .value(TodayL.text("today.health.hour"), p.start, unit: .hour), y: .value(TodayL.text("today.health.steps"), p.value))
                .foregroundStyle(Color.primary.opacity(0.7))
                .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                    .font(.caption2.weight(.medium))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(TodayL.format("today.health.steps.count", String(Int(v.rounded())))).font(.caption2.weight(.medium)).monospacedDigit()
                    }
                }
            }
        }
        .frame(height: 84)
        .accessibilityLabel(Text("today.pas.par.heure", tableName: "Today"))
    }

    // MARK: - Detail on demand

    private func disclosure(_ report: HealthDayReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("today.sources.et.seances", tableName: "Today")
                        .font(.footnote.weight(.semibold))
                    if !report.activities.isEmpty {
                        Text("\(report.activities.count)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? TodayL.text("today.health.hide.details") : TodayL.text("today.health.show.details"))

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    if let steps = report.row(.stepCount), hasStepDetail(report) { sourceRow(steps) }
                    if !report.activities.isEmpty {
                        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                        ForEach(report.activities) { activityRow($0) }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// One quantity: value, then a bar split by source share (labelled — never colour alone).
    private func sourceRow(_ row: HealthDayRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).font(.footnote.weight(.medium))
                Spacer(minLength: 8)
                Text(row.value ?? "—").font(.footnote.weight(.semibold)).monospacedDigit()
            }
            if row.kind == .stepCount, let source = row.source {
                Text(source).font(.caption2).foregroundStyle(.secondary)
            } else if !row.shares.isEmpty {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(row.shares) { share in
                            Capsule()
                                .fill(Self.color(share.source))
                                .frame(width: max(3, (geo.size.width - CGFloat(row.shares.count - 1) * 2) * share.fraction))
                        }
                    }
                }
                .frame(height: 5)
                Text(row.shares.map { "\($0.source.label) \(Int(($0.fraction * 100).rounded())) %" }.joined(separator: " · "))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if let source = row.source {
                Text(source).font(.caption2).foregroundStyle(.secondary)
            }
            if let agreement = row.agreement {
                Text(agreement).font(.caption2).foregroundStyle(.secondary)
            }
            if let note = row.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if row.hasConflicts {
                Text(Self.conflictMessage(row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                let names = row.conflictSourceNames + (row.hasUnknownConflictSource ? [TodayL.text("today.health.conflict.unknown.name")] : [])
                if !names.isEmpty {
                    Text(TodayL.format("today.health.conflict.source.names", names.joined(separator: " · ")))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func activityRow(_ a: HealthDayActivityRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.footnote.weight(.medium))
                Text("\(Self.time.string(from: a.start))–\(Self.time.string(from: a.end)) · \(a.sources.map(\.label).joined(separator: " + "))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(a.durationMin) min").font(.footnote.weight(.semibold)).monospacedDigit()
                if let energy = a.energy {
                    Text(energy).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Empty / loading

    private func message(_ text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action, action: perform)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// Same structure as the loaded card (title, figure, chart), so nothing jumps when data lands.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(value: "0 000", hasValue: true)
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)).frame(height: 84)
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel(Text("today.chargement.des.pas", tableName: "Today"))
    }

    // MARK: - Helpers

    private static func conflictMessage(_ row: HealthDayRow) -> String {
        let reasons = row.conflicts.map(\.reason)
        if reasons.allSatisfy({ $0 == .unknownProducer }) {
            return TodayL.text("today.health.conflict.unknown.source")
        }
        if reasons.allSatisfy({ $0 == .tooManySamples }) {
            return TodayL.text("today.health.conflict.too.many.samples")
        }
        return TodayL.text("today.health.conflicting.sources")
    }

    /// "8 432 pas" → "8 432": the unit is already the card label.
    private static func stepFigure(_ value: String) -> String {
        value.replacingOccurrences(of: " pas", with: "")
    }

    /// Source hues for the share bars (always captioned with the source name).
    static func color(_ source: HealthDataSource) -> Color {
        switch source {
        case .whoop: return Color.primary.opacity(0.75)
        case .appleWatch: return Pop.blue
        case .healthKit: return Pop.cyan
        }
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}
