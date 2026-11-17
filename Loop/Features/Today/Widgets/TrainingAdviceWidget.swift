import SwiftUI
import LoopStrapEngine

// MARK: - Strings (chrome only; insight texts come from TrainingInsightStrings)

/// App-side keys for the chrome around an insight (title, confidence label, states). The insight
/// sentences themselves are rendered by `TrainingInsightRenderer` from `TrainingInsightStrings`;
/// both tables are merged so every visible sentence goes through the same keyed renderer.
/// No digit appears in any template: numbers only come from `TrainingInsight.facts`.
enum TrainingAdviceStrings {
    static let table: [String: String] = {
        var s = TrainingInsightStrings.fr
        s["training.widget.title"] = "Conseil du jour"
        s["training.widget.loading"] = "Analyse de votre entraînement en cours."
        s["training.widget.absent.title"] = "Pas encore de conseil"
        s["training.widget.absent.body"] = "Aucune lecture n'est disponible : les données d'entraînement manquent. Aucune conclusion n'est tirée."
        s["training.widget.calibration.badge"] = "Calibration"
        s["training.widget.insufficient.badge"] = "Données insuffisantes"
        s["training.widget.partial.badge"] = "Données partielles"
        s["training.widget.contradictory.badge"] = "Signaux contradictoires"
        s["training.widget.other_conflict"] = "Autre signal contradictoire"
        s["training.widget.cta"] = "Voir le détail"
        s["training.confidence.label"] = "Confiance"
        s["training.confidence.low"] = "faible"
        s["training.confidence.medium"] = "moyenne"
        s["training.confidence.high"] = "élevée"
        s["training.confidence.none"] = "Confiance non évaluable"
        s["training.experimental"] = "Expérimental"
        // Detail page
        s["training.detail.title"] = "Conseil du jour"
        s["training.detail.contributors"] = "Facteurs pris en compte"
        s["training.detail.notes"] = "Notes"
        s["training.detail.others"] = "Autres lectures"
        s["training.detail.none"] = "Aucune lecture disponible pour le moment."
        // Contributor labels
        let contributors: [String: String] = [
            "active_days": "Jours avec séance", "acute_ewma_7d": "Charge lissée récente",
            "calibration": "Durée de calibration", "chronic_ewma_28d": "Charge lissée habituelle",
            "cusum": "Somme cumulative (CUSUM)", "daily_load_constant": "Charge quotidienne constante",
            "daily_load_coverage": "Jours de charge connus", "daily_load_dispersion": "Dispersion de la charge",
            "daily_load_mean": "Charge quotidienne moyenne", "history_length": "Longueur de l'historique",
            "paired_days": "Paires de jours", "personal_reference": "Référence personnelle",
            "rank_correlation": "Corrélation de rang", "recent_load_missing": "Charge récente manquante",
            "recovery_score": "Score de récupération (expérimental)", "reported_feeling": "Ressenti déclaré",
            "session_count": "Nombre de séances", "session_spacing": "Espacement des séances",
            "sleep_duration": "Durée de sommeil", "sleep_duration_median": "Médiane de sommeil",
            "sleep_duration_vs_personal_reference": "Sommeil face à ta référence",
            "low_confidence_inputs": "Charges quotidiennes peu fiables"
        ]
        for (k, v) in contributors { s["training.contributor.\(k)"] = v }
        s["training.contributor.unknown"] = "Autre facteur"
        if Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true {
            s.merge(TrainingAdviceEnglish.strings) { _, english in english }
        }
        return s
    }()

    static func text(_ key: String) -> String { table[key] ?? key }

    /// Same table, adapted to the displayed day (`AdviceTense`). On a past day the reading is
    /// framed as computed today (the report is not recomputed per day), and imperative
    /// recommendations become statements.
    static func table(for tense: AdviceTense) -> [String: String] {
        guard tense == .past else { return table }
        var s = table
        s["training.widget.title"] = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "Training reading" : "Lecture d'entraînement"
        for (key, value) in s where value.contains("ne tirez pas de conclusion") {
            s[key] = value.replacingOccurrences(
                of: " : ne tirez pas de conclusion d'un seul d'entre eux.",
                with: " : aucun des deux ne suffit seul à conclure.")
        }
        return s
    }

    /// Framing line shown with a training reading on a past day.
    static let pastDayNote = Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true
        ? "Reading calculated using data up to today, not this day."
        : "Lecture calculée sur les données jusqu'à aujourd'hui, pas sur ce jour."

