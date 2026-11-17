import SwiftUI

// MARK: - Component

/// Fond d'app : uni `bg.base` (spec design §2.1, décision Q3). Remplace l'ancien dégradé bleu nuit,
/// qui donnait ≈1,4:1 sous les titres en mode clair et concurrençait les teintes de métrique.
struct AppBackground: View {
    var body: some View {
        LoopColor.bgBase
            .ignoresSafeArea()
    }
}

extension View {
    /// Applique le fond d'app derrière la vue.
    func appBackground() -> some View {
        background { AppBackground() }
    }
}
