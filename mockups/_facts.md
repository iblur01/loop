# Faits pour le designer (extraction lecture seule)

Chemins relatifs à /Users/theo/dev/loop. Aucun fichier modifié hors de ce fichier.

## 1. Documents de design

- `DESIGN.md` (racine, 38 lignes) : principes (monochrome d'abord, une teinte accent par page = `.tint`, warning orange/rouge seulement si bas/critique, Liquid Glass natif `glassEffect` iOS 26+, pas de fallback). Anti-patterns : couleur partout, pills partout, cards répétitives, contrôles morts. Pas de tokens chiffrés.
- `docs/design/SPEC-DESIGN-LOOP.md` (431 lignes) : spec cible, statut "à valider".
  - Surfaces clair/sombre (§2.1) : bg.base F2F2F7 / 000000 ; surface.card FFFFFF / 1A1A1D ; surface.nested F2F2F6 / 2A2A2E ; surface.highlight E4E4EA / 3A3A3E ; text.primary 0B0B0C / FFFFFF ; text.secondary 5E5E66 / A6A6AD ; text.tertiary 8A8A90 / 7C7C83.
  - États (§2.2) : good 157A3F / 34D17A ; fair 8F6000 / FFC233 ; poor C92F2A / FF5A4F ; neutral 5E5E66 / A6A6AD.
  - Métriques (§2.3) : strain 0070B8 / 1FB6FF ; sleep 5A45D6 / 8E7CFF ; cardio C8155A / FF3D7F ; hrv 007D6E / 2FD9C5 ; stress 8A3CCF / C77DFF ; energy B4500A / FF8A3D ; steps 4A7A0E / A3E635 ; spo2 2F5FD0 / 7AA7FF ; temp 9E5200 / FFA347.
  - Rayons (§2.5) : card 26 ; nested 18 ; tile 22. Espacements : écran 16 (aujourd'hui 16 ou 20), padding carte 16, entre cartes 12 (grille) / 20 (sections). Cible tactile 44x44.
  - Typo (§3) : SF Pro, chiffres `.monospacedDigit()`, `.rounded` réservé aux héros ; hero 72 pt semibold ; titre de section `.title2` bold ; libellé `.subheadline` ; légende `.footnote` ; sur-titre `.caption` semibold capitales tracking 0,6.
- Tokens réellement implémentés (plus avancés que la spec) :
  - `Loop/Shared/DesignTokens/LoopColor.swift:39-67` (mêmes valeurs que la spec pour les surfaces/texte).
  - `Loop/Shared/DesignTokens/Metric.swift:13-16` (états) et `:45-52` (métriques) : valeurs identiques à la spec.
  - `Loop/Shared/DesignTokens/LoopType.swift:27-31` : rayons 26 / 18 / 22 ; `LoopCard` modifier `:54-70`.
  - Divergence : `Metric.strain` est 0070B8/1FB6FF, mais l'anneau Strain utilise la teinte HSB 0.55/1.0/0.95 (voir §4).

## 2. Profil

- `Loop/Features/Profile/ProfileView.swift` (133 lignes) : NavigationStack + ScrollView, VStack spacing 22, padding horizontal 20. Ordre des blocs :
  1. `ProfileHeader` (avatar initiales 92 pt en `glassEffect` circle, `.tint`; champ prénom 26 pt semibold; ligne device "WHOOP 4.0 · local" par défaut) :23-30
  2. Section "Profil" : `BodyProfileCard` :34-35
  3. Section "profile.strain.section" : `StrainDifficultyCard` :37-38, puis `healthProfileCard` (âge, FC max résolue, mention estimation, bouton "Gérer") :86-108
  4. Section "Données locales" : `ProfileDataGroup` (Dernier calcul) :41-42, `RecalcCard` :43, `ProfileNavRow` "Apple Santé" si `HealthKitImporter.isAvailable` :44-50
  5. Section "Plus" : `ProfileNavRow` Sauvegarde :53-57, Avancé :58-62
  6. Disclaimer caption secondary (non médical) :63-66
- Routes : `ProfileRoute` backup / health / advanced (:6-10) vers BackupView, HealthImportView, AdvancedView.
- `BodyProfileCard.swift` (115 lignes) : une seule surface `deviceSurface()`, séparateurs 1 pt `.primary` 6 %. Trois lignes :
  - Réveil cible (icône `alarm`, Stepper ±15 min, affichage H:mm) :24-48
  - Objectif de sommeil (icône `bed.double`, Slider 300–600 min pas 15, libellé "X h Y") :52-76
  - Unités (icône `ruler`, Picker segmenté metric/imperial) :80-95
  - Icônes en `.tint` (seul accent) ; valeurs en `.semibold`. Pas de champ taille/poids/âge ici.
- `ProfileHeader.swift` (63 lignes) : réutilisable tel quel (hero sans carte).
- `ProfileDataGroup.swift` (40 lignes) : une ligne "Dernier calcul" (date `.abbreviated/.shortened`, "—" si nil). Réutilisable.
- `ProfileNavRow.swift` (52 lignes) : ligne de navigation (icône `.tint` 26 pt, titre subheadline medium, sous-titre caption, chevron). Réutilisable pour toute porte de détail.
- Composants présents mais NON montés dans ProfileView : `MaxHeartRateCard.swift` (183 lignes ; seul usage = son `#Preview` :181). Il contient saisie FC max (bornes 120–230, :20), provenance Picker (manual / measured / ageEstimate), estimation par âge (10–100), Effacer. Donc la saisie FC max et l'âge manuel ne sont pas accessibles depuis la page Profil actuelle.
- Autres composants montés : `StrainDifficultyCard.swift` (73 l.) : slider inversé "Facile"/"Difficile", libellé via `strainDifficultyLabel`, note "relance un recalcul complet" (:54). `RecalcCard.swift` (86 l.) : bouton Recalculer, progression `completed/total`, Annuler.
- Champs corporels : `heightCm` (100–250) et `weightKg` (20–400) existent dans `UserPreferences` (:106-107, :121-135) et sont saisis seulement dans l'onboarding (`Loop/Features/Onboarding/OnboardingView.swift:289-290`). Aucun champ taille/poids dans le profil. `manualAge` (10–100) : saisie seulement dans MaxHeartRateCard (non monté) et onboarding.
- FC max auto : `UserMaxHeartRate.swift:40-45`, formule Tanaka 208 − 0,7 × âge, arrondi, borné 120–230. Âge effectif (`UserPreferences.swift:267-279`) : Apple Santé (date de naissance HealthKit) prioritaire, sinon `manualAge`. Ordre de résolution (`resolvedMaxHeartRate`, :254-263) : valeur saisie non-estimée > Tanaka > valeur saisie estimée > nil.
- Textes L10n : clés `Base` (lproj `en.lproj`, `fr.lproj/Base.strings`), ex. "Profil", "Réveil cible", "Objectif de sommeil", "Unités", "Dernier calcul", "Données locales", "Sauvegarde" / "Exporter ou restaurer", "Avancé" / "Maintenance · debug", "Apple Santé" / "Importer tes séances (lecture seule)". Pas de `LanguageManager` dans le code hors Device (aucune occurrence). Langue = système (Base.strings en/fr).

## 3. Sous-écrans

- `Loop/Features/Profile/Advanced/AdvancedView.swift` (titre "Avancé") : sections Maintenance (recalcul complet avec confirmation, "Tout effacer" destructif = purge des tables, irréversible sauf backup), Debug (copier logs BLE, simuler batterie critique / en charge, arrêter simulation Live Activity, mesure perf de recalcul ; bloc gardé par `#if DEBUG`, :87), Onboarding ("Refaire l'onboarding", destructif, réinitialise profil et préférences, pas strain ni backups).
- `Loop/Features/Profile/Backup/BackupView.swift` (titre "Sauvegarde") : sections Exporter (`.loopbackup` = whoop.sqlite + cache, export via document picker), Importer depuis une autre application (Noop :70 ; import Hevy CSV :165-168, `fileImporter` .commaSeparatedText :120), Restaurer (fichier `.loopbackup`, confirmation destructive, remplace toutes les données), Vérifier une sauvegarde. Chevauchement possible avec Avancé : "Tout effacer" et restauration.
- `Loop/Features/Profile/Health/HealthImportView.swift` (titre "Apple Santé") : connecter Apple Santé (lecture seule), état des permissions, dernière synchro, "Revoir les permissions", explication. Ne contient pas de réglage de profil.
- `Loop/Features/Profile/Backup/NoopImportView.swift` : sheet d'import Noop, appelé depuis BackupView:68.
- Doublons à éviter : pas de dossier `Réglages` ; le rôle "réglages" est porté par Profil. Les sections Profil et Avancé ne se recoupent pas, sauf le recalcul (ProfileView RecalcCard + Avancé "Recalcul complet").

## 4. Anneaux Sommeil / Récupération / Effort

- `Loop/Features/Today/Components/RingView.swift` : `RingView` reçoit `color: Color` ; track `.primary` 8 % (:73), zone cible `.primary` 20 % (:79), progression = `LinearGradient` color → color 76 % opacité, ombre color 25 % radius 8 (:95-106). `lineWidth` défaut 10 (:17). Aucune teinte codée en dur ici.
- `Loop/Features/Today/Home/TodayRingModel.swift` (couleurs réelles) :
  - Sommeil `sleepColor` = HSB(0.58, 0.55, 0.80) (:21) ; ≈ #5F9FCC (estimation).
  - Effort `strainColor` = HSB(0.55, 1.00, 0.95) (:22) ; ≈ #00A8F2 (estimation, cohérent avec le commentaire "#00AAF2").
  - En attente `pendingColor` = HSB(0.58, 0.10, 0.60) (:23).
  - Récupération `recoveryColor(score:)` (:25-29) : système `.green` si ≥ 67, `.yellow` si ≥ 34, sinon `.red`. Ce ne sont pas les tokens `state.*` (qui sont 157A3F / 8F6000 / C92F2A).
- Tokens correspondants : `Metric.sleep` 5A45D6/8E7CFF (`Metric.swift:46`) et `Metric.strain` 0070B8/1FB6FF (`:45`) ne sont PAS utilisés par les anneaux. Écart à signaler : anneau sommeil bleu-gris vs token violet ; anneau effort cyan vs token bleu plus sombre ; récupération en couleurs système vs `state.*`.
- `Loop/Features/Today/Home/TodayRing.swift` : anneau + valeur centrée + libellé (RingView :13-14). `TodayRingsHero.swift` (26 l.) : trois anneaux dans une surface `loopGlass(cornerRadius: 30)`, padding vertical 22 / horizontal 10 ; rayon 30 ne correspond pas à `radius.card` 26.

## 5. Préférences

`Loop/Core/Preferences/UserPreferences.swift` (341 lignes), UserDefaults, clés préfixées `userPreferences.` (:13-32) :

| Clé | Type | Défaut | Ligne |
|---|---|---|---|
| strainDifficulty | Double | 0.45 (borné 0.1–0.8) | :14, :218-220 |
| firstName | String | "" | :15, :77 |
| wakeHour / wakeMinute | Int | 7 / 0 | :16-17, :80-81 |
| sleepTargetMin | Double | 480 (300–600) | :18, :98-100 |
| onboardingComplete | Bool | false | :19 |
| unitSystem | enum metric/imperial | metric | :20, :144-158 |
| alarmEnabled | Bool | false | :21 |
| alarmHour / alarmMinute | Int | 7 / 0 | :22-23, :162-163 |
| alarmWeekdays | Set<Int> | vide (one-shot) | :24, :181 |
| alarmMode | AlarmMode off/regular/smart | regular | :25, :185 |
| alarmLeadMinutes | Int | 15 (5–30) | :26, :164-166 |
| userMaxHeartRate | JSON UserMaxHeartRate | nil (auto) | :27, :232 |
| manualAge | Int? | nil (10–100) | :28, :111 |
| heightCm | Double? | nil (100–250) | :29, :122 |
| weightKg | Double? | nil (20–400) | :30, :130 |
| preferredSports | Set<String> | vide | :31, :138 |

Pas de préférence de thème, de langue, de confidentialité, d'export CSV/JSON.

Vérifications par fonctionnalité :
- Notifications / alarmes : réglage réel. Alarme intelligente via le bracelet (`SmartAlarmController.swift` ; RUN_ALARM BLE, :80), calcul `AlarmScheduler.swift` ; modèle `AlarmMode.swift`. Pas de `UNUserNotification` dans le code. UI d'alarme : `Loop/Features/Today/Widgets/AlarmWidget.swift` (hors Profil). Pas de réglage d'alarme dans Profil. Réglages lisibles seulement via prefs (non exposés dans Profil).
- Unités métrique/impérial : réglage réel, `BodyProfileCard.swift:80-95`. Mais aucun affichage impérial vérifié ici (non audité hors Profil).
- Apparence (thème) : aucun réglage. Clair/sombre suit le système via `LoopColor.swift:15-19` (`userInterfaceStyle`). Pas de choix utilisateur.
- Langue (LanguageManager) : absent. Langue = système (`Loop/Resources/en.lproj`, `fr.lproj/Base.strings`). Pas de réglage.
- Confidentialité : pas de réglage. Seul texte : disclaimer `ProfileView.swift:63-66` et permissions HealthKit (`HealthImportView`).
- Export : réglage réel uniquement pour la sauvegarde `.loopbackup` (`BackupView.swift:29-60`, `Loop/Core/Backup/BackupDocumentPickers.swift`). Pas de CSV/JSON.
- Sauvegarde : réel, `BackupView.swift` (Exporter, Restaurer, Vérifier) ; import Hevy CSV et Noop.

## Fichiers vérifiés
DESIGN.md ; docs/design/SPEC-DESIGN-LOOP.md ; Loop/Features/Profile/{ProfileView, Components/*, Advanced/AdvancedView, Backup/BackupView, Health/HealthImportView, Backup/NoopImportView}.swift ; Loop/Features/Today/Components/RingView.swift ; Loop/Features/Today/Home/{TodayRingModel, TodayRing, TodayRingsHero}.swift ; Loop/Core/Preferences/{UserPreferences, UserMaxHeartRate, AlarmMode}.swift ; Loop/Shared/DesignTokens/{LoopColor, Metric, LoopType}.swift.
