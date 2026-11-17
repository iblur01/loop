import Foundation

/// Logique pure de calcul du prochain déclenchement d'alarme — sans BLE, sans état, testable.
enum AlarmScheduler {
    /// Prochaine `Date` de déclenchement étant donné l'heure cible + jours actifs.
    ///
    /// - Parameters:
    ///   - hour/minute : heure murale cible (calendrier local).
    ///   - weekdays : indices `Calendar` 1...7 (1=dimanche, 7=samedi). Vide → one-shot : la prochaine
    ///     occurrence de l'heure (aujourd'hui si encore à venir, sinon demain).
    ///   - now : instant de référence (injectable pour les tests).
    /// - Returns: la prochaine `Date` ≥ `now`, ou `nil` si l'heure est invalide.
    static func nextFireDate(hour: Int, minute: Int, weekdays: Set<Int>, from now: Date = Date(),
                             calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        // One-shot : prochaine occurrence de l'heure, peu importe le jour.
        if weekdays.isEmpty {
            guard let todayAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
                return nil
            }
            if todayAt > now { return todayAt }
            return calendar.date(byAdding: .day, value: 1, to: todayAt)
        }

        // Répétitif : balaye jusqu'à 7 jours en avant et retient le 1er jour actif dont l'heure est ≥ now.
        for offset in 0...7 {
            guard
                let candidateDay = calendar.date(byAdding: .day, value: offset, to: now),
                let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: candidateDay)
            else { continue }
            let weekday = calendar.component(.weekday, from: fire)
            guard weekdays.contains(weekday) else { continue }
            if fire > now { return fire }
        }
        return nil
    }
}
