# Composants — Profil et Réglages

Chemins relatifs à `/Users/theo/dev/loop`. Tokens : `Loop/Shared/DesignTokens/LoopColor.swift`, `LoopType.swift` (`LoopType`, `LoopMeasure`, `.loopCard`). Aucun `.font(.system(size:))` : rôles `LoopType` ou styles sémantiques uniquement.

## Profil (`mockups/profil.html`)

### Réutilisés

| Composant | Fichier | Usage dans la maquette |
|---|---|---|
| `ProfileView` | `Loop/Features/Profile/ProfileView.swift` | conteneur ; ordre recomposé, padding 16 (`LoopMeasure.screenGutter`) au lieu de 20, espacement 20 entre sections au lieu de 22 ; ajout de la route `.settings` à `ProfileRoute` |
| `ProfileHeader` | `Loop/Features/Profile/Components/ProfileHeader.swift` | avatar en verre + titre ; le titre devient « Ton profil » si `firstName` est vide, sous-titre sans marque |
| `ProfileNavRow` | `Loop/Features/Profile/Components/ProfileNavRow.swift` | lignes Apple Santé, Sauvegarde, Avancé, Réglages ; icône en `text.secondary` au lieu de `.tint`, hauteur fixe 56 |
| `ProfileDataGroup` | `Loop/Features/Profile/Components/ProfileDataGroup.swift` | réduit à une ligne de pied « Dernier calcul » (formatage de date conservé) |
| `.loopCard(.card)` | `Loop/Shared/DesignTokens/LoopType.swift:54-70` | carte corporelle et groupes de lignes (remplace `deviceSurface()`) |
| Logique FC max | `Loop/Core/Preferences/UserMaxHeartRate.swift:40-45`, `UserPreferences.swift:254-279` | valeur « Auto ≈ », âge effectif et sa source |
| `BodyProfileCard`, `StrainDifficultyCard` | `Loop/Features/Profile/Components/` | leurs contrôles (Stepper, Slider) passent derrière les lignes « Objectifs » (écran de détail ou sheet) ; la ligne Unités part dans Réglages |

### Nouveaux

| Composant | Rôle |
|---|---|
| `BodyMetricsCard` | carte corporelle : arc FC max + 3 colonnes âge / taille / poids avec source ; pied « Saisis à l'onboarding » |
| `MaxHeartRateArc` | arc 270° sur la plage 120–230 bpm, trait 10, teinte de l'anneau Effort, sans dégradé ni ombre (ne pas réutiliser `RingView`, qui applique un dégradé et une ombre, `RingView.swift:95-106`) |
| `BodyMetricColumn` | libellé `.footnote`, valeur `LoopType.tileValue` + unité `.subheadline`, source `.footnote` |
| `ProfileValueRow` | ligne 56 pt « icône, titre, valeur, chevron » pour Réveil cible, Objectif de sommeil, Difficulté d'effort |
| `BodyMeasuresEditor` | à créer : édition taille / poids / âge hors onboarding (peut reprendre `MaxHeartRateCard.swift`, aujourd'hui non monté) |

Retiré de la page : `RecalcCard` (le recalcul complet existe déjà dans `Loop/Features/Profile/Advanced/AdvancedView.swift`).

## Réglages (`mockups/reglages.html`)

### Réutilisés

| Composant | Fichier | Usage dans la maquette |
|---|---|---|
| `UserPreferences` | `Loop/Core/Preferences/UserPreferences.swift` | source des valeurs : alarme (:21-26), unités (:20) |
| `AlarmMode` | `Loop/Core/Preferences/AlarmMode.swift` | Picker du mode |
| Picker Unités | `Loop/Features/Profile/Components/BodyProfileCard.swift:80-95` | déplacé tel quel |
| `HealthImportView` | `Loop/Features/Profile/Health/HealthImportView.swift` | cible de « Autorisations Apple Santé » |
| `BackupView` (section Exporter) | `Loop/Features/Profile/Backup/BackupView.swift:29-60` | cible de « Exporter une sauvegarde » |
| `.loopCard(.card)` | `Loop/Shared/DesignTokens/LoopType.swift:54-70` | groupes, si `ScrollView` ; sinon `List(.insetGrouped)` natif |

### Nouveaux

| Composant | Rôle |
|---|---|
| `SettingsView` | page poussée depuis Profil, sections Réveil, Notifications, Affichage, Confidentialité, Export |
| `SettingsRow` | ligne 48 pt : tuile 28 pt rayon 8, titre `.body`, valeur `text.secondary`, chevron ou `Toggle` |
| `SettingsIconTile` | tuile colorée par catégorie (Sommeil, Effort, graphite), glyphe SF blanc taille unique |
| `AlarmSettingsSection` | édition des préférences d'alarme existantes ; `Toggle` teinté du vert Récupération, seul accent |
| `NotificationsSettings` | à créer (aucune notification locale dans le code) |
| `AppearancePicker` | à créer (système / clair / sombre, via `preferredColorScheme`) |
| `LanguageRow` | à créer (ouvre les réglages iOS de l'app) |
| `CSVExporter` | à créer |