    static func contributorLabel(_ id: String) -> String {
        table["training.contributor.\(id)"] ?? text("training.contributor.unknown")
    }

    /// State badge key for one insight (nil when it is reliable and needs none).
    static func stateBadgeKey(_ insight: TrainingInsight) -> String? {
        switch insight.state {
        case .insufficientData:
            return insight.shortKey.hasSuffix("calibration")
                ? "training.widget.calibration.badge" : "training.widget.insufficient.badge"
        case .contradictory: return "training.widget.contradictory.badge"
        case .ok:
            let partial = insight.confidence == .low
                || insight.detailNoteKeys.contains(where: TrainingAdviceModel.dataQualityNotes.contains)
            return partial ? "training.widget.partial.badge" : nil
        }
    }

    static func confidenceWord(_ c: TrainingConfidence) -> String {
        text("training.confidence.\(c.rawValue)")
    }
}

// MARK: - Model

/// Pure selection logic: which insight the widget shows and in which state.
/// An uncertain state never exposes a confidence figure as if it were reliable.
struct TrainingAdviceModel: Equatable {
    enum Phase: Equatable {
        case loading
        case absent
        /// Not enough history yet (load-ratio calibration).
        case calibration
        /// Another insufficient-data insight, nothing reliable to say.
        case insufficient
        /// An ok insight resting on low confidence or partial inputs.
        case partial
        case ready
        case contradictory
    }

    let phase: Phase
    let insight: TrainingInsight?
    let all: [TrainingInsight]

    static let dataQualityNotes: Set<String> = ["training.note.low_confidence_inputs", "training.note.sleep_low_coverage"]

    static func make(insights: [TrainingInsight], isLoading: Bool) -> TrainingAdviceModel {
        if insights.isEmpty {
            return TrainingAdviceModel(phase: isLoading ? .loading : .absent, insight: nil, all: [])
        }
        // A contradiction takes priority over any ok insight; otherwise the first ok insight.
        if let conflict = insights.first(where: { $0.state == .contradictory }) {
            return TrainingAdviceModel(phase: .contradictory, insight: conflict, all: insights)
        }
        if let pick = insights.first(where: { $0.state == .ok }) {
            let partial = pick.confidence == .low
                || pick.detailNoteKeys.contains(where: dataQualityNotes.contains)
            return TrainingAdviceModel(phase: partial ? .partial : .ready, insight: pick, all: insights)
        }
        // Only insufficient insights: prefer the load-ratio calibration message.
        if let calib = insights.first(where: { $0.shortKey.hasSuffix("calibration") }) {
            return TrainingAdviceModel(phase: .calibration, insight: calib, all: insights)
        }
        return TrainingAdviceModel(phase: isLoading ? .loading : .insufficient, insight: insights.first, all: insights)
    }

    /// A contradictory insight exists but the displayed one is not it.
    var hasHiddenConflict: Bool {
        guard let insight else { return false }
        return all.contains { $0.state == .contradictory && $0 != insight }
    }

    /// Confidence is only shown for states that make a statement.
    var showsConfidence: Bool {
        switch phase {
        case .ready, .partial, .contradictory: return insight != nil
        default: return false
        }
    }
}

// MARK: - Widget

/// "Conseil du jour": the first statable training insight, with its confidence, and a link to the
/// detail page. Answers "what does my training data say today, and how far can I trust it?" —
/// something no other Today widget shows. Read-only.
struct TrainingAdviceWidget: View {
    let insights: [TrainingInsight]
    let isLoading: Bool
    /// Displayed day ("yyyy-MM-dd"); nil = today.
    var day: String? = nil

    private var tense: AdviceTense { AdviceTense.of(day: day) }
    private var strings: [String: String] { TrainingAdviceStrings.table(for: tense) }

    private var model: TrainingAdviceModel { .make(insights: insights, isLoading: isLoading) }

