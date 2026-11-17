import SwiftUI

/// Pure-logic model behind the stress page. Reads a `StressSnapshot` (24 h timeline + summary)
/// and exposes the score and band, a decomposition of what's driving stress (autonomic balance
/// via HRV, heart-rate elevation, non-activity baseline), the day's time-in-state split, and a
/// restoration ratio. Value type, no view state.
struct StressCoachModel {
    let snapshot: StressSnapshot

    init(snapshot: StressSnapshot) {
        self.snapshot = snapshot
    }

    private var timeline: [StressPoint] { snapshot.timeline }
    private var summary: StressSummary { snapshot.summary }

    // MARK: - Score & band

    var score: Double? { snapshot.latest?.score ?? summary.avgScore }
    var band: StressBand { StressBand(score: score) }
    var accent: Color { band.color }

    var scoreText: String {
        guard let s = score, s.isFinite else { return "—" }
        return String(format: "%.1f", s)
    }

    var qualityLabel: String { band.label }

    /// 0…1 on the 0–3 scale, for the hero gauge.
    var scoreFraction: Double {
        guard let s = score, s.isFinite else { return 0 }
        return min(max(s / 3.0, 0), 1)
    }

    var latestTimeText: String {
        guard let ts = snapshot.latest?.ts else { return "" }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    var headline: String {
        switch band {
        case .calibrating:
            return String(localized: "today.pas.encore.assez.de.signal.aujourd.hui.pour.evaluer.ton.stress", table: "Today")
        case .low:
            return String(localized: "today.systeme.nerveux.majoritairement.au.calme.aujourd.hui.bonne.recuperation", table: "Today")
        case .steady:
            return String(localized: "today.stress.dans.la.normale.avec.des.pics.ponctuels.rien.d.inhabituel", table: "Today")
        case .high:
            return String(localized: "today.charge.de.stress.soutenue.prevois.des.fenetres.de.recuperation", table: "Today")
        }
    }

    // MARK: - Timeline for chart

    struct TimelinePoint: Identifiable {
        let id = UUID()
        let date: Date
        let score: Double
        let context: String?
    }

    var timelinePoints: [TimelinePoint] {
        timeline.suffix(300).map {
            TimelinePoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)),
                          score: min(max($0.score, 0), 3),
                          context: $0.context)
        }
    }

    var hasTimeline: Bool { timeline.count >= 2 }

    // MARK: - Drivers (why)

    struct Driver: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let weight: Double   // 0…1 relative contribution, for the bar
    }

    private var avgHr: Double? {
        let v = timeline.compactMap(\.hrBpm)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }
    private var avgRmssd: Double? {
        let v = timeline.compactMap(\.rmssdMs)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }
    private var avgMovement: Double? {
        let v = timeline.compactMap(\.movementIntensity)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    /// Ranked contributors to today's stress. Built from the physiological channels the band
    /// itself is computed from, so the user sees *why*, not just *what*.
    var drivers: [Driver] {
        var out: [Driver] = []

        if let rmssd = avgRmssd {
            // Lower HRV → higher autonomic stress. Map ~20–80 ms to weight 1→0.
            let w = clamp((60 - (rmssd - 20)) / 60)
            out.append(Driver(
                title: String(localized: "today.equilibre.autonome.hrv", table: "Today"),
                detail: rmssd < 35
                    ? TodayL.format("today.stress.hrv.low", String(Int(rmssd)))
                    : TodayL.format("today.stress.hrv.good", String(Int(rmssd))),
                weight: w))
        }

        if let hr = avgHr {
            // Elevation above a calm ~60 bpm baseline.
            let w = clamp((hr - 60) / 50)
            out.append(Driver(
                title: String(localized: "today.frequence.cardiaque", table: "Today"),
                detail: TodayL.format("today.stress.hr.average", String(Int(hr))),
                weight: w))
        }

        if let nonAct = summary.avgNonActivityScore {
            let w = clamp(nonAct / 3.0)
            out.append(Driver(
                title: String(localized: "today.stress.hors.activite", table: "Today"),
                detail: nonAct >= 1.0
                    ? TodayL.format("today.final.stress.rest.present", String(format: "%.1f", nonAct))
                    : TodayL.format("today.final.stress.rest.low", String(format: "%.1f", nonAct)),
                weight: w))
        }

        if let mv = avgMovement, mv > 0 {
            out.append(Driver(
                title: String(localized: "today.activite.physique", table: "Today"),
                detail: TodayL.text("today.une.part.du.stress.vient.du.mouvement.pas.de.la.tension.mentale"),
                weight: clamp(mv)))
        }

        return out.sorted { $0.weight > $1.weight }
    }

    var dominantSummary: String {
        guard let top = drivers.first else { return String(localized: "today.signal.limite", table: "Today") }
        return top.title
    }

    var whyNarrative: String {
        guard !drivers.isEmpty else {
            return String(localized: "today.le.stress.combine.ta.frequence.cardiaque.ta.variabilite.hrv.et.ton.niveau.d", table: "Today")
        }
        let restful = (summary.avgNonActivityScore ?? 0) < 1.0
        let lead: String
        switch band {
        case .high:  lead = TodayL.text("today.stress.narrative.high")
        case .steady: lead = TodayL.text("today.stress.narrative.moderate")
        case .low:   lead = TodayL.text("today.stress.narrative.low")
        case .calibrating: lead = TodayL.text("today.stress.narrative.calibrating")
        }
        let tail = restful
            ? TodayL.text("today.stress.narrative.restful")
            : TodayL.text("today.stress.narrative.active")
        return lead + (drivers.first?.title.lowercased() ?? "") + "." + tail
    }

    var explanation: String {
        TodayL.text("today.stress.description")
    }

    // MARK: - Facts

    struct Fact: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let fraction: Double?   // 0…1 for the sub-bar, nil = no bar
    }

    var facts: [Fact] {
        [
            Fact(label: String(localized: "today.moyenne", table: "Today"), value: fmt(summary.avgScore), fraction: summary.avgScore.map { clamp($0 / 3) }),
            Fact(label: "Pic", value: fmt(summary.maxScore), fraction: summary.maxScore.map { clamp($0 / 3) }),
            Fact(label: TodayL.text("today.remaining.rest"), value: fmt(summary.avgNonActivityScore), fraction: summary.avgNonActivityScore.map { clamp($0 / 3) }),
            Fact(label: String(localized: "today.fc.moyenne", table: "Today"), value: avgHr.map { "\(Int($0)) bpm" } ?? "—", fraction: avgHr.map { clamp(($0 - 50) / 70) }),
            Fact(label: String(localized: "today.hrv.moyenne", table: "Today"), value: avgRmssd.map { "\(Int($0)) ms" } ?? "—", fraction: avgRmssd.map { clamp($0 / 100) }),
            Fact(label: String(localized: "today.temps.eleve", table: "Today"), value: minutesText(summary.highMinutes), fraction: nil)
        ]
    }

    // MARK: - Time-in-state split

    struct StateSlice: Identifiable {
        let id = UUID()
        let band: StressBand
        let minutes: Double
        let fraction: Double
    }

    /// Estimated minutes spent Bas / Stable / Élevé, derived by attributing the median sampling
    /// interval to each timeline point's band.
    var stateSlices: [StateSlice] {
        guard timeline.count >= 2 else { return [] }
        let intervalMin = medianIntervalMinutes
        var minutes: [StressBand: Double] = [.low: 0, .steady: 0, .high: 0]
        for p in timeline {
            let b = StressBand(score: p.score)
            if b == .calibrating { continue }
            minutes[b, default: 0] += intervalMin
        }
        let total = max(minutes.values.reduce(0, +), 1)
        return [StressBand.low, .steady, .high].map {
            StateSlice(band: $0, minutes: minutes[$0] ?? 0, fraction: (minutes[$0] ?? 0) / total)
        }
    }

    /// Share of measured time spent calm (Bas). The headline number for the balance card.
    var restorationFraction: Double {
        stateSlices.first { $0.band == .low }?.fraction ?? 0
    }

    var restorationText: String {
        guard !stateSlices.isEmpty else { return String(localized: "today.pas.encore.de.repartition", table: "Today") }
        return TodayL.format("today.stress.calm.percent", String(Int((restorationFraction * 100).rounded())))
    }

    var manageTitle: String {
        switch band {
        case .high:  return String(localized: "today.cree.des.fenetres.de.recuperation", table: "Today")
        case .steady: return String(localized: "today.equilibre.tension.et.recuperation", table: "Today")
        case .low:   return String(localized: "today.belle.journee.de.recuperation", table: "Today")
        case .calibrating: return String(localized: "today.en.cours.de.calibrage", table: "Today")
        }
    }

    var manageMessage: String {
        switch band {
        case .high:
            return String(localized: "today.respiration.lente.marche.ou.sieste.courte.abaissent.le.stress.mesure.evite", table: "Today")
        case .steady:
            return String(localized: "today.tes.pics.sont.normaux.insere.de.courtes.pauses.respiratoires.entre.les.bloc", table: "Today")
        case .low:
            return String(localized: "today.profite.de.cet.etat.pour.encaisser.un.effort.ou.consolide.le.par.un.sommeil", table: "Today")
        case .calibrating:
            return String(localized: "today.porte.le.bracelet.en.continu.pour.affiner.la.lecture.de.ton.stress", table: "Today")
        }
    }

    // MARK: - Helpers

    private var medianIntervalMinutes: Double {
        let ts = timeline.map(\.ts).sorted()
        guard ts.count >= 2 else { return 1 }
        let deltas = zip(ts.dropFirst(), ts).map { Double($0 - $1) }.sorted()
        let mid = deltas[deltas.count / 2]
        // Clamp out gaps (strap off) so they don't inflate the split.
        return min(max(mid / 60, 0.5), 10)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }

    private func fmt(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.1f", v)
    }

    private func minutesText(_ m: Double) -> String {
        guard m > 0 else { return "0 min" }
        if m < 60 { return "\(Int(m.rounded())) min" }
        return "\(Int(m / 60)) h \(Int(m.rounded()) % 60)"
    }
}
