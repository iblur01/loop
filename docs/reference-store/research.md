# Loop — Research : calibration par référence Apple Watch

> Rédigé le 2026-06-20. Phase Analyst (BMAD) du cycle HealthKit Reference Store.
> Explique le problème observé, la méthode de calibration par phase avec sa
> dimension temporelle, et les données HealthKit nécessaires à chaque phase.
> Pré-prod : ce doc nourrit le PRD, l'architecture et le roadmap.

---

## 1. Le problème observé

L'utilisateur porte une Apple Watch en parallèle du WHOOP 4.0. Les stats Loop
ne correspondent pas à ce que l'AW affiche, sur trois métriques :

### 1.1 Strain qui monte trop vite (journées à 1500 pas)

**Symptôme** : une journée sédentaire (1500 pas, pas de sport) produit un
strain Loop élevé, alors que l'AW affiche peu d'activité.

**Causes racines (preuves dans le code)** :

- `Strain.swift:77` — `minActivityPctHRR = 20%`. La gate d'activité est trop
  basse : pour RHR 55 / HRmax 187, 20% HRR = ~81 bpm. La marche légère et même
  la station debout dépassent ce seuil → comptées comme activité.
- `Strain.swift:54` — `strainDenominator = 5000.0` (constante `D` dans
  `strain = 21 × ln(TRIMP+1) / ln(D)`). Valeur **population** "tuned for
  WHOOP-like sensitivity", pas personnalisée. Avec un dénominateur trop petit,
  un TRIMP faible (journée sédentaire) suffit à pousser le strain vers le haut.
- `Strain.swift:82` — `defaultDifficulty = 0.6` compense en multipliant le
  TRIMP par 0.6, mais c'est un pansement global : il ne corrige ni la gate ni
  le dénominateur, et il écrase aussi les vraies séances.

**Conclusion** : le mécanisme TRIMP (HR-based, marche offline) est sain, mais
les **constantes de mapping** (gate d'activité + dénominateur log) sont des
valeurs population qui ne correspondent pas à la distribution de charge réelle
de l'utilisateur.

### 1.2 Recovery mal calibrée ("je suis épuisé mais vert")

**Symptôme** : des jours de fatigue accumulée affichent quand même une
recovery verte, parce que le score est calculé par rapport à... soi-même.

**Cause racine (preuves dans le code)** :

- `Recovery.swift:62-160` — le score est **purement auto-référentiel** :
  z-score vs ta propre EWMA roulante. Si tu es chroniquement épuisé pendant
  14 jours, ta baseline HRV baisse, ton RHR monte, et au 15e jour tu restes
  "à ta médiane (épuisée)" → z ≈ 0 → score ≈ 58% (vert/jaune).
- `Recovery.swift:173-174` — `logisticZ0 = 0.0` : le centre de la courbe est
  à z=0 = ta propre moyenne roulante. Aucun ancre absolu (norme âge/sexe).
- `Baselines.swift:326` — `minNightsTrust = 14` : avant 14 nuits, baseline
  "provisional" → cold-start bruité, faux scores pendant les 2 premières
  semaines.
- `Recovery.swift:166-169` — poids fixes : HRV 0.50, RHR 0.25, resp 0.10,
  sleep 0.15. Non calibrés sur l'utilisateur.

**Conclusion** : le principe auto-référentiel (détecter tes variations
journalières) est bon, mais il manque un **ancre absolu** pour éviter la
dérive systémique ("baseline qui suit ta fatigue").

### 1.3 Sleep "un poil" mal calculé

**Symptôme** : durées et bornes OK (parité Python validée, MAE 22 min), mais
la classification des stages (deep/REM/light) et la détection doze/sieste
restent imprécises.

**Cause racine (preuves dans DIAGNOSIS.md §8ter)** :

- La segmentation est réparée (MAE durée 256→22 min vs oracle Python).
- Reste : le **classifieur d'époques** (`SleepClassifier` / `SleepFeatures`)
  produit des écarts sur le doze (06-15 : +167 min) et la sieste (06-14 :
  +66 min).
- DIAGNOSIS.md §8ter l'explicite : "chantier futur à rendement décroissant"
  **parce qu'il manquait des labels** pour fitter le classifieur. Sans vérité
  terrain, on ne peut que tuner à la main.

**Conclusion** : il manque des **labels de sommeil** pour calibrer le
classifieur. L'Apple Watch fournit ces labels (estimate, pas PSG, mais un
second opinion structuré par époque).