    var body: some View {
        let m = model
        Group {
            if m.insight != nil, m.phase != .loading {
                NavigationLink(value: TodayRoute.trainingAdvice) { card(m) }
                    .buttonStyle(.plain)
            } else {
                card(m)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(m))
        .accessibilityAddTraits(m.insight != nil && m.phase != .loading ? .isButton : [])
    }

    private func card(_ m: TrainingAdviceModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetLabel(symbol: symbol(m.phase),
                        title: strings["training.widget.title"] ?? "",
                        showsChevron: m.insight != nil && m.phase != .loading,
                        tint: tint(m.phase))

            if let badge = badgeKey(m.phase) {
                Text(TrainingAdviceStrings.text(badge))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(bodyText(m))
                .font(.subheadline)
                .foregroundStyle(m.phase == .loading ? .secondary : .primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if m.phase == .loading {
                ProgressView().controlSize(.small)
            }

            if m.showsConfidence, let insight = m.insight {
                TrainingConfidenceRow(confidence: insight.confidence, experimental: insight.isExperimental)
            } else if m.phase == .calibration || m.phase == .insufficient {
                Text(TrainingAdviceStrings.text("training.confidence.none"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if m.hasHiddenConflict {
                Label(TrainingAdviceStrings.text("training.widget.other_conflict"), systemImage: "arrow.left.arrow.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if tense == .past {
                Label(TrainingAdviceStrings.pastDayNote, systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetSurface()
    }

    private func bodyText(_ m: TrainingAdviceModel) -> String {
        switch m.phase {
        case .loading: return TrainingAdviceStrings.text("training.widget.loading")
        case .absent: return TrainingAdviceStrings.text("training.widget.absent.body")
        default:
            guard let insight = m.insight else { return TrainingAdviceStrings.text("training.widget.absent.body") }
            return TrainingInsightRenderer.short(insight, strings: strings)
        }
    }

    private func badgeKey(_ phase: TrainingAdviceModel.Phase) -> String? {
        switch phase {
        case .absent: return "training.widget.absent.title"
        case .calibration: return "training.widget.calibration.badge"
        case .insufficient: return "training.widget.insufficient.badge"
        case .partial: return "training.widget.partial.badge"
        case .contradictory: return "training.widget.contradictory.badge"
        case .loading, .ready: return nil
        }
    }

    private func symbol(_ phase: TrainingAdviceModel.Phase) -> String {
        switch phase {
        case .contradictory: return "arrow.left.arrow.right"
        case .calibration: return "gauge.with.dots.needle.0percent"
        case .loading: return "hourglass"
        default: return "lightbulb.fill"
        }
    }

    private func tint(_ phase: TrainingAdviceModel.Phase) -> Color? {
        switch phase {
        case .contradictory: return Pop.orange
        case .ready: return Pop.blue
        default: return nil
        }
    }

    private func accessibilityText(_ m: TrainingAdviceModel) -> String {
        var parts = [strings["training.widget.title"] ?? ""]
        if tense == .past { parts.append(TrainingAdviceStrings.pastDayNote) }
        if let badge = badgeKey(m.phase) { parts.append(TrainingAdviceStrings.text(badge)) }
        parts.append(bodyText(m))
        if m.showsConfidence, let c = m.insight?.confidence {
            parts.append("\(TrainingAdviceStrings.text("training.confidence.label")) \(TrainingAdviceStrings.confidenceWord(c))")
        } else if m.phase == .calibration || m.phase == .insufficient {
            parts.append(TrainingAdviceStrings.text("training.confidence.none"))
        }
        if m.hasHiddenConflict { parts.append(TrainingAdviceStrings.text("training.widget.other_conflict")) }
        if m.insight != nil, m.phase != .loading { parts.append(TrainingAdviceStrings.text("training.widget.cta")) }
        return parts.joined(separator: ". ")
    }
}

/// Three-step meter + word. The word carries the meaning (not colour alone); steps are decorative.
struct TrainingConfidenceRow: View {
    let confidence: TrainingConfidence
    var experimental: Bool = false

    private var level: Int {
        switch confidence { case .low: return 1; case .medium: return 2; case .high: return 3 }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(i < level ? Color.primary.opacity(0.75) : Color.primary.opacity(0.15))
                        .frame(width: 16, height: 5)
                }
            }
            .accessibilityHidden(true)

            Text("\(TrainingAdviceStrings.text("training.confidence.label")) \(TrainingAdviceStrings.confidenceWord(confidence))")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            if experimental { TrainingExperimentalPill() }
        }
    }
}

struct TrainingExperimentalPill: View {
    var body: some View {
        Text(TrainingAdviceStrings.text("training.experimental"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 1))
    }
}

/// State badge + confidence (or "not evaluable") + experimental pill for one insight. Shared by the
/// detail page's other readings and the strain analysis card so every surface states the same thing.
struct TrainingInsightStatus: View {
    let insight: TrainingInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let badge = TrainingAdviceStrings.stateBadgeKey(insight) {
                Text(TrainingAdviceStrings.text(badge))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if insight.state == .insufficientData {
                HStack(spacing: 8) {
                    Text(TrainingAdviceStrings.text("training.confidence.none"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if insight.isExperimental { TrainingExperimentalPill() }
                }
            } else {
                TrainingConfidenceRow(confidence: insight.confidence, experimental: insight.isExperimental)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
enum TrainingAdvicePreviewData {
    static func insight(_ code: String, _ state: TrainingInsightState, _ conf: TrainingConfidence,
                        short: String, detail: String, facts: [TrainingFact] = [],
                        notes: [String] = [], contributors: [String] = ["acute_ewma_7d", "chronic_ewma_28d"]) -> TrainingInsight {
        // TrainingInsight has no public memberwise init: build previews through its Codable form.
        struct Payload: Encodable {
            let code: String, state: TrainingInsightState, confidence: TrainingConfidence
            let facts: [TrainingFact], contributors: [String]
            let shortKey: String, detailKey: String, detailNoteKeys: [String], isExperimental: Bool
        }
        let payload = Payload(code: code, state: state, confidence: conf, facts: facts, contributors: contributors,
                              shortKey: short, detailKey: detail, detailNoteKeys: notes, isExperimental: false)
        return try! JSONDecoder().decode(TrainingInsight.self, from: JSONEncoder().encode(payload))
    }
    static let ok = insight(TrainingInsightCode.loadRatio, .ok, .high,
                            short: "training.load_ratio.stable.short", detail: "training.load_ratio.stable.detail",
                            facts: [.init(key: "ratio", value: 1.05, decimals: 2), .init(key: "acute", value: 9.1, decimals: 1),
                                    .init(key: "chronic", value: 8.7, decimals: 1), .init(key: "data_days", value: 28, unit: "j"),
                                    .init(key: "acute_days", value: 7), .init(key: "chronic_days", value: 28)])
    static let calibration = insight(TrainingInsightCode.loadRatio, .insufficientData, .low,
                                     short: "training.load_ratio.calibration.short", detail: "training.load_ratio.calibration.detail",
                                     facts: [.init(key: "data_days", value: 9), .init(key: "required_days", value: 21), .init(key: "chronic_days", value: 28)],
                                     contributors: ["calibration"])
    static let partial = insight(TrainingInsightCode.loadRatio, .ok, .low,
                                 short: ok.shortKey, detail: ok.detailKey, facts: ok.facts,
                                 notes: ["training.note.low_confidence_inputs"], contributors: ["acute_ewma_7d", "low_confidence_inputs"])
    static let contradictory = insight(TrainingInsightCode.sleepRecoveryConflict, .contradictory, .medium,
                                       short: "training.conflict.sleep_low_recovery_high.short", detail: "training.conflict.sleep_low_recovery_high.detail",
                                       facts: [.init(key: "sleep_last_h", value: 5.4, decimals: 1), .init(key: "sleep_delta_h", value: 1.6, decimals: 1),
                                               .init(key: "sleep_reference_h", value: 7.0, decimals: 1), .init(key: "delta_mad", value: 2.1, decimals: 1),
                                               .init(key: "recovery_score", value: 78)],
                                       notes: ["training.note.experimental_recovery"], contributors: ["sleep_duration_vs_personal_reference", "recovery_score"])
}

#Preview("États") {
    ScrollView {
        VStack(spacing: 14) {
            TrainingAdviceWidget(insights: [], isLoading: true)
            TrainingAdviceWidget(insights: [], isLoading: false)
            TrainingAdviceWidget(insights: [TrainingAdvicePreviewData.calibration], isLoading: false)
            TrainingAdviceWidget(insights: [TrainingAdvicePreviewData.partial], isLoading: false)
            TrainingAdviceWidget(insights: [TrainingAdvicePreviewData.ok], isLoading: false)
            TrainingAdviceWidget(insights: [TrainingAdvicePreviewData.contradictory], isLoading: false)
        }
        .padding(16)
    }
    .appBackground()
    .environment(\.dynamicTypeSize, .xxxLarge)
}
#endif
