import Foundation

// MARK: - Renderer

/// Fills `{fact_key}` placeholders of a localisation template from an insight's facts.
/// Texts never contain literal numbers: every digit shown comes from `TrainingInsight.facts`.
public enum TrainingInsightRenderer {
    public static func short(_ insight: TrainingInsight,
                             strings: [String: String] = TrainingInsightStrings.fr) -> String {
        render(key: insight.shortKey, facts: insight.facts, strings: strings)
    }

    /// Detail text followed by the note sentences, separated by a space.
    public static func detail(_ insight: TrainingInsight,
                              strings: [String: String] = TrainingInsightStrings.fr) -> String {
        ([insight.detailKey] + insight.detailNoteKeys)
            .map { render(key: $0, facts: insight.facts, strings: strings) }
            .joined(separator: " ")
    }

    /// Unknown key: the key itself is returned. Unknown placeholder: "n/d".
    public static func render(key: String, facts: [TrainingFact],
                              strings: [String: String] = TrainingInsightStrings.fr) -> String {
        guard let template = strings[key] else { return key }
        var out = ""
        var name: String?
        for ch in template {
            if let current = name {
                if ch == "}" {
                    out += facts.first { $0.key == current }?.formatted ?? "n/d"
                    name = nil
                } else {
                    name = current + String(ch)
                }
            } else if ch == "{" {
                name = ""
            } else {
                out.append(ch)
            }
        }
        if let pending = name { out += "{" + pending }
        return out
    }
}

// MARK: - French strings