---

## 2. Principe directeur : "drift toward reference, never snap"

On n'écrase **jamais** Loop par l'Apple Watch. On ajuste lentement les
paramètres via EWMA des résidus (Loop vs AW). L'AW est un **second estimate
personnel**, pas une vérité absolue (ses sleep stages sont elles-mêmes des
estimates accel+HR, pas PSG).

**Règles** :
- `whoop.sqlite` RAW reste l'unique source of truth WHOOP.
- Les données HealthKit vivent dans un store **séparé**, étiquetées
  "référence personnelle Apple Watch", jamais fusionnées avec le RAW WHOOP.
- Chaque métrique calibrée porte un `calibrationConfidence` (nuits comparées,
  variance du résidu, drift) → remplit l'exigence AGENTS.md "document
  confidence/uncertainty".
- 100% offline, HealthKit = lecture locale on-device, aucun runtime réseau.

---

## 3. Les 4 phases de calibration (avec dimension temporelle)

### Phase 0 — Diagnostic (non invasif)

> **Objectif** : rendre l'erreur visible et chiffrée avant de toucher quoi
> que ce soit. Savoir empiriquement si c'est le strain, la recovery ou le
> sleep qui dérive le plus.

**Méthode** :
- `HealthKitReferenceStore` read-only : pull des données AW, persistance dans
  une table `calibrationResidual(metric, day, loopValue, awValue, Δ)`.
- Pour chaque jour : calculer `Δ = loopValue − awValue` par métrique
  (strain, recovery, sleep duration, sleep stages %, HRV, RHR...).
- Agréger : MAE, biais moyen (`mean(Δ)`), écart-type, par métrique et par
  fenêtre glissante (7j, 30j).
- **Aucune formule n'est modifiée**. Loop tourne à l'identique. On observe
  juste l'écart.

**Dimension temporelle** :
- Accumuler **14-30 jours** de données parallèles avant de tirer des
  conclusions. En dessous de 14 jours, le bruit domine le signal.
- À 30 jours : on a une image stable du biais par métrique → décide quelle
  phase (1, 2, ou 3) attaquer en premier.

