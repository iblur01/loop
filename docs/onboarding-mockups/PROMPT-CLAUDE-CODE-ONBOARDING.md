# Prompt Claude Code — Implémentation SwiftUI de l'Onboarding Flowform (iOS 26+)

```text
Contexte : application iOS personnelle « Loop » (santé et sport, local-first, SwiftUI, iOS 26+).
Dépôt : /Users/theo/dev/loop.
Réponds en français.

ATTENTION GIT : des modifications non commitées préexistent dans l'arbre de travail. Ne fais AUCUN git checkout, git reset, git stash ni git clean. Ne touche qu'aux fichiers strictement nécessaires à l'onboarding et à ses tests.

================================================================================
1. LECTURE PRÉALABLE OBLIGATOIRE
================================================================================
Avant d'écrire la moindre ligne de code, lis intégralement :
1. Les spécifications et maquettes de l'onboarding (ta source de vérité UX/UI et textes) :
   - docs/onboarding-mockups/PLAN.md
   - docs/onboarding-mockups/screens-data.js (textes FR/EN exacts, états nominaux et d'erreur des 8 écrans)
   - docs/onboarding-mockups/styles.css
2. Le système de design et les tokens existants :
   - DESIGN.md
   - docs/design/SPEC-DESIGN-LOOP.md
   - Loop/Shared/DesignTokens/LoopColor.swift
   - Loop/Shared/DesignTokens/LoopType.swift
   - Loop/Shared/DesignTokens/Metric.swift
   - Loop/Shared/DesignTokens/WorkoutSport.swift
   - Loop/Shared/AppBackground.swift
3. Le code existant branché sur l'onboarding :
   - Loop/App/LoopApp.swift
   - Loop/Features/Onboarding/OnboardingView.swift
   - Loop/Core/Preferences/UserPreferences.swift
   - Loop/Core/Preferences/UserMaxHeartRate.swift
   - Loop/Core/Health/HealthKitImporter.swift
   - Loop/Core/Health/HealthSampleImporter.swift
   - Loop/Core/Device/DeviceConnectionViewModel.swift
   - Loop/Core/Sync/SyncCoordinator.swift
   - Loop/Core/Backup/BackupCoordinator.swift
   - Loop/Core/Backup/BackupDocumentPickers.swift
   - Loop/Features/Today/Widgets/TrainingAdviceWidget.swift
   - Loop/Resources/fr.lproj/Base.strings et Loop/Resources/en.lproj/Base.strings

================================================================================
2. OBJECTIF D'IMPLÉMENTATION
================================================================================
Remplacer l'ancien `OnboardingView.swift` par le nouveau parcours « Flowform » en 8 étapes défini dans `docs/onboarding-mockups/PLAN.md` et `screens-data.js`, en utilisant le vrai Liquid Glass natif iOS 26+ et les surfaces opaques `.loopCard()` de `LoopType.swift` :

Séquence des 8 étapes (`OnboardingStep: Int, CaseIterable`) :
- 01 `.welcome`    : Accueil (promesse en une phrase, carte d'aperçu illustratif du guidage matinal avec badge « Exemple illustratif », carte « 100 % sur cet iPhone · Sans compte », CTA primaire « Commencer » et CTA secondaire « Restaurer une sauvegarde » ouvrant le sélecteur `.loopbackup` via `BackupCoordinator`).
- 02 `.manifesto`  : Ce que Loop fait et ne fait pas (2 cartes opaques `.loopCard(.card)` : 3 engagements / 3 limites non négociables, CTA « Continuer »).
- 03 `.healthKit`  : Connexion Apple Santé en lecture seule (bouton unique « Connecter Apple Santé » qui appelle `HealthKitImporter.shared.requestAllAccess()` puis lance `sync(requestAccess: false)` et `HealthSampleImporter().importAll(requestAccess: false)` en tâche de fond ; CTA secondaire « Continuer sans Santé » ; gestion propre de `!HealthKitImporter.isAvailable` sur iPad et du comportement de confidentialité iOS sans faux message d'erreur rouge).
- 04 `.band`       : Bracelet compatible WHOOP 4.0 (facultatif, branché sur `DeviceConnectionViewModel` : indicateur LED bleue clignotante accessible + état détecté nom/modèle/batterie + états d'absence de capteur ou Bluetooth coupé ; CTA secondaire permanent « Continuer sans bracelet »).
- 05 `.profile`    : Profil minimal (Âge, Taille, Poids, FC maximale si connue dans une seule carte `.loopCard(.card)` avec séparateurs hairlines ; pré-remplissage depuis `prefs.healthAge` et le dernier poids Santé si disponibles avec mention « Lu depuis Apple Santé » ; validation de la FC max sur `120...230 bpm` via `UserMaxHeartRate` ; note explicite sur l'imprécision individuelle de la formule de Tanaka 208 − 0,7 × âge).
- 06 `.goals`      : Objectifs sportifs (grille multi-choix accessible basée sur `WorkoutSport.Kind` : `.run`, `.strength`, `.swim`, `.walk`, `.cycling`, `.hiit` ; note rassurante précisant que les 22 sports restent détectés et importés automatiquement).
- 07 `.sync`       : Première synchronisation (progression honnête séparée par source : état réel `HealthKitImporter` / `HealthSampleImporter`, état réel `SyncCoordinator` / `DeviceConnectionViewModel`, et `LoopDataRepository.computeProgress` ; CTA « Voir mon aperçu » ou « Continuer en arrière-plan » qui ne bloque jamais l'utilisateur ; état vide honnête si aucune source n'a été connectée).
- 08 `.ready`      : Écran final et accès au coach (aperçu réel du guidage quotidien *Ce que tu peux faire aujourd'hui* / *Ce qu'il vaut mieux éviter* avec `TrainingConfidenceRow` si l'historique Santé le permet, OU état honnête « Jour 1 · En calibration » sans aucun chiffre inventé si démarré à froid ; bascule optionnelle « Alerte matinale & batterie » déclenchant `UNUserNotificationCenter.current().requestAuthorization` ; CTA final « Ouvrir Loop » qui appelle `prefs.completeOnboarding()`).

================================================================================
3. RÈGLES D'ARCHITECTURE, DE DESIGN ET D'ACCESSIBILITÉ (NON NÉGOCIABLES)
================================================================================
1. **Verre pour ce qui flotte, opaque pour ce qui se lit (`SPEC-DESIGN-LOOP.md` §5)** :
   - Fond d'écran : `.appBackground()` (`LoopColor.bgBase`, `#F2F2F7` en clair / `#000000` en sombre).
   - Barre supérieure (bouton retour chevron, pilule de progression 8 segments, bouton « Passer ») et dock inférieur d'actions : **Liquid Glass natif iOS 26** (`GlassEffectContainer`, `.glassEffect(.regular, in: .capsule)`, `.buttonStyle(.glassProminent)`, `.buttonStyle(.glass)`).
   - Toutes les cartes de contenu, listes, formulaires et bannières : **100 % opaques** via `.loopCard(.card)` et `.loopCard(.nested)` (`LoopColor.surfaceCard` et `LoopColor.surfaceNested`).
   - **Interdiction absolue** de verre sur verre, de `.ultraThinMaterial`, `.thinMaterial`, `UIBlurEffect`, de dégradé de texte, de glow néon ou d'emoji en guise d'icône (utilise exclusivement SF Symbols).