/// French texts for every key an insight can reference. The app may copy them into its
/// own string catalogue; keys are stable.
public enum TrainingInsightStrings {
    public static let fr: [String: String] = {
        var s: [String: String] = [:]
        func add(_ key: String, _ short: String, _ detail: String) {
            s["training.\(key).short"] = short
            s["training.\(key).detail"] = detail
        }
        // Acute / chronic load
        add("load_ratio.calibration",
            "Charge en calibration : {data_days} jours de données sur {required_days} nécessaires.",
            "Le rapport entre charge récente et charge habituelle n'est affiché qu'à partir de {required_days} jours de données de charge sur les {chronic_days} derniers jours. Il y en a {data_days} pour l'instant : aucune conclusion n'est tirée.")
        add("load_ratio.norecent",
            "Pas de charge récente connue (dernière valeur il y a {days_since_last} jours).",
            "Le rapport charge récente sur charge habituelle n'est pas calculé sans donnée sur les {acute_days} derniers jours.")
        add("load_ratio.unavailable",
            "Rapport de charge indisponible : charge habituelle quasi nulle.",
            "La charge habituelle lissée ({chronic}) est trop proche de zéro pour calculer un rapport fiable.")
        add("load_ratio.high",
            "Charge récente nettement supérieure à votre habitude (rapport {ratio}).",
            "La charge cardio lissée sur {acute_days} jours ({acute}) vaut {ratio} fois celle lissée sur {chronic_days} jours ({chronic}), sur {data_days} jours de données.")
        add("load_ratio.rising",
            "Charge récente un peu supérieure à votre habitude (rapport {ratio}).",
            "La charge cardio lissée sur {acute_days} jours ({acute}) vaut {ratio} fois celle lissée sur {chronic_days} jours ({chronic}), sur {data_days} jours de données.")
        add("load_ratio.stable",
            "Charge récente proche de votre habitude (rapport {ratio}).",
            "La charge cardio lissée sur {acute_days} jours ({acute}) vaut {ratio} fois celle lissée sur {chronic_days} jours ({chronic}), sur {data_days} jours de données.")
        add("load_ratio.low",
            "Charge récente inférieure à votre habitude (rapport {ratio}).",
            "La charge cardio lissée sur {acute_days} jours ({acute}) vaut {ratio} fois celle lissée sur {chronic_days} jours ({chronic}), sur {data_days} jours de données.")
        s["training.note.low_confidence_inputs"] =
            "Plus de la moitié des charges quotidiennes utilisées ont une confiance faible ({low_confidence_pct} %), ce qui limite la portée de cette lecture."

        // Monotony
        add("monotony.insufficient",
            "Variété de la charge : {known_days} jours connus sur {window_days}, {required_days} nécessaires.",
            "La monotonie (moyenne divisée par l'écart-type de la charge quotidienne) exige au moins {required_days} jours de charge connus sur les {window_days} derniers jours. Les jours sans donnée ne sont pas comptés comme zéro.")
        add("monotony.undefined",
            "Variété de la charge non calculable : charge identique chaque jour connu.",
            "Sur {known_days} jours connus parmi les {window_days} derniers, la charge quotidienne ne varie pas : l'écart-type est nul et la monotonie n'est pas définie.")
        add("monotony.high",
            "Charge quotidienne peu variée sur la semaine (monotonie {monotony}).",
            "Sur {known_days} jours connus parmi les {window_days} derniers, la monotonie est de {monotony}, au-dessus du repère de {threshold}. Cela décrit la régularité des charges, pas un niveau de risque.")
        add("monotony.normal",
            "Charge quotidienne variée sur la semaine (monotonie {monotony}).",
            "Sur {known_days} jours connus parmi les {window_days} derniers, la monotonie est de {monotony}, sous le repère de {threshold}. Cela décrit la régularité des charges, pas un niveau de risque.")

        // Regularity
        add("regularity.insufficient",
            "Régularité : historique trop court ({tracked_days} jours sur {required_days}).",
            "Au moins {required_days} jours d'historique sont nécessaires pour évaluer la régularité des séances ; {tracked_days} sont disponibles.")
        add("regularity.none",
            "Aucune séance enregistrée sur la période récente.",
            "Aucune séance sur les {tracked_days} derniers jours suivis ; la dernière remonte à {days_since_last} jours.")
        add("regularity.single",
            "Une seule journée active sur {tracked_days} jours suivis.",
            "{active_days} jour avec séance sur {tracked_days} jours suivis ; dernière séance il y a {days_since_last} jours. L'espacement n'est pas calculable avec un seul jour actif.")
        add("regularity.ok",
            "{active_days} jours actifs sur {tracked_days} jours suivis.",
            "{active_days} jours avec séance sur {tracked_days} jours suivis. Le plus grand écart entre deux jours actifs est de {max_gap_days} jours ; dernière séance il y a {days_since_last} jours.")

        // Sleep trend
        add("sleep_trend.insufficient",
            "Tendance du sommeil : données insuffisantes.",
            "{recent_n} nuits récentes (au moins {required_recent} requises) et {reference_n} nuits de référence (au moins {required_reference} requises).")
        for (dir, word) in [("down", "inférieure à"), ("up", "supérieure à"), ("stable", "proche de")] {
            add("sleep_trend.\(dir)",
                "Durée de sommeil récente \(word) votre référence ({sleep_recent_h} h contre {sleep_reference_h} h).",
                "Médiane des {recent_days} derniers jours : {sleep_recent_h} h, contre {sleep_reference_h} h sur les {reference_days} jours précédents, soit un écart de {sleep_delta_h} h ({delta_mad} MAD). Écart calculé sur {recent_n} nuits récentes et {reference_n} nuits de référence.")
        }
        s["training.note.sleep_low_coverage"] =
            "La couverture du sommeil est partielle (environ {sleep_coverage_pct} %), ce qui réduit la confiance."

        // Contradictions
        add("conflict.sleep_low_recovery_high",
            "Signaux contradictoires : sommeil court mais récupération élevée.",
            "La dernière nuit ({sleep_last_h} h) est inférieure de {sleep_delta_h} h à votre référence ({sleep_reference_h} h, écart de {delta_mad} MAD), alors que le score de récupération est de {recovery_score}. Ces deux indicateurs ne vont pas dans le même sens : ne tirez pas de conclusion d'un seul d'entre eux.")
        add("conflict.sleep_ok_recovery_low",
            "Signaux contradictoires : sommeil habituel mais récupération basse.",
            "La dernière nuit ({sleep_last_h} h) reste proche de votre référence ({sleep_reference_h} h), alors que le score de récupération est de {recovery_score}. Ces deux indicateurs ne vont pas dans le même sens : ne tirez pas de conclusion d'un seul d'entre eux.")
        add("conflict.feeling_low_recovery_high",
            "Signaux contradictoires : ressenti bas mais récupération élevée.",
            "Votre ressenti ({feeling} sur {feeling_max}) est bas alors que le score de récupération est de {recovery_score}.")
        add("conflict.feeling_high_recovery_low",
            "Signaux contradictoires : bon ressenti mais récupération basse.",
            "Votre ressenti ({feeling} sur {feeling_max}) est bon alors que le score de récupération est de {recovery_score}.")
        s["training.note.experimental_recovery"] =
            "Le score de récupération est expérimental."

        // Volume per sport
        let sports: [(String, String)] = [("run", "course"), ("swim", "natation"), ("strength", "musculation")]
        for (key, label) in sports {
            add("volume.\(key).insufficient",
                "Volume de \(label) : historique trop court ({tracked_days} jours sur {required_days}).",
                "Il faut au moins {required_days} jours d'historique pour comparer le volume récent à votre habitude ; {tracked_days} sont disponibles.")
            let detail = "Séances de \(label) sur {recent_days} jours : {recent_sessions}, contre {prior_sessions_mean} en moyenne par période de {recent_days} jours sur les {prior_days} jours précédents."
            add("volume.\(key).up", "Volume de \(label) en hausse par rapport à votre habitude.", detail)
            add("volume.\(key).down", "Volume de \(label) en baisse par rapport à votre habitude.", detail)
            add("volume.\(key).stable", "Volume de \(label) stable par rapport à votre habitude.", detail)
        }
        s["training.note.volume_minutes"] =
            "Durée cumulée : {recent_minutes} min sur {recent_days} jours, contre {prior_minutes_mean} min en moyenne par période précédente."
        s["training.note.volume_srpe"] =
            "Charge d'effort perçu (sRPE multiplié par la durée) : {srpe_load_recent} unités arbitraires sur {recent_days} jours."
        s["training.note.no_hr_strength"] =
            "La musculation n'est pas évaluée par la fréquence cardiaque : seuls le nombre de séances, leur durée et l'effort perçu (sRPE) fournis sont utilisés."
        s["training.note.no_hr_swim"] =
            "En natation, la fréquence cardiaque n'est pas utilisée pour estimer l'intensité : seul le volume est comparé."

        // Change detection
        let metrics: [(String, String)] = [("load", "charge cardio quotidienne"), ("sleep", "durée de sommeil"),
                                           ("recovery", "score de récupération")]
        let changeDetail = "Une somme cumulative (CUSUM) atteint {statistic} pour un seuil de {threshold}, sur {recent_points} points des {recent_days} derniers jours comparés à {reference_points} points de référence. Début estimé il y a {onset_days_ago} jours. Détection statistique à confirmer dans la durée."
        for (key, label) in metrics {
            add("change.\(key).up", "Changement détecté : \(label) plus élevée que votre référence.", changeDetail)
            add("change.\(key).down", "Changement détecté : \(label) plus basse que votre référence.", changeDetail)
        }

        // Exploratory links
        let links: [(String, String)] = [
            ("load_sleep", "Charge du jour et durée de sommeil de la nuit suivante"),
            ("load_recovery", "Charge du jour et récupération du lendemain"),
            ("sleep_recovery", "Durée de sommeil et récupération"),
            ("efficiency_recovery", "Efficacité du sommeil et récupération")
        ]
        let linkDetail = "Corrélation de rang (Spearman) de {rho_abs} en valeur absolue sur {n} paires de jours, intervalle approximatif de {ci_abs_low} à {ci_abs_high}."
        for (key, label) in links {
            add("link.\(key).pos", "\(label) : tendance à évoluer dans le même sens.", linkDetail)
            add("link.\(key).neg", "\(label) : tendance à évoluer en sens inverse.", linkDetail)
            add("link.\(key).insufficient", "\(label) : données insuffisantes.",
                "{n} paires de jours disponibles, au moins {required_n} requises pour une corrélation exploratoire.")
        }
        s[LinkStat.noteKey] = "Corrélation exploratoire, pas une causalité."
        return s
    }()
}
