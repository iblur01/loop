# 02 — Champs / boutons / sections inutiles à supprimer ou rationaliser

## À supprimer (mort/no-op)

| Localisation | Élément | Statut | Action |
|---|---|---|---|
| `SettingsView.swift:21` Section "Account" → Profile | HStack + chevron, aucune destination | Placeholder no-op | **Supprimer** (remplacé par ProfileView) |
| `SettingsView.swift:30` Section "App Settings" → Notifications | HStack + chevron, aucune destination | Placeholder no-op | **Supprimer** (remplacé par ProfileView → Préférences) |
| `SettingsView.swift:38` Section "App Settings" → Appearance | "System" fixe, non modifiable | Placeholder no-op | **Supprimer** (remplacé par ProfileView → Apparence) |
| `SettingsView.swift:52` Section "Sign Out" | Bouton destructeur, action vide `{ }` | No-op | **Supprimer** (pas de compte, offline-first) |
| `RecoveryCoachModel.swift:121` Row `respRow` | Toujours "--" (champ server-only absent) | UI morte | **Supprimer** la row (ou masquer tant que pas de calc local resp) |
| `NoSensorSheet.swift:15` `tutorialURL = "https://www.youtube.com"` | URL générique inutile | Placeholder | **Supprimer** ou remplacer par un tuto réel (markdown in-app ?) |
| `CoachCard.swift:163` `completedCount: Int = 2` | Hardcodé à 2, non branché | Mort | **Mettre à 0** par défaut, ou supprimer le badge |
| `TodayView.swift:34` `name: "Théo"` | Hardcodé | Devrait venir de UserPreferences | **Remplacer** par `prefs.firstName` |

## À déplacer (pas supprimer — change de page)

| Élément | De | Vers | Raison |
|---|---|---|---|
| Tout le contenu de `DeviceView` actuel (firmware, UUID, DB stats, logs, diagnostic, recalcul perf) | `DeviceView.swift:22` | `DeviceAdvancedView` (NEW) | DeviceView devient une page user |
| Sections "Calcul du strain" + "Données" + "Maintenance" + "Debug" | `SettingsView` | `ProfileView → Settings` (strain/données) et `AdvancedView` (debug) | Séparation user/dev |
| Sections "Sauvegarde" | `SettingsView` | `ProfileView → Settings → BackupView` | Plus propre |
| `DateNavigator` (répété 4×) | Today + 3 details | Composant shared unique | DRY (déjà factorisé, juste s'assurer qu'il n'y a qu'une implé) |

## À rationaliser (doublons techniques)

| Élément | Fichiers | Action |
|---|---|---|
| `MetricsGlassShell`, `CoachGlassShell`, `StressGlassShell`, `BraceletSyncGlassShell`, `DeviceCardGlassShell`, `ActivityGlassShell`, `ExpressGlassShell` | 7 fichiers | **Fusionner** en une `LoopGlassShell(accent:)` partagée (elles sont quasi-identiques) |
| `RecoveryHeroCard` + `StrainHeroCard` | `RecoveryCoachModel.swift`, `StrainCoachModel.swift` | Structure Hero/Metrics/Insight identique → envisager un `MetricFamilyDetailView` générique paramétré |
| `RecoveryMetricsCard` + `StrainMetricsCard` | idem | Même row layout → `MetricRowView` partagé |
| `RecoveryGradientBackdrop` + `StrainGradientBackdrop` | idem | Même structure → `BandGradientBackdrop(band:)` partagé |
| `DeviceSectionHeader` + `ActivityTimelineHeader` | `DeviceSectionHeader.swift`, `ActivityTimeline.swift` | Même pattern header (icon + label + divider + badge) → `LoopSectionHeader` partagé |
| `DateFormatter` instanciés par-call | `SleepCoachModel.swift:62`, `ActivityTimeline.swift:162`, `StressCard.swift:24` | Passer en `static let` partagé (quelques-uns le font déjà, généraliser) |

