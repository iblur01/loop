import SwiftUI

// Couleurs des bandes de récupération, tirées des tokens (`HealthState`). Séparées de
// `RecoveryCoachModel.swift`, que Tools/LoopReplay compile sans l'UI.

extension RecoveryBand {
    /// Evaluation shared with every recovery surface (spec design §2.4).
    var state: HealthState {
        switch self {
        case .green:       return .good
        case .yellow:      return .fair
        case .red:         return .poor
        case .calibrating: return .neutral
        }
    }

    var color: Color { state.color }
}

extension RecoveryDeltaDirection {
    var color: Color {
        switch self {
        case .better:   return HealthState.good.color
        case .worse:    return HealthState.poor.color
        case .neutral:  return HealthState.neutral.color
        }
    }
}
