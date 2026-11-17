import Foundation
import WhoopStore

// MARK: - Catalogue (pur, sans HealthKit)

/// Types Apple Santé lus par Loop. `rawValue` = identifiant HK court stocké dans `health_sample.type`
/// et dans la clé d'ancre "healthkit:<rawValue>". Ne pas renommer : ce serait une rupture de données.
enum HealthSampleKind: String, CaseIterable, Identifiable, Sendable {
    case stepCount
    case heartRate
    case restingHeartRate
    case heartRateVariabilitySDNN
    case activeEnergyBurned
    case basalEnergyBurned
    case distanceWalkingRunning
    case appleExerciseTime
    case vo2Max
    case bodyMass
    case sleepAnalysis

    enum BackgroundCadence: Equatable, Sendable { case immediate, hourly }

    var id: String { rawValue }

    var isCategory: Bool { self == .sleepAnalysis }

    /// Unité de stockage (chaîne stable, indépendante de `HKUnit.unitString`).
    var unit: String {
        switch self {
        case .stepCount: return "count"
        case .heartRate, .restingHeartRate: return "count/min"
        case .heartRateVariabilitySDNN: return "ms"
        case .activeEnergyBurned, .basalEnergyBurned: return "kcal"
        case .distanceWalkingRunning: return "m"
        case .appleExerciseTime: return "min"
        case .vo2Max: return "mL/(kg·min)"
        case .bodyMass: return "kg"
        case .sleepAnalysis: return "HKCategoryValueSleepAnalysis"
        }
    }

    var label: String {
        switch self {
        case .stepCount: return String(localized: "health.sample.steps", table: "Core")
        case .heartRate: return String(localized: "health.sample.heartRate", table: "Core")
        case .restingHeartRate: return String(localized: "health.sample.restingHeartRate", table: "Core")
        case .heartRateVariabilitySDNN: return String(localized: "health.sample.hrv", table: "Core")
        case .activeEnergyBurned: return String(localized: "health.sample.activeEnergy", table: "Core")
        case .basalEnergyBurned: return String(localized: "health.sample.restingEnergy", table: "Core")
        case .distanceWalkingRunning: return String(localized: "health.sample.distance", table: "Core")
        case .appleExerciseTime: return String(localized: "health.sample.exercise", table: "Core")
        case .vo2Max: return "VO2 max"
        case .bodyMass: return String(localized: "health.sample.weight", table: "Core")
        case .sleepAnalysis: return String(localized: "health.sample.sleep", table: "Core")
        }
    }

    /// Les types à haute fréquence (pas, FC, énergie, distance, exercice) sont de toute façon
    /// bridés à l'heure par iOS ; on le demande explicitement pour ménager la batterie. Les types
    /// rares (FC repos, VFC, VO2 max, poids, sommeil) sont demandés en immédiat.
    var backgroundCadence: BackgroundCadence {
        switch self {
        case .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max, .bodyMass, .sleepAnalysis:
            return .immediate
        default:
            return .hourly
        }
    }
}

// MARK: - Mapping (pur)

/// Entrée indépendante de HealthKit, pour tester le mapping sans `HKSample`.
struct HealthSampleInput: Equatable {
    let uuid: String
    let kind: HealthSampleKind
    let start: Date
    let end: Date
    /// Quantité dans `kind.unit`, ou valeur brute de la catégorie.
    let value: Double?
    let sourceName: String?
    let sourceBundle: String?
    /// Valeur de `HealthSampleMapping.originMetadataKey` dans les métadonnées, si présente.
    let originMarker: String?
    /// `sourceRevision.productType` (ex. "Watch6,1"), identité matérielle stable non localisée.
    var productType: String? = nil
    /// `device?.model` (ex. "Watch", "iPhone").
    var deviceModel: String? = nil
}

enum HealthSampleMapping {
    /// Clé de métadonnées que Loop posera sur ses propres écritures (tranche écriture, plus tard).
    static let originMetadataKey = "LoopOrigin"
    static let loopOrigin = "loop"

    /// Retourne nil pour un échantillon inexploitable (dates inversées, valeur absente ou non finie),
    /// qui est alors ignoré à l'import.
    static func map(_ input: HealthSampleInput, importedAt: Date, ownBundleId: String? = nil) -> HealthSample? {
        guard input.end >= input.start else { return nil }
        guard let value = input.value, value.isFinite else { return nil }
        let bundle = clean(input.sourceBundle)
        let marker = clean(input.originMarker)?.lowercased()
        let isLoop = marker == loopOrigin || (bundle != nil && bundle == clean(ownBundleId))
        return HealthSample(
            uuid: input.uuid,
            type: input.kind.rawValue,
            startDate: input.start.timeIntervalSince1970,
            endDate: input.end.timeIntervalSince1970,
            value: value,
            unit: input.kind.unit,
            sourceName: clean(input.sourceName),
            sourceBundle: bundle,
            metadataOrigin: isLoop ? loopOrigin : nil,
            importedAt: importedAt.timeIntervalSince1970,
            productType: clean(input.productType),
            deviceModel: clean(input.deviceModel))
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