**Livrable** : un tableau de bord (vue Settings) qui montre, par métrique :
  - biais moyen (Loop a-t-il tendance à surestimer / sous-estimer ?)
  - MAE
  - tendance sur 30j (le biais s'améliore-t-il ou empire-t-il ?)

**Données HealthKit nécessaires (Phase 0)** :

| Type HealthKit | Identifiant | Usage Phase 0 |
|---|---|---|
| Heart rate (série) | `HKQuantityTypeIdentifier.heartRate` | Comparer HR moyen journalier |
| HRV (SDNN) | `HKQuantityTypeIdentifier.heartRateVariabilitySDNN` | Comparer HRV nightly (⚠️ SDNN ≠ RMSSD, voir §4) |
| Resting HR | `HKQuantityTypeIdentifier.restingHeartRate` | Comparer RHR |
| Walking HR avg | `HKQuantityTypeIdentifier.walkingHeartRateAverage` | Contexte activité |
| Steps | `HKQuantityTypeIdentifier.stepCount` | Valider niveau d'activité (1500 pas) |
| Active energy | `HKQuantityTypeIdentifier.activeEnergyBurned` | Comparer charge vs strain |
| Exercise time | `HKQuantityTypeIdentifier.appleExerciseTime` | Comparer charge vs strain |
| Distance walking/running | `HKQuantityTypeIdentifier.distanceWalkingRunning` | Contexte activité |
| Sleep analysis (stages) | `HKCategoryTypeIdentifier.sleepAnalysis` | Comparer durée + stages vs Loop |
| Sleep duration goal | `HKQuantityTypeIdentifier.sleepDay` | (optionnel) contexte |

**Sortie de Phase 0** : un rapport `calibration-diagnostic.md` qui classe les
métriques par biais décroissant et recommande l'ordre des phases 1-3.

---

### Phase 1 — Strain personnalisé

> **Objectif** : fit `strainDenominator` et `minActivityPctHRR` sur la
> distribution d'activité réelle de l'utilisateur.

**Méthode** :
- Récupérer 30-60 jours de `activeEnergyBurned` + `appleExerciseTime` + `steps`
  depuis l'AW.
- Calibrer `minActivityPctHRR` : choisir le seuil %HRR qui exclut les jours
  sédentaires (< 3000 pas, < 30 min exercise) du calcul de strain. Aujourd'hui
  20% → probablement 30-35% pour ne pas compter la marche légère.
- Calibrer `strainDenominator` : fitter `D` tel que `strain = 21 × ln(TRIMP+1)
  / ln(D)` mappe une journée intense de l'utilisateur (selon AW activeEnergy)
  vers ~strain 14-16, et une journée sédentaire vers ~2-4. Fit par
  régression sur la distribution TRIMP observée.
- Le mécanisme TRIMP (HR-based, offline) **ne change pas**. Seules les
  constantes de mapping deviennent personnelles.

**Dimension temporelle** :
- Besoin de **30-60 jours** de distribution pour capturer la variété
  (jours sédentaires + jours de sport). En dessous de 30 jours, le fit est
  instable (pas assez de jours intenses).
- Re-fit mensuel (EWMA) : la forme physique évolue, le dénominateur doit
  suivre lentement.

**Données HealthKit nécessaires (Phase 1)** : `activeEnergyBurned`,
`appleExerciseTime`, `stepCount`, `distanceWalkingRunning`, `heartRate`
(série, pour re-calculer TRIMP sur les fenêtres calibrées).

**Livrable** : `strainPersonalizedConfig(minActivityPctHRR, denominator,
confidence)` persisté dans `calibration.json`, avec `confidence` = nombre de
jours utilisés pour le fit.

---

### Phase 2 — Recovery ancrée

> **Objectif** : ajouter une couche *absolute anchor* blendée avec le
> z-score auto-référentiel. Corrige "je suis épuisé mais vert".

**Méthode** :
- Récupérer HRV (SDNN) + RHR de l'AW sur l'historique disponible.
- Convertir AW HRV SDNN → équivalent RMSSD (facteur ~1.2-1.4, à valider — voir
  §4). OU : traiter AW HRV en **relatif-only** (z-score vs norme AW, pas
  conversion absolue).
- Construire un z-score **absolu** : `z_abs = (ton HRV − norme âge/sexe) /
  σ_norme`. Source de la norme : population published (ou dérivée de
  l'historique AW lui-même si > 90 jours).
- Blend : `score = w_self · self_score + w_abs · absolute_score` où
  `w_abs: 0 → 0.3` selon le nombre de nuits comparées.
  - 0 nuits comparées → `w_abs = 0` (pure self-referential, comportement actuel)
  - 14 nuits → `w_abs = 0.1`
  - 60 nuits → `w_abs = 0.3` (ancre plafonnée à 30%, le self-referential
    reste dominant pour détecter tes variations journalières)
- L'ancre **ne remplace pas** le self-referential : elle empêche juste la
  baseline de dériver vers ta fatigue chronique.

**Dimension temporelle** :
- `w_abs` ramp **0 → 0.3 sur 60 nuits**. Avant 14 nuits : pas d'ancre (bruit).
  14-60 nuits : ramp linéaire. 60+ nuits : plafond 0.3.
- Re-calcul de la norme AW tous les 90 jours (EWMA lent).

**Données HealthKit nécessaires (Phase 2)** :
`heartRateVariabilitySDNN` (nightly), `restingHeartRate` (daily).

**Livrable** : `recoveryAnchoredConfig(w_abs, norme_hrv, norme_rhr,
nuits_comparées)` persisté dans `calibration.json`.

---

### Phase 3 — Classifieur sleep

> **Objectif** : utiliser les sleep stages AW comme labels pour fitter
> par utilisateur les seuils du `SleepClassifier`.

**Méthode** :
- Récupérer les `HKCategoryTypeIdentifier.sleepAnalysis` avec les valeurs
  `.deep`, `.rem`, `.core` (≈ light), `.awake`, `.inBed`.
- Aligner temporellement les époques Loop (30s) avec les segments AW.
- Pour chaque époque : `label = AW_stage`, `features = Loop features (HR,
  HRV, gravity, movement)`.
- Fitter les seuils du `SleepClassifier` (currently hand-tuned) par
  régression logistique / threshold optimization sur les résidus
  `Loop_stage − AW_stage` par époque.
- Le classifieur **garde sa structure** (mêmes features), seuls les seuils
  deviennent personnels.

**Dimension temporelle** :
- Besoin de **semaines de nuits** pour avoir assez d'époques labellisées par
  stage. Une nuit ≈ 7h × 120 époques/h = ~840 époques. 30 nuits ≈ 25 200
  époques, dont ~20% deep, ~25% REM, ~50% light, ~5% awake.
- Les stages rares (deep, awake) sont les moins fiables à fitter → besoin
  de plus de nuits (60+) pour stabiliser leurs seuils.
- C'est la phase la plus longue : **60-90 nuits** pour un fit stable.

**Données HealthKit nécessaires (Phase 3)** :
`HKCategoryTypeIdentifier.sleepAnalysis` (avec stages `.deep`, `.rem`,
`.core`, `.awake`, `.inBed`). iOS 17+ expose ces stages (sur Apple Watch
Series 9+ / Ultra+ avec watchOS 10+).

**Livrable** : `sleepClassifierThresholds(...)` persisté dans
`calibration.json`, avec `confidence` par stage (nombre d'époques
labellisées).

---

## 4. Caveats techniques

### 4.1 HRV : SDNN (AW) vs RMSSD (WHOOP)

- L'Apple Watch expose `heartRateVariabilitySDNN` = **SDNN** (écart-type de
  tous les intervalles RR, en ms).
- WHOOP / Loop utilise **RMSSD** (racine de la moyenne des carrés des
  différences successives, en ms).
- Ce ne sont **pas** la même métrique. SDNN ≈ 1.2-1.4 × RMSSD en moyenne,
  mais le ratio varie selon l'utilisateur et la fenêtre.
- **Décision pour Phase 2** : soit convertir (~×1.2-1.4, à valider), soit
  traiter AW HRV en **relatif-only** (z-score vs norme AW, sans conversion
  absolue). La seconde option est plus sûre (pas de facteur de conversion
  trompeur). L'Architect devra trancher.

### 4.2 Sleep stages AW = estimate, pas PSG

- Les sleep stages AW sont des estimates (accel + HR + température poignet),
  pas une polysomnographie. Agreement with PSG : ~70-80% pour light/deep,
  plus faible pour REM.
- C'est un **second opinion**, pas vérité. La méthode reste "réconcilier
  deux estimates", pas "fitter à la vérité". Documenter cette incertitude
  dans le `calibrationConfidence`.

### 4.3 Permissions HealthKit

- `NSHealthShareUsageDescription` dans Info.plist via `project.yml` (read).
- Aucun entitlement payant. HealthKit read = description string + types
  déclarés.
- L'utilisateur doit autoriser l'accès dans Settings > Health (premier run).
- HealthKit **read** n'exige pas l'app soit en avant-plan pour les queries
  historiques ; le background delivery est dispo mais optionnel.

### 4.4 Persistance & backup

- Les données HealthKit vivent dans un store **séparé** de `whoop.sqlite`
  (table dédiée OU fichier dédié — décision Architect).
- Doit être **incluable dans le `.loopbackup`** (BackupCoordinator) — le
  schéma doit le permettre, même si le wiring backup est hors-scope Phase 0.
- `calibration.json` (params fités en Phases 1-3) vit à côté de `cache.json`,
  inclus dans le backup.

### 4.5 Pas de runtime réseau

- HealthKit = lecture locale on-device. Aucune dépendance réseau.
- Respecte le cutover offline-first (DIAGNOSIS.md §2026-06-18).

---

## 5. Périmètre du cycle BMAD actuel

**Ce cycle (Phase 0 uniquement)** :
- Inventaire des types HealthKit (fait ci-dessus, §3 Phase 0).
- Permissions + déclaration dans `project.yml`.
- Store de persistance (HealthKitReferenceStore).
- Pull initial + incrémental (watermark).
- Table `calibrationResidual` + calcul des Δ par jour.
- Vue Settings minimale "Données Apple Watch" : statut d'accès + dernière
  sync + counts par type + tableau de bord des résidus (biais, MAE, 30j).
- Tests unitaires.

**Hors-scope (cycles suivants)** :
- Phase 1 (strain), Phase 2 (recovery), Phase 3 (sleep classifier) :
  calibration des formules. Ce cycle pose juste l'infra d'observation.
- UI de comparaison détaillée Loop vs AW (graphes, drill-down).
- Widget, notifications, export autre que backup.

---

## 6. Ordre d'attaque recommandé (après Phase 0)

1. **Phase 0** (ce cycle) → 14-30 jours d'observation → rapport diagnostic.
2. Selon le rapport, attaquer la métrique avec le plus gros biais en premier.
   Hypothèse actuelle (à valider par Phase 0) : **strain** (Phase 1) est le
   plus biaisé (constantes population), suivi de **recovery** (Phase 2,
   manque d'ancre), puis **sleep** (Phase 3, le plus long à calibrer).
3. Chaque phase est un cycle BMAD séparé, avec son propre research → PRD →
   architecture → stories → dev → QA.

---

## 7. Données HealthKit complètes à stocker (toutes phases)

Pour éviter de re-pull à chaque phase, on stocke dès Phase 0 tout ce qui
servira aux phases 1-3 :

| Type | Identifiant | Phase(s) | Fréquence | Unité |
|---|---|---|---|---|
| Heart rate | `heartRate` | 0,1,2 | ~1/min (AW) | count/min |
| HRV (SDNN) | `heartRateVariabilitySDNN` | 0,2 | nightly (AW) | ms |
| Resting HR | `restingHeartRate` | 0,2 | daily | count/min |
| Walking HR avg | `walkingHeartRateAverage` | 0 | daily | count/min |
| Steps | `stepCount` | 0,1 | hourly cumul | count |
| Active energy | `activeEnergyBurned` | 0,1 | hourly cumul | kcal |
| Exercise time | `appleExerciseTime` | 0,1 | hourly cumul | min |
| Walk/run distance | `distanceWalkingRunning` | 0,1 | hourly cumul | m |
| Sleep analysis | `sleepAnalysis` (category) | 0,3 | par segment | enum stage |
| Flights climbed | `flightsClimbed` | 0 | daily | count |
| Stand time | `appleStandTime` | 0 | daily | min |

**Décision Analyst** : on stocke tout ce qui est listé ci-dessus. Le coût
stockage est négligeable (utilisateur unique, ~1 an de données AW ≈ quelques
MB). Mieux vaut tout avoir pour les phases futures que re-pull.

---

## 8. Prochaines étapes (BMAD)

Ce research.md est le livrable de l'**Analyst**. Il nourrit :
- **PM** → `prd.md` (user stories, succès mesurable, out-of-scope).
- **Architect** → `architecture.md` (package SPM, schéma DB, permissions,
  watermarking, modèle d'erreur, wiring backup).
- **SM** → `stories.md` + `roadmap.md` (découpage en stories autonomes).
- **Dev / QA** → implémentation + validation de la Phase 0.
