import Foundation

/// Façade UserDefaults pour l'ordre des sources de la réconciliation. Seules les surcharges de
/// l'utilisateur sont stockées ; tout le reste retombe sur `HealthSourcePriority.default`.
/// Pas de table SQL : la vue fusionnée est calculée à la lecture.
struct HealthReconciliationSettings {
    static let storageKey = "healthReconciliation.sourcePriority.v1"
    /// Clé réservée dans le dictionnaire stocké pour l'ordre des séances.
    static let workoutsKey = "workouts"
    /// Producteurs HealthKit classés par métrique, séparés des priorités par catégorie.
    static let producerStorageKey = "healthReconciliation.producerPriority.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Priorité effective : valeurs par défaut + surcharges stockées. Une donnée illisible ou une
    /// source inconnue est ignorée sans erreur.
    func load() -> HealthSourcePriority {
        var priority = HealthSourcePriority.default
        for (key, order) in storedOverrides() {
            if key == Self.workoutsKey {
                priority.workouts = order
            } else {
                priority.orders[key] = order
            }
        }
        return priority
    }

    /// Remplace l'ordre d'un type (et d'un contexte, si fourni). Les doublons sont retirés ;
    /// une liste vide supprime la surcharge.
    func setOrder(_ order: [HealthDataSource], for kind: HealthSampleKind, context: HealthMeasureContext? = nil) {
        setOverride(order, key: HealthSourcePriority.key(kind, context))
    }

    func setWorkoutOrder(_ order: [HealthDataSource]) {
        setOverride(order, key: Self.workoutsKey)
    }

    /// Ordres explicites par métrique. Une application absente des données du jour conserve sa
    /// place pour les jours suivants ; les sources sans bundle ne sont pas identifiables sûrement.
    func producerOrders() -> [String: [String]] {
        guard let raw = defaults.dictionary(forKey: Self.producerStorageKey) else { return [:] }
        var result: [String: [String]] = [:]
        for (key, value) in raw {
            guard HealthSampleKind(rawValue: key) != nil, let identifiers = value as? [String] else { continue }
            let order = Self.validProducerIDs(identifiers)
            if !order.isEmpty { result[key] = order }
        }
        return result
    }

    func producerOrder(for kind: HealthSampleKind) -> [String] {
        producerOrders()[kind.rawValue] ?? []
    }

    /// Seuls les bundles peuvent être préférés : un nom d'application peut changer ou entrer en
    /// collision. Une liste vide retire la préférence sans toucher aux priorités par catégorie.
    func setProducerOrder(_ order: [String], for kind: HealthSampleKind) {
        var orders = producerOrders()
        let valid = Self.validProducerIDs(order)
        if valid.isEmpty {
            orders.removeValue(forKey: kind.rawValue)
        } else {
            orders[kind.rawValue] = valid
        }
        if orders.isEmpty {
            defaults.removeObject(forKey: Self.producerStorageKey)
        } else {
            defaults.set(orders, forKey: Self.producerStorageKey)
        }
    }

    /// Retire toutes les surcharges (retour aux valeurs par défaut).
    func reset() {
        defaults.removeObject(forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.producerStorageKey)
    }

    // MARK: - Helpers

    private func setOverride(_ order: [HealthDataSource], key: String) {
        var raw = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
        let deduped = Self.dedupe(order)
        if deduped.isEmpty {
            raw.removeValue(forKey: key)
        } else {
            raw[key] = deduped.map(\.rawValue)
        }
        if raw.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(raw, forKey: Self.storageKey)
        }
    }

    private func storedOverrides() -> [String: [HealthDataSource]] {
        guard let raw = defaults.dictionary(forKey: Self.storageKey) as? [String: [String]] else { return [:] }
        var result: [String: [HealthDataSource]] = [:]
        for (key, values) in raw {
            let order = Self.dedupe(values.compactMap(HealthDataSource.init(rawValue:)))
            if !order.isEmpty { result[key] = order }
        }
        return result
    }

    private static func dedupe(_ order: [HealthDataSource]) -> [HealthDataSource] {
        var seen: [HealthDataSource] = []
        for s in order where !seen.contains(s) { seen.append(s) }
        return seen
    }

    private static func validProducerIDs(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { id in
            let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.hasPrefix("bundle:"), normalized.count > "bundle:".count,
                  !normalized.dropFirst("bundle:".count).contains(where: { $0.isWhitespace }),
                  seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
