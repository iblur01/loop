import Foundation

// MARK: - Supplemental heart rate (Apple Santé → strain)

/// Comble les TROUS du flux FC du bracelet avec une FC externe (Apple Watch / Apple Santé), sans
/// jamais remplacer ni doubler une seconde déjà couverte par le bracelet.
///
/// Le strain est une intégrale temporelle de la FC (TRIMP = Σ durée × poids de zone) : une même
/// seconde ne doit être comptée qu'une fois, quelle que soit la source. Une séance vue à la fois
/// par le bracelet et par la Watch n'ajoute donc rien : le bracelet couvre déjà ces secondes, la
/// Watch n'y est pas utilisée. Seules les périodes sans bracelet (retiré, chargé, hors portée de
/// l'offload) reçoivent la FC externe.
///
/// Chaque échantillon externe est tenu à 1 Hz jusqu'au suivant, borné à `maxHoldSeconds`, puis
/// les secondes couvertes par le bracelet sont retirées. Le résultat est trié par `ts`.
///
/// - Parameters:
///   - band: FC du bracelet (1 Hz), éventuellement non triée.
///   - supplemental: FC externe, éventuellement non triée. Les valeurs non finies ou hors de la plage 25–250 bpm sont ignorées.
/// - Returns: `band` valide inchangé si `supplemental` est vide ; sinon `band` + secondes comblées.
public func mergeSupplementalHR(
    band: [(ts: Double, bpm: Double)],
    supplemental: [(ts: Double, bpm: Double)]
) -> [(ts: Double, bpm: Double)] {
    let validBand = band.filter { $0.ts.isFinite && $0.bpm.isFinite && CardioInputPolicy.heartRateBPM.contains($0.bpm) }
    let sortedExternal = supplemental
        .filter { $0.ts.isFinite && $0.bpm.isFinite && CardioInputPolicy.heartRateBPM.contains($0.bpm) }
        .sorted { $0.ts == $1.ts ? $0.bpm < $1.bpm : $0.ts < $1.ts }
    // Several HealthKit sources can publish readings within the same second. Expand
    // one reading per second so duplicated or sub-second observations cannot inflate
    // the sample count and make an otherwise insufficient series appear complete.
    var external: [(ts: Double, bpm: Double)] = []
    for sample in sortedExternal {
        let second = floor(sample.ts)
        if external.last?.ts == second {
            external[external.count - 1] = (second, sample.bpm)
        } else {
            external.append((second, sample.bpm))
        }
    }
    guard !external.isEmpty else { return validBand }

    let bandTs = validBand.map(\.ts).sorted()
    var filled: [(ts: Double, bpm: Double)] = []
    for (i, sample) in external.enumerated() {
        let next = i + 1 < external.count ? external[i + 1].ts : sample.ts + SupplementalHR.maxHoldSeconds
        let holdEnd = min(next, sample.ts + SupplementalHR.maxHoldSeconds)
        var t = sample.ts
        // Au moins la seconde de l'échantillon lui-même, même si le suivant est plus proche.
        repeat {
            if !isCoveredByBand(t, sortedBandTs: bandTs) {
                filled.append((ts: t, bpm: sample.bpm))
            }
            t += 1
        } while t < holdEnd
    }
    guard !filled.isEmpty else { return validBand }
    return (validBand + filled).sorted { $0.ts < $1.ts }
}

/// Constantes de la fusion FC externe, exposées pour les tests et la documentation.
public enum SupplementalHR {
    /// Durée max pendant laquelle un échantillon externe est tenu. La Watch enregistre la FC
    /// toutes les ~5 s en séance ; 10 s (2× cette cadence) couvre la séance sans inventer de FC
    /// entre deux mesures de fond espacées de plusieurs minutes.
    public static let maxHoldSeconds: Double = 10

    /// Une seconde est « couverte » par le bracelet s'il a un échantillon à ≤ 3 s : c'est le seuil
    /// au-delà duquel `strain()` considère un écart du flux 1 Hz comme un trou (3× la cadence).
    public static let bandCoverageToleranceSeconds: Double = 3
}

/// Recherche dichotomique de l'échantillon bracelet le plus proche de `t`.
private func isCoveredByBand(_ t: Double, sortedBandTs: [Double]) -> Bool {
    guard !sortedBandTs.isEmpty else { return false }
    var lo = 0
    var hi = sortedBandTs.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if sortedBandTs[mid] < t { lo = mid + 1 } else { hi = mid }
    }
    let tol = SupplementalHR.bandCoverageToleranceSeconds
    if lo < sortedBandTs.count, sortedBandTs[lo] - t <= tol { return true }
    if lo > 0, t - sortedBandTs[lo - 1] <= tol { return true }
    return false
}

/// Opt-in source priority inside explicit half-open workout ranges. `preferred`
/// must already be source-selected by the caller. Outside those ranges the band
/// retains priority. Missing preferred readings leave the band available.
/// All output has one reading per second; source originals remain caller-owned.
public func mergePrioritizedHR(
    band: [(ts: Double, bpm: Double)],
    supplemental: [(ts: Double, bpm: Double)],
    preferred: [(ts: Double, bpm: Double)],
    preferredRanges: [(start: Double, end: Double)]
) -> [(ts: Double, bpm: Double)] {
    func seconds(_ series: [(ts: Double, bpm: Double)]) -> [Double: Double] {
        var result: [Double: Double] = [:]
        for sample in series.filter({ $0.ts.isFinite && $0.bpm.isFinite && CardioInputPolicy.heartRateBPM.contains($0.bpm) })
            .sorted(by: { $0.ts == $1.ts ? $0.bpm < $1.bpm : $0.ts < $1.ts }) {
            result[floor(sample.ts)] = sample.bpm
        }
        return result
    }
    let canonicalBand = seconds(band).map { (ts: $0.key, bpm: $0.value) }
    var result = seconds(mergeSupplementalHR(band: canonicalBand, supplemental: supplemental))
    let ranges = preferredRanges.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
    // Expand before range clipping: observations preceding the boundary can support
    // its first seconds, but no preferred hold can escape the caller's window.
    for sample in mergeSupplementalHR(band: [], supplemental: preferred) {
        if ranges.contains(where: { sample.ts >= $0.start && sample.ts < $0.end }) {
            result[sample.ts] = sample.bpm
        }
    }
    return result.map { (ts: $0.key, bpm: $0.value) }.sorted { $0.ts < $1.ts }
}