## À traduire (incohérence FR/EN)

| Fichier | Chaîne EN | FR cible |
|---|---|---|
| `CoachCard.swift:192` | "Ease Off Today" | "Modère l'effort aujourd'hui" |
| `CoachCard.swift:200` | "Optimal Health" | "Santé optimale" |
| `CoachCard.swift:207` | "Moderate Day" | "Journée modérée" |
| `CoachCard.swift:213` | "Prioritise Sleep" | "Priorise le sommeil" |
| `CoachCard.swift:218` | "Rest & Recover" | "Repos & récupération" |
| `CoachCard.swift:167` | "No data yet" / "Pull to refresh..." | "Pas encore de données" / "Tirer pour rafraîchir..." |
| `StressCard.swift:165` | "LOW" / "STEADY" / "HIGH" | "BAS" / "STABLE" / "ÉLEVÉ" |
| `StressCard.swift:174` | "CALM LOAD" / "STEADY LOAD" / "ELEVATED LOAD" | "CHARGE CALME" / "CHARGE STABLE" / "CHARGE ÉLEVÉE" |
| `StressCard.swift:110` | "Updated HH:mm" / "No stress data yet" / "Latest estimate" | "Mis à jour HH:mm" / "Pas encore de stress" / "Dernière estimation" |
| `StressCard.swift:124` | "AVG" / "HIGH" / "ACTIVE" | "MOY" / "MAX" / "ACTIF" |
| `DeviceView.swift:40` | "Device Status" | "État de l'appareil" |
| `DeviceView.swift:162` | "Device" (nav title) | "Appareil" |
| `DeviceView.swift:191` | "Connected" / "Connecting…" / "Disconnected" | "Connecté" / "Connexion…" / "Déconnecté" |
| `SettingsView.swift:60` | "Settings" (nav title) | "Réglages" |
| `DateNavigator.swift:299` | "TODAY" | "AUJ." (ou garder TODAY si tu préfères le style WHOOP) |
| `ActivityTimeline.swift:182` | "Timeline" | "Activité" (ou garder Timeline, plus clair) |
| `ActivityTimeline.swift:238` | "Afficher plus/moins" | Déjà FR — OK |
| `SleepCoachModel.swift` | "RECOVERY" / "DAY STRAIN" (dans les Hero) | Garder EN en label uppercase (style WHOOP) OU traduire |

**Décision à prendre** : garde-t-on les labels uppercase EN (style WHOOP : "SLEEP", "RECOVERY", "STRAIN", "DAY STRAIN") ou on traduit tout ? Recommandation : garder les pill labels uppercase EN pour le style, traduire les phrases complètes.

## À re-vérifier (pas sûr que ce soit inutile)

| Élément | Vérification |
|---|---|
| `BraceletSyncStatusCard` (non branché) | Tu veux le garder pour le brancher sur Today (info sync visible) ou le supprimer ? |
| `LoopWidgetSnapshotStore` + `publishWidgetSnapshot()` | Toujours utile pour les widgets ? (Si oui, garder) |
| `DeviceSheetModifier` fallback iOS <26 | Tu cibles iOS 17+ — le fallback est utile, à garder |
| `ExpressMetricsCard` | Garder (état express légitime pendant recalcul) |
| `StressCard` sur Today + future StressDetailView | Si page détail dédiée, peut-être simplifier la card Today (non-expandable, just → navigate) |

## Bilan net

- **Suppressions** : 8 éléments (4 placeholders Settings + 1 row Resp + 1 URL + 1 hardcodé + 1 no-op button)
- **Déplacements** : 4 groupes (Device debug → Advanced, Settings strain/données/maintenance/backup → Profile, DateNavigator → shared)
- **Rationalisations** : 7 glass shells → 1, 2 Hero/Metrics/Insight → 1 generic, 2 backdrop → 1, 2 header → 1
- **Traductions** : ~15 chaînes EN → FR
