import SwiftUI

/// Une seule action : « Recalculer » (recalcul incrémental). Le recalcul total vit dans Avancé,
/// avec confirmation. Pendant un calcul, la carte devient une surface de progression avec annulation.
struct RecalcCard: View {
    @ObservedObject var repository: LoopDataRepository

    private var disabled: Bool { repository.localMetricsEngine == nil }

    var body: some View {
        VStack(spacing: 16) {
            if repository.isRefreshing {
                progress
            } else {
                primary
                if let err = repository.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Primary

    private var primary: some View {
        Button { repository.requestRefresh(force: false) } label: { primaryLabel }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(disabled)
    }

    private var primaryLabel: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(NSLocalizedString("Recalculer", tableName: "Base", comment: ""))
                .font(.body.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(repository.refreshIsFull ? NSLocalizedString("Recalcul total…", tableName: "Base", comment: "") : NSLocalizedString("Recalcul rapide…", tableName: "Base", comment: ""))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let p = repository.computeProgress {
                    Text("\(p.completed)/\(p.total)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let p = repository.computeProgress {
                ProgressView(value: Double(p.completed), total: Double(max(p.total, 1)))
                Text(p.stage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            Button(NSLocalizedString("Annuler", tableName: "Base", comment: "")) { repository.cancelRefresh() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .buttonStyle(.plain)
        }
        .padding(18)
        .deviceSurface()
    }
}

#Preview {
    RecalcCard(repository: LoopDataRepository())
        .padding()
}
