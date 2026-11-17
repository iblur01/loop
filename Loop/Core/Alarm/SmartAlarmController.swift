import Foundation
import Combine

/// Pilote l'alarme 2-couches du bracelet.
///
/// Couche 1 — **firmware RTC** (`SET_ALARM_TIME`) : garantie, vibre même app tuée / iPhone verrouillé.
/// Couche 2 — **smart-wake** (mode `.smart` uniquement) : sur une fenêtre `leadMinutes` avant l'heure
/// cible, on entre en flux HR dense (`ENTER_HIGH_FREQ_SYNC`) et on déclenche tôt (`RUN_ALARM`) dès
/// qu'on détecte un éveil naissant (montée du HR ≥ `hrRiseThreshold`).
///
/// INVARIANT CRITIQUE : `EXIT_HIGH_FREQ_SYNC` doit être envoyé sur TOUS les chemins de sortie du
/// smart-wake (succès, timeout, annulation, erreur, passage en arrière-plan) — sinon le bracelet reste
/// en mode high-freq et draine sa batterie. Garanti ici par un `defer` dans la tâche smart-wake.
@MainActor
final class SmartAlarmController: ObservableObject {

    @Published private(set) var isArmed = false
    @Published private(set) var nextFireDate: Date?

    /// Fenêtre HR observée pour détecter l'éveil ; montée ≥ ce seuil → déclenche tôt.
    private let hrRiseThreshold = 5
    private let prefs = UserPreferences.shared

    private var smartWakeTask: Task<Void, Never>?

    // MARK: - Arm / disarm

    /// Calcule le prochain déclenchement depuis la config, met le bracelet à l'heure (UTC) puis arme
    /// l'alarme firmware. En mode `.smart`, planifie aussi l'overlay smart-wake.
    func arm(using connection: DeviceConnectionViewModel) {
        smartWakeTask?.cancel()
        smartWakeTask = nil

        guard prefs.alarmEnabled, prefs.alarmMode != .off,
              let fireDate = computeNextFireDate() else {
            isArmed = false
            nextFireDate = nil
            return
        }

        nextFireDate = fireDate
        isArmed = true

        // SET_CLOCK avant SET_ALARM_TIME : RTC strap UTC-correct, sinon l'alarme fire au mauvais moment.
        connection.bleManager.send(.setClock, payload: BLEBondingHandshake.setClockPayload())
        let epoch = UInt32(fireDate.timeIntervalSince1970)
        connection.bleManager.send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epoch))

        if prefs.alarmMode == .smart {
            scheduleSmartWake(fireDate: fireDate, leadMinutes: prefs.alarmLeadMinutes, connection: connection)
        }
    }

    /// Désarme : annule l'alarme firmware, coupe le smart-wake et sort du high-freq par sécurité.
    func disarm(using connection: DeviceConnectionViewModel) {
        smartWakeTask?.cancel()
        smartWakeTask = nil
        connection.bleManager.send(.disableAlarm, payload: [0x01])
        connection.bleManager.send(.exitHighFreqSync, payload: [0x00])
        isArmed = false
        nextFireDate = nil
    }

    /// Ré-arme si l'alarme est activée et que le déclenchement précédent est passé (ou rien d'armé).
    /// Appelé au foreground et à la connexion pour récupérer une alarme perdue (reboot strap, etc.).
    func rearmIfNeeded(using connection: DeviceConnectionViewModel) {
        guard prefs.alarmEnabled, prefs.alarmMode != .off else {
            if isArmed { disarm(using: connection) }
            return
        }
        if let next = nextFireDate, next > Date(), smartWakeTask != nil || prefs.alarmMode == .regular {
            return
        }
        arm(using: connection)
    }

    // MARK: - Test buzz

    /// Buzz immédiat pour tester l'alarme. WHOOP 4.0 n'a qu'un seul motif de vibration d'alarme
    /// (`RUN_ALARM`) ; les `runHapticsPattern` sont des haptics de notification, pas l'alarme.
    func testBuzz(using connection: DeviceConnectionViewModel) {
        connection.bleManager.send(.runAlarm, payload: [0x01])
    }

    // MARK: - Scheduling

    func computeNextFireDate(now: Date = Date()) -> Date? {
        AlarmScheduler.nextFireDate(
            hour: prefs.alarmHour,
            minute: prefs.alarmMinute,
            weekdays: prefs.alarmWeekdays,
            from: now
        )
    }

    /// Planifie l'overlay smart-wake : attend jusqu'à `fireDate - leadMinutes`, entre en high-freq,
    /// observe le HR sur la fenêtre, déclenche tôt sur éveil détecté, sinon laisse le firmware RTC
    /// prendre le relais à `fireDate`. Sort TOUJOURS du high-freq (defer).
    private func scheduleSmartWake(fireDate: Date, leadMinutes: Int, connection: DeviceConnectionViewModel) {
        let windowStart = fireDate.addingTimeInterval(-Double(leadMinutes) * 60)
        let state = connection.state
        let manager = connection.bleManager
        let threshold = hrRiseThreshold

        smartWakeTask = Task { @MainActor in
            let untilWindow = windowStart.timeIntervalSinceNow
            if untilWindow > 0 {
                try? await Task.sleep(for: .seconds(untilWindow))
            }
            guard !Task.isCancelled else { return }

            manager.send(.enterHighFreqSync, payload: [0x01])
            // INVARIANT : sortie du high-freq garantie quel que soit le chemin (succès/timeout/cancel/erreur).
            defer { manager.send(.exitHighFreqSync, payload: [0x00]) }

            // Course entre le timeout (fireDate, où le firmware RTC prend le relais) et la détection
            // d'éveil (montée HR ≥ threshold → buzz tôt). Le premier qui finit annule l'autre, et le
            // `defer` ci-dessus sort du high-freq dans tous les cas.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    let deadline = fireDate.timeIntervalSinceNow
                    if deadline > 0 { try? await Task.sleep(for: .seconds(deadline)) }
                }
                group.addTask { @MainActor in
                    var baseline: Int?
                    for await hr in state.$heartRate.values {
                        if Task.isCancelled { return }
                        guard let hr else { continue }
                        if let base = baseline {
                            if hr - base >= threshold {
                                manager.send(.runAlarm, payload: [0x01])
                                return
                            }
                            baseline = min(base, hr)
                        } else {
                            baseline = hr
                        }
                    }
                }
                await group.next()
                group.cancelAll()
            }
        }
    }
}
