import SwiftUI

/// Une seule ligne calme : quand le moteur local a calculé pour la dernière fois. Les compteurs
/// (jours, sessions, stockage) vivent dans Appareil → Informations avancées.
struct ProfileDataGroup: View {
    @ObservedObject var repository: LoopDataRepository

    var body: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
            Text(NSLocalizedString("Dernier calcul", tableName: "Base", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(formattedDate(repository.cache.updatedAt))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .deviceSurface()
        .accessibilityElement(children: .combine)
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

#Preview {
    ProfileDataGroup(repository: LoopDataRepository())
        .padding()
}
