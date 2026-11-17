import Foundation

// MARK: - DiagnosticReport
//
// Produit un rapport texte lisible des données calculées localement (jours, nuits, siestes,
// exercices, stress) pour pouvoir le copier dans le presse-papiers et le transférer facilement
// quand une incohérence est détectée. Volontairement compact : exclut les payloads lourds
// (`stages` base64, `hrSamples` brut) qui n'aident pas au repérage d'incohérences.
enum DiagnosticReport {

    typealias DBStats = (decodedRows: Int, decodedRowsTotal: Int, rawBatches: Int, rawBytes: Int, latestTs: Int?)

    /// Construit le rapport texte complet à partir du cache calculé.
    static func make(cache: LoopCache, deviceId: String, dbStats: DBStats?) -> String {
        var out = ""
        let now = Date()

        out += "=== LOOP — RAPPORT DONNÉES CALCULÉES ===\n"
        out += "généré: \(iso(now))\n"
        out += "device: \(deviceId)\n"
        if let s = dbStats {
            out += "lignes décodées: \(s.decodedRows) (total \(s.decodedRowsTotal)) — dernier échantillon: \(s.latestTs.map { iso(Date(timeIntervalSince1970: TimeInterval($0))) } ?? "—")\n"
        }
        out += "dernier calcul: \(cache.updatedAt.map(iso) ?? "—")\n"
        out += "jours=\(cache.daily.count) nuits/sessions sommeil=\(cache.sleepSessions.count) exercices=\(cache.workoutSessions.count)\n"

        // MARK: Jours
        out += "\n--- JOURS ---\n"
        for d in cache.daily.sorted(by: { $0.date < $1.date }) {
            out += "[\(d.date)] "
            out += "sommeil=\(min(d.totalSleepMin)) eff=\(pct(d.efficiency)) "
            out += "deep=\(min(d.deepMin)) rem=\(min(d.remMin)) light=\(min(d.lightMin)) pert=\(d.disturbances.map(String.init) ?? "—") "
            out += "coucher=\(localTime(d.sleepStart)) lever=\(localTime(d.sleepEnd)) score=\(num(d.sleepScore)) | "
            out += "RHR=\(num(d.restingHR)) HRV=\(num(d.avgHrv)) reco=\(num(d.recovery))(\(d.recoveryStatus)/\(d.recoveryBand ?? "—")) strain=\(num(d.strain))\n"
        }

        // MARK: Sessions sommeil (nuits + siestes)
        out += "\n--- SESSIONS SOMMEIL (nuit/sieste) ---\n"
        for s in cache.sleepSessions.sorted(by: { $0.startTs < $1.startTs }) {
            let durMin = Double(s.endTs - s.startTs) / 60
            let kind = durMin < 180 ? "sieste?" : "nuit"
            out += "\(localDateTime(Double(s.startTs))) → \(localTime(Double(s.endTs))) "
            out += "durée=\(Int(durMin.rounded()))min [\(kind)] eff=\(pct(s.efficiency)) RHR=\(s.restingHr.map(String.init) ?? "—") HRV=\(num(s.avgHrv))\n"
        }

        // MARK: Exercices
        out += "\n--- EXERCICES ---\n"
        if cache.workoutSessions.isEmpty {
            out += "(aucun)\n"
        }
        for w in cache.workoutSessions.sorted(by: { $0.startTs < $1.startTs }) {
            let durMin = w.durationS.map { $0 / 60 } ?? (w.endTs - w.startTs) / 60
            out += "\(localDateTime(Double(w.startTs))) → \(localTime(Double(w.endTs))) "
            out += "durée=\(durMin)min type=\(w.kind ?? "—") avgHR=\(num(w.avgHr)) peakHR=\(w.peakHr.map(String.init) ?? "—") strain=\(num(w.strain)) kcal=\(num(w.caloriesKcal))\n"
        }

        // MARK: Stress
        if let st = cache.stress {
            out += "\n--- STRESS (\(st.date)) ---\n"
            out += "moy=\(num(st.summary.avgScore)) moy(hors activité)=\(num(st.summary.avgNonActivityScore)) max=\(num(st.summary.maxScore)) "
            out += "min haut=\(Int(st.summary.highMinutes.rounded())) min activité=\(Int(st.summary.activityMinutes.rounded())) points=\(st.timeline.count)\n"
        }

        return out
    }

    // MARK: - Formatters

    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso(_ d: Date) -> String { isoFmt.string(from: d) }

    private static func localDateTime(_ ts: Double?) -> String {
        guard let ts else { return "—" }
        let d = Date(timeIntervalSince1970: ts)
        return d.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
    }

    private static func localTime(_ ts: Double?) -> String {
        guard let ts else { return "—" }
        let d = Date(timeIntervalSince1970: ts)
        return d.formatted(.dateTime.hour().minute())
    }

    private static func num(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f", v)
    }

    private static func min(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))min"
    }

    private static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        // efficiency peut être 0–1 ou 0–100 selon la source ; normalise à %.
        let p = v <= 1.0 ? v * 100 : v
        return String(format: "%.0f%%", p)
    }
}
