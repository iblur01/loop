import Combine
import SwiftUI

// MARK: - SyncStatusAccessory

/// Statut de sync affiché dans l'accessoire natif de la barre d'onglets (`tabViewBottomAccessory`,
/// capsule Liquid Glass fournie par le système : aucun verre ni matériau ici). Visible pendant la
/// sync, puis brièvement sur l'état final. Une erreur réelle passe en `state.poor` avec son symbole
/// (spec design §4.3) ; le reste est à l'encre.
struct SyncStatusAccessory: View {
    let status: SyncStatus

    var body: some View {
        HStack(spacing: 10) {
            if display.isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: display.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(display.isAlert ? HealthState.poor.color : .primary)
                    .accessibilityHidden(true)
            }
            Text(display.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(display.isAlert ? String(format: String(localized: "sync.alert", table: "Core"), display.text) : display.text)
    }

    private var display: SyncToastDisplay {
        switch status {
        case .syncing:
            return SyncToastDisplay(symbol: "arrow.triangle.2.circlepath", text: String(localized: "sync.syncing", table: "Core"), isActive: true, isAlert: false)
        case .strapStuck:
            return SyncToastDisplay(symbol: HealthState.poor.symbol, text: String(localized: "sync.stuck", table: "Core"), isActive: false, isAlert: true)
        case .error(let msg):
            return SyncToastDisplay(symbol: HealthState.poor.symbol, text: msg, isActive: false, isAlert: true)
        case .offline, .connectedIdle:
            return SyncToastDisplay(symbol: "checkmark.circle.fill", text: String(localized: "sync.current", table: "Core"), isActive: false, isAlert: false)
        }
    }
}

private struct SyncToastDisplay {
    let symbol: String
    let text: String
    let isActive: Bool
    let isAlert: Bool
}

// MARK: - Coordinator

/// Pilote la présentation du `SyncStatusAccessory` : visible pendant la sync, puis brièvement sur l'état final,
/// avant de se retirer seul. Observe `SyncCoordinator.$status`.
@MainActor
final class SyncToastCoordinator: ObservableObject {
    @Published private(set) var isPresented = false

    private var cancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var lastStatus: SyncStatus = .offline

    func observe(_ coordinator: SyncCoordinator) {
        cancellable = coordinator.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.react(to: status) }
    }

    private func react(to status: SyncStatus) {
        defer { lastStatus = status }
        guard status != lastStatus else { return }

        switch status {
        case .syncing:
            present(autoDismissAfter: nil)
        case .error, .strapStuck:
            present(autoDismissAfter: 4)
        case .connectedIdle, .offline:
            // « À jour » seulement après une sync, jamais au repos au lancement.
            if case .syncing = lastStatus { present(autoDismissAfter: 2) }
        }
    }

    private func present(autoDismissAfter seconds: Double?) {
        dismissTask?.cancel()
        isPresented = true
        guard let seconds else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isPresented = false
        }
    }
}
