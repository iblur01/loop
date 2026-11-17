import SwiftUI

/// En-tête d'identité : avatar en verre (seul verre de la page, il flotte) et prénom éditable. Sans
/// carte autour. Sans prénom, le titre affiche « Ton profil » en placeholder.
struct ProfileHeader: View {
    @ObservedObject var prefs: UserPreferences

    var body: some View {
        HStack(spacing: 16) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                TextField(NSLocalizedString("profile.header.placeholder", tableName: "Base", comment: ""), text: $prefs.firstName)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(LoopColor.textPrimary)
                    .lineLimit(1)
                    .submitLabel(.done)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var avatar: some View {
        Text(initials)
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .foregroundStyle(LoopColor.textPrimary)
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: .circle)
            .accessibilityHidden(true)
    }

    private var initials: String {
        let trimmed = prefs.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "L" }
        let parts = trimmed.split(separator: " ")
        return String(parts.prefix(2).compactMap(\.first)).uppercased()
    }
}

#Preview {
    ProfileHeader(prefs: .shared)
        .padding(16)
}