2. **Typographie & Dynamic Type (`LoopType.swift`)** :
   - Zéro `.font(.system(size:))` en dur : tout passe par `LoopType` ou les styles sémantiques SwiftUI (`.title2.bold()`, `.headline`, `.subheadline`, `.footnote`, `.caption.weight(.semibold)`), chiffres en `.monospacedDigit()`.
   - Aux tailles d'accessibilité (`@Environment(\.dynamicTypeSize)` `.isAccessibilitySize`), la grille 2 colonnes des sports (étape 06) passe automatiquement sur 1 colonne et les lignes du profil (étape 05) s'empilent verticalement.
3. **Accessibilité (WCAG AA, VoiceOver, Reduce Motion, Reduce Transparency)** :
   - Textes secondaires en `LoopColor.textSecondary` (jamais `.tertiary` pour une information utile).
   - Aucun état ne repose sur la couleur seule : utilise toujours `HealthState.symbol` + mot explicite.
   - Respecte `@Environment(\.accessibilityReduceMotion)` : désactive la pulsation de la LED bleue et remplace la transition glissée asymétrique par `.opacity` si Reduce Motion est actif.
   - Cibles tactiles `>= 44 × 44 pt` (`LoopMeasure.minTarget`).
   - Déplace le focus `@AccessibilityFocusState` sur le titre de l'étape à chaque changement d'écran.
