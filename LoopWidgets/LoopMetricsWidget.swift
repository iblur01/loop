import SwiftUI
import WidgetKit

struct LoopMetricsWidget: Widget {
    let kind = LoopWidgetSnapshotStore.timelineKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LoopMetricsProvider()) { entry in
            LoopMetricsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Loop Metrics")
        .description("widget.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct LoopSleepAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopSleepAccessoryWidget", provider: LoopMetricsProvider()) { entry in
            MetricAccessoryCircularView(metric: entry.snapshot.sleep, symbol: "moon.fill")
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("widget.sleep")
        .description("widget.sleep.description")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LoopRecoveryAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopRecoveryAccessoryWidget", provider: LoopMetricsProvider()) { entry in
            MetricAccessoryCircularView(metric: entry.snapshot.recovery, symbol: "heart.fill")
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("widget.recovery")
        .description("widget.recovery.description")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LoopStrainAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopStrainAccessoryWidget", provider: LoopMetricsProvider()) { entry in
            MetricAccessoryCircularView(metric: entry.snapshot.strain, symbol: "bolt.heart.fill")
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("widget.strain")
        .description("widget.strain.description")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LoopBatteryAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopBatteryAccessoryWidget", provider: LoopMetricsProvider()) { entry in
            MetricAccessoryCircularView(metric: entry.snapshot.battery, symbol: "battery.100percent")
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("widget.battery")
        .description("widget.battery.description")
        .supportedFamilies([.accessoryCircular])
    }
}

struct LoopStatusAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LoopStatusAccessoryWidget", provider: LoopMetricsProvider()) { entry in
            LoopStatusAccessoryRectangularView(snapshot: entry.snapshot)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("widget.status")
        .description("widget.status.description")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LoopMetricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> LoopMetricsEntry {
        LoopMetricsEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (LoopMetricsEntry) -> Void) {
        completion(LoopMetricsEntry(date: Date(), snapshot: LoopWidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LoopMetricsEntry>) -> Void) {
        let snapshot = LoopWidgetSnapshotStore.load()
        let entry = LoopMetricsEntry(date: Date(), snapshot: snapshot)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct LoopMetricsEntry: TimelineEntry {
    let date: Date
    let snapshot: LoopWidgetSnapshot
}

private struct LoopMetricsWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let snapshot: LoopWidgetSnapshot

    private var metrics: [LoopWidgetSnapshot.Metric] {
        [snapshot.sleep, snapshot.recovery, snapshot.strain, snapshot.battery]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 12) {
            HStack {
                Text("widget.today")
                    .font(.system(size: family == .systemSmall ? 13 : 15, weight: .bold))

                Spacer()

                Text(snapshot.updatedAt, style: .time)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if family == .systemSmall {
                LazyVGrid(columns: smallColumns, spacing: 8) {
                    ForEach(metrics, id: \.label) { metric in
                        MetricCircle(metric: metric, size: 48)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    ForEach(metrics, id: \.label) { metric in
                        MetricCircle(metric: metric, size: 58)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(family == .systemSmall ? 12 : 16)
    }

    private var smallColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }
}

private struct MetricCircle: View {
    let metric: LoopWidgetSnapshot.Metric
    let size: CGFloat

    private var tint: Color {
        Color(hex: metric.tintHex)
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: 5)

                Circle()
                    .trim(from: 0, to: min(max(metric.progress, 0), 1))
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                Text(metric.valueText)
                    .font(.system(size: size < 54 ? 12 : 14, weight: .bold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(width: size, height: size)

            Text(localizedMetricLabel(metric.label))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizedMetricLabel(metric.label))
        .accessibilityValue(metric.valueText)
    }
}

private struct MetricAccessoryCircularView: View {
    let metric: LoopWidgetSnapshot.Metric
    let symbol: String

    var body: some View {
        Gauge(value: min(max(metric.progress, 0), 1)) {
            Image(systemName: symbol)
        } currentValueLabel: {
            Text(accessoryValueText)
                .minimumScaleFactor(0.65)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(Color(hex: metric.tintHex))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localizedMetricLabel(metric.label))
        .accessibilityValue(metric.valueText)
    }

    private var accessoryValueText: String {
        metric.valueText.replacingOccurrences(of: "%", with: "")
    }
}

private struct LoopStatusAccessoryRectangularView: View {
    let snapshot: LoopWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "applewatch")
                Text("Loop")
                    .fontWeight(.semibold)
                Spacer(minLength: 4)
                Text(snapshot.updatedAt, style: .time)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                compactMetric(snapshot.battery, symbol: "battery.100percent")
                compactMetric(snapshot.strain, symbol: "bolt.heart.fill")
            }

            HStack(spacing: 8) {
                compactMetric(snapshot.sleep, symbol: "moon.fill")
                compactMetric(snapshot.recovery, symbol: "heart.fill")
            }
        }
        .font(.system(size: 12, weight: .medium))
        .widgetAccentable()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("widget.status.accessibility")
        .accessibilityValue(String(format: String(localized: "widget.status.value"), snapshot.battery.valueText, snapshot.strain.valueText, snapshot.updatedAt.formatted(date: .omitted, time: .shortened)))
    }

    private func compactMetric(_ metric: LoopWidgetSnapshot.Metric, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(metric.valueText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

private extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var value: UInt64 = 0
        scanner.scanHexInt64(&value)

        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255

        self.init(red: red, green: green, blue: blue)
    }
}

// Snapshot labels are stable identifiers, localized at display time in the extension.
private func localizedMetricLabel(_ label: String) -> String {
    switch label {
    case "Sleep": return String(localized: "widget.sleep")
    case "Recovery": return String(localized: "widget.recovery")
    case "Strain": return String(localized: "widget.strain")
    case "Battery": return String(localized: "widget.battery")
    default: return label
    }
}
