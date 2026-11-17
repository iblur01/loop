import Foundation

/// Série FC d'une séance pour la courbe. Les zones ne passent pas par ici : elles sont lues
/// telles quelles dans `WorkoutSession.heartRateZones` (calculées par le moteur). La série FC
/// complète d'une séance n'est pas dans le cache : tant qu'aucun fournisseur ne la remplit, la
/// courbe reste masquée.
struct WorkoutHeartRateProfile: Equatable {
    struct Point: Equatable {
        let ts: Int
        let bpm: Double
    }

    let samples: [Point]

    var hasCurve: Bool { samples.filter { $0.bpm.isFinite && $0.bpm > 0 }.count >= 2 }
}

/// Tracé GPS d'une séance. Loop n'importe pas encore `HKWorkoutRoute` : jamais fourni pour l'instant.
struct WorkoutRoute: Equatable {
    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    let coordinates: [Coordinate]

    var isDrawable: Bool {
        coordinates.filter { $0.latitude.isFinite && $0.longitude.isFinite }.count >= 2
    }
}