4. **Localisation FR / EN & Charte éditoriale** :
   - Tutoiement exclusif en français (`tu / ton / ta`), vocabulaire normé (*Bracelet* / *Appareil*).
   - Ajoute toutes les nouvelles clés dans `Loop/Resources/fr.lproj/Base.strings` ET `Loop/Resources/en.lproj/Base.strings` (en reprenant les libellés courts `< 26 caractères` validés dans `screens-data.js`).
5. **Découpage modulaire propre** :
   - Si tu crées de nouveaux fichiers sous `Loop/Features/Onboarding/` (ex. `OnboardingViewModel.swift` ou sous-vues), vérifie dans `project.yml` si `Loop` inclut récursivement le dossier `Loop` (auquel cas pas besoin de toucher `project.yml`, ou régénère proprement si nécessaire sans casser les autres fichiers).

================================================================================
4. ORCHESTRATION DES SOUS-AGENTS (WORKFLOW OBLIGATOIRE)
================================================================================
Utilise tes sous-agents (Task / Subagents) en suivant strictement ce découpage des rôles.
**Règle d'or : un agent ne relit et ne valide jamais lui-même ce qu'il a produit.**

- **Sous-agent 1 — Modèle de données, Préférences & Localisation (Sonnet)** :
  - Inspecte et met à jour `UserPreferences.swift` (ajout propre et rétrocompatible de `manualAge: Int?`, `heightCm: Double?`, `weightKg: Double?`, `preferredSports: Set<String>`, réinitialisés dans `resetOnboarding()`), ainsi que les clés FR/EN dans `Loop/Resources/fr.lproj/Base.strings` et `Loop/Resources/en.lproj/Base.strings`.
  - Vérifie l'intégration avec `LoopApp.swift` (passage de `repository` et `backup` à `OnboardingView` si nécessaire pour les étapes 01 et 07).

- **Sous-agent 2 — Implémentation UI SwiftUI & Liquid Glass iOS 26 (Opus ou Sonnet)** :
  - Implémente les 8 étapes dans `Loop/Features/Onboarding/` en respectant à la lettre `PLAN.md`, `screens-data.js` et `SPEC-DESIGN-LOOP.md` (chrome en Liquid Glass natif `GlassEffectContainer` / `.glassEffect`, cartes opaques `.loopCard()`, transitions fluides, gestion des états vides et d'erreur sur chaque étape).

- **Sous-agent 3 — Tests Unitaires XCTest (Sonnet)** :
  - Crée `LoopTests/OnboardingFlowTests.swift` pour tester :
    1. La progression à travers les 8 étapes (avancer, reculer, passer une étape facultative, auto-skip ou pré-remplissage si déjà configuré).
    2. La validation du profil minimal (bornes FC max `120...230`, âge `10...100`, fallback estimation automatique Tanaka, persistance dans `UserPreferences` et `resetOnboarding()`).
    3. La sélection/désélection des `preferredSports`.
    4. La transition post-restauration `.loopbackup` et l'appel final à `completeOnboarding()`.

- **Sous-agent 4 — Critique Indépendant Code, Design & Accessibilité (Opus — Agent distinct n'ayant écrit aucun code)** :
  - Audite tout le code écrit par les sous-agents 1, 2 et 3 contre `DESIGN.md`, `SPEC-DESIGN-LOOP.md` et `PLAN.md` :
    - `grep` : 0 `.font(.system(size:))` en dur, 0 `Material` / `UIBlurEffect`, 0 verre imbriqué dans une carte de lecture, 0 emoji, 0 vouvoiement en FR.
    - Vérifie la présence de `@AccessibilityFocusState`, `accessibilityReduceMotion`, `dynamicTypeSize.isAccessibilitySize`, et des traits VoiceOver.
    - Liste toute non-conformité pour correction immédiate avant la compilation finale.

================================================================================
5. VÉRIFICATION FINALE ET CRITÈRES D'ACCEPTATION
================================================================================
1. Compile l'application et lance les tests unitaires via `xcodebuild` (cible simulateur iOS) pour prouver qu'il n'y a aucune erreur de compilation ni de régression dans `LoopTests`.
2. Vérifie avec `git status` et `git diff` qu'aucune modification préexistante hors périmètre n'a été altérée ou perdue.
3. Dans ta restitution finale, indique :
   - Les fichiers créés ou modifiés ;
   - Le résultat du build et des tests `OnboardingFlowTests` ;
   - Les remarques soulevées par le Sous-agent 4 (critique indépendant) et comment elles ont été corrigées.
```
