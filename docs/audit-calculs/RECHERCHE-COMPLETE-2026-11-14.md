# Recherche complète — calcul Loop (sommeil, strain, récupération, workouts, pipeline)

Date : 14 novembre 2026
Statut : lecture seule. Aucun fichier du projet modifié, aucun commit.
Fichier séparé de `AUDIT.md` (autre session, même dossier) : ce document consolide la recherche menée ici, avec les données Apple Santé.

---

## 0. Résumé exécutif

Le calcul actuel de Loop ne donne pas des chiffres justes, pour trois raisons qui se cumulent :

1. **Le staging du sommeil est faux** : la segmentation en session est correcte, mais la classification en éveil / léger / profond / REM repose sur des seuils absolus, des entrées mortes (respiration, Cole-Kripke) et une échelle de mouvement cassée.
2. **Le strain mesure l'activité quotidienne, pas l'effort** : un seuil à 20 % de la FC de repos fait compter la marche comme de l'effort, et la FC max est estimée sans âge sur 3 jours.
3. **La détection des séances est trop large et ne lit pas Apple Santé** : la course de 10 km du 13/11 est bien enregistrée par le bracelet et par l'Apple Watch, mais le moteur la fond dans un bloc de 3 h, et l'import Santé n'est pas déclenché automatiquement.

Le pipeline (cache, jours, horloge) aggrave le tout : un refresh à 3 jours écrase le cache de 60 jours, les jours sont découpés en UTC, et les lectures sont tronquées silencieusement.

Le serveur externe **ne corrige aucun de ces points**. Le goulot est dans le signal et les algorithmes, pas dans la puissance de calcul. Recommandation : garder le calcul on-device, ajouter une couche IA d'explication optionnelle plus tard.

---

## 1. Périmètre et méthode

### 1.1 Projet audité
- Code : `/Users/theo/dev/loop` (app iOS Loop, client local-first d'un bracelet WHOOP 4.0, mono-utilisateur).
- Ne pas confondre avec `/Users/theo/dev/portfolio-dt` (site Next.js, hors sujet).
- Moteur : `Packages/LoopStrapEngine/Sources/LoopStrapEngine/` (Sleep, Daily, HRV, NumericKit, Units, Advice) et `Loop/Core/Engine/LocalMetricsEngine.swift` (~1 155 lignes).

### 1.2 Sources de données utilisées
| Source | Contenu | Usage |
|---|---|---|
| `Loop-2026-11-14-1301.loopbackup` | whoop.sqlite, cache.json, meta.json | Vérité terrain bracelet (sommeil, séances, daily) |
| `Loop-2026-11-14-1308.loopbackup` | idem + **Apple Santé** (`health_sample`, `external_workout`) | Référence externe pour sommeil, FC, course, pas |
| `Loop-2026-11-12-2327.loopbackup` | ajouté aux dossiers de travail | **Non analysé** à ce stade |
| `DIAGNOSIS.md`, `CLAUDE.md`, `AGENTS.md`, `loop-redesign/` | Documentation interne | Contexte et bugs connus |

### 1.3 Méthode
- **5 audits** en lecture seule, par domaine, avec des modèles différents selon la complexité (Fable pour le sommeil, Opus pour strain et workouts, Sonnet pour le pipeline et l'architecture). Chaque agent a reçu les chemins des backups comme vérité terrain.
- **Reproduction en Python** sur copies des bases (ouverture `mode=ro`) pour vérifier les chiffres avant de les affirmer.
- **Croisement bracelet / Apple Santé** sur les nuits et séances disponibles.

### 1.4 Limites
- Aucune polysomnographie : « faux » signifie *physiologiquement invraisemblable* ou *incohérent avec une autre source*, pas « vérité absolue ».
- Apple Santé n'est pas une référence parfaite (la Watch fait aussi du staging approximatif).
- Les numéros de ligne cités viennent des audits. Certains reposent sur `DIAGNOSIS.md` (daté du 17 juin) et n'ont pas tous été revérifiés dans le code actuel. **À reconfirmer avant toute correction.**
- Les tests Swift n'ont **pas** été exécutés.
- Une échantillon de 5 nuits est trop petit pour une métrique de concordance fiable (objectif du plan : 30 nuits).

---

## 2. Données de vérité : bracelet contre Apple Santé

### 2.1 Contenu des sauvegardes

**Backup 1308 (le plus complet)** :

| Table | Lignes |
|---|---|
| `health_sample` | 2 174 572 |
| `hrSample` (bracelet) | 209 711 |
| `rrInterval` | 145 533 |
| `gravitySample` | 202 406 |
| `respSample` | 202 406 |
| `skinTempSample` | 202 406 |
| `spo2Sample` | 202 406 |
| `external_workout` | 670 |
| `event` | 2 552 |
| `battery` | 810 |
| `rawBatch` | 3 044 |
| `adviceSignal` | 122 |
| `sleepSession` | **0** (la table existe mais reste vide) |
| `dailyMetric` | **0** |

Types Apple Santé présents : `activeEnergyBurned`, `heartRate`, `stepCount`, `basalEnergyBurned`, `distanceWalkingRunning`, `sleepAnalysis`, `appleExerciseTime`, `heartRateVariabilitySDNN`, `restingHeartRate`, `vo2Max`, `bodyMass`.

**Backup 1301** : `external_workout`, `health_sample` et `external_sync_anchor` **vides**. L'import Santé n'avait pas tourné à cette date.

Les dates Apple Santé sont en epoch Unix (pas en référence 2001), à convertir en UTC puis en Europe/Paris.

### 2.2 Séances (`external_workout`, extraits du 11 au 13/11)

| Date (Paris) | Sport | Début → fin | Durée | Distance | Énergie | Source |
|---|---|---|---|---|---|---|
| 11/11 | (Hevy, muscu) | 10h43 → 11h41 | 3 439 s | 0 m | 397 kcal | Hevy |
| 11/11 | (Strava) | 10h43 → 11h41 | 3 432 s | 0 m | 396 kcal | Strava |
| 12/11 | (Hevy) | 11h22 → 12h14 | 3 085 s | 0 m | 284 kcal | Hevy |
| 12/11 | (Strava) | 11h22 → 12h14 | 3 088 s | 0 m | 282 kcal | Strava |
| 13/11 | sport 37 (course) | 13h26 → 14h42 UTC | **4 555 s** | **10 027 m** | 777 kcal | Apple Watch |
| 13/11 | sport 52 | 14h42 → 15h28 UTC | 2 700 s | 2 896 m | 274 kcal | Strava |
| 13/11 | sport 52 | 14h42 → 15h28 UTC | 2 690 s | 2 896 m | 187 kcal | Apple Watch |

Note : le `sportType` est un code numérique HealthKit (37 = course à pied, 52 = marche, 50 = musculation/fitness, 63 = autre). Le mapping exact est à confirmer dans le code (`WorkoutSport.swift`).

**Conclusion sur la course de 10 km** : confirmée par l'Apple Watch (10,03 km, FC moyenne 164, max 176) et par Strava. Le bracelet l'a aussi captée dans la même fenêtre.

### 2.3 Course du 13/11 : FC

| Source | FC moyenne | FC max | Commentaire |
|---|---|---|---|
| Apple Watch (899 échantillons, 13h26-14h42 UTC) | **164** | **176** | Référence cohérente avec la course |
| Bracelet (cache, séance fusionnée) | ~146 | **182** | Pic de 182 en début de séance = probable artefact |

Le bracelet a bien enregistré une FC de 160-170 sur la fenêtre de course, mais le moteur l'a fusionnée avec l'échauffement et la récupération.

### 2.4 Pas et activité
- 11/11 : 3 947 pas
- 12/11 : 7 160 pas
- **13/11 : 40 578 pas** (journée de course + marche)
- 14/11 : 826 pas (matin uniquement au moment de l'export)

Le strain du 13/11 ne reflète pas ce volume. À intégrer au calcul de charge.

### 2.5 Nuits de sommeil : bracelet contre Apple Santé

**Nuit 13→14/11** (la nuit agitée) :

| Indicateur | Bracelet (cache) | Apple Watch | Écart |
|---|---|---|---|
| Début (Paris) | 01h04 | 00h58 | ~+6 min |
| Fin (Paris) | 10h02 | 09h29 | ~+33 min côté bracelet |
| Durée au lit | ~9 h 00 | ~8 h 31 | |
| Léger / core | **425,9 min** | **247 min** | +179 min côté bracelet |
| Profond | 38 min | 43 min | cohérent |
| REM | **18,5 min** | **118 min** | **×6 côté bracelet sous-estimé** |
| Éveil | ~56 min | **103 min** | **bracelet sous-compte de moitié** |
| Efficacité | 0,896 | à calculer sur le TIB | |
| Score sommeil | 54,4 / 100 | — | |
| Perturbations | 14 | — | |

**Autres nuits (Apple Watch, Paris)** :

| Nuit | Début → fin | Core | Profond | REM | Éveil |
|---|---|---|---|---|---|
| 10→11/11 | 01h21 → 08h25 | 234 | 38 | 54 | 98 |
| 11→12/11 | 01h10 → 09h57 | 219 | 46 | 96 | 166 |
| 12→13/11 (1re partie) | 01h30 → 05h50 | 138 | 79 | 16 | 26 |
| 12→13/11 (2e partie) | 23h31 → 05h24 | 201 | 79 | 48 | 25 |
| 13→14/11 | 00h58 → 09h29 | 247 | 43 | 118 | 103 |

Le bracelet, pour les nuits 11→12 et 12→13 (cache) : profond 5,5 et 12,5 min, REM 19,5 et 5,5 min, léger 268,5 et 123 min. Les valeurs de profond et de REM du bracelet sont systématiquement très basses par rapport à Apple.

**Interprétation** : l'Apple Watch n'est pas une vérité absolue, mais le bracelet range une nuit agitée dans le léger et sous-estime fortement le REM. Il est clairement en défaut sur le staging.

### 2.6 HRV et FC de repos (Apple Santé)
- La HRV SDNN d'Apple est très bruitée d'une mesure à l'autre (de 14 à 140 ms sur une même nuit). À ne pas utiliser seule comme référence.
- FC de repos Apple (valeur quotidienne à 23h) : 68 (11/11), 87 (12/11), 73 (13/11). Cette valeur est très variable selon l'heure de mesure.
- Le cache bracelet donne une FC de repos de nuit de 64 (nuit 11→12), 60 (12→13) et 67 (13→14). Les deux sources ne sont pas directement comparables sans aligner la fenêtre de mesure.

---

## 3. Sommeil (audit Fable, complet)

### 3.1 Verdict
La **segmentation en session est correcte** : la session de la nuit 13→14 est reproduite à la seconde près depuis le SQLite brut (00h04:25 → 09h02:46 UTC, soit 01h04 → 10h02 Paris). Ce qui est faux, c'est le **staging**.

### 3.2 Ce que contient la nuit 13→14 (brut, 1 Hz, sans trou)
- Deux levers nets, mesurés sur le bracelet :
  - 02h50:48 → 03h05:31 UTC (14,7 min), étiquetés éveil 9,5 min
  - 06h39:27 → 06h52:05 UTC (12,6 min), étiquetés éveil 11,5 min
- FC en dérive continue : 88 bpm la première heure, 76 bpm la dernière (corrélation r = −0,62), après une soirée à 100-115 bpm.
- `respSample.raw` ne prend que deux valeurs (2817 et 3073) : la variabilité respiratoire est **impossible à calculer** sur 0 des 1 077 époques.
- Indice de Cole-Kripke maximal : 0,07, pour un seuil de 1. **Zéro époque d'éveil** sur 1 077.
- 92 min d'époques avec mouvement (moveFrac ≥ 0,15), 56 min d'éveil au final.

### 3.3 Défauts classés

| # | Sévérité | Fichier:ligne (à revérifier) | Problème | Impact |
|---|---|---|---|---|
| S1 | **CRITIQUE** | `Sleep/SleepClassifier.swift:67-68, 293-294` | `hrLo`/`hrHi` sont des **percentiles absolus** de la nuit, sans retrait de tendance | 100 % des époques 00h04-02h04 sont « hrHigh » ; le REM n'est possible qu'en début de nuit ; le profond tombe à 05h31-07h32 |
| S2 | **CRITIQUE** | `Sleep/SleepFeatures.swift:147-187`, `LocalMetricsEngine.swift:360` | Le flux de respiration est un **mot d'état** (2 valeurs), pas une onde | La règle REM principale (`Classifier:327`) est morte ; `rrvRegular` toujours vrai (`:310`) ; REM uniquement via le fallback (`:331`) |
| S3 | **CRITIQUE** | `Sleep/EpochGrid.swift:17, 37, 151` | Les comptes sont une somme de deltas en g divisés par 100 (max 0,138) | Onset = 0 et final = n−1 (`SleepEngine:403`) ; bandes calculées éveil inclus (`Classifier:55`) ; forçage des bords (`SleepEngine:419`) sans effet. Les tests `SleepUnitTests` ne testent que des comptes synthétiques |
| S4 | MAJEUR | `Sleep/SleepClassifier.swift:317` | L'éveil exige **mouvement ET activation cardiaque** | 21,5 min de mouvement classées en sommeil |
| S5 | MAJEUR | `Sleep/SleepTypes.swift:38-43`, `SleepClassifier.swift:245` | Durées minimales asymétriques (REM/profond 5 min, éveil 2 min), absorption par le voisin le plus long | REM 36,5 → 18,5 min ; éveil 70,5 → 56 ; léger 392 → 426 |
| S6 | MAJEUR | `Sleep/InBedDetection.swift:446` (avec `:15`) | Un sous-span ≤ 60 min entre deux levers ≥ 15 min est jeté | Trou sans stade ou session tronquée (évité ici de 20 s) |
| S7 | MAJEUR | `Sleep/SleepEngine.swift:135, 222, 255` | Efficacité = TST/SPT après rognage ; latence toujours 0 ; `trimActiveEdges` retire 23h49 → 00h04 (immobile au lit) | 0,896 affiché, environ 0,87 sur l'enveloppe au lit (553 min) |
| S8 | MAJEUR | `Sleep/InBedDetection.swift:384-388` | Baseline = médiane FC de la fenêtre de 30 h (87, porte à 91,35) | Les bornes bougent à chaque recalcul de la journée en cours |
| S9 | MINEUR | `LocalMetricsEngine.swift:391, 1125` vs `SleepEngine.swift:598` | Jour en UTC d'un côté, `Europe/Paris` codé en dur de l'autre | Attribution incohérente |
| S10 | MINEUR | `SleepCoachModel.swift:140, 252-256` | « Latence » = délai jusqu'au premier profond ; hypnogramme inventé (240/85/95) affiché sans stades ; aucun indicateur de couverture | La nuit 12→13 a un trou de 250 min (22h26 → 02h37 UTC) : la session de 2 h 30 n'est pas un défaut d'algorithme |

### 3.4 Cause la plus probable
S1 + S2 combinés : sans respiration, REM et profond ne dépendent plus que du rang absolu de la FC, et la FC descend toute la nuit. S3 retire le seul garde-fou actigraphique ; S4 et S5 reversent le reste en léger.

### 3.5 Scripts de reproduction
- `/private/tmp/claude-501/-Users-theo--claude-spares-spare-kwvmGC/df367c3c-242a-4c42-b8b0-4523cf902520/scratchpad/rep.py`
- `/private/tmp/claude-501/-Users-theo--claude-spares-spare-kwvmGC/df367c3c-242a-4c42-b8b0-4523cf902520/scratchpad/night.py`

---

## 4. Strain et récupération (audit Opus, complet)

### 4.1 Verdict
Le strain mesure l'**activité quotidienne**, pas l'effort. Une journée sans sport donne 11,1 ; la course de 10 km seulement 13,9. Il n'y a presque pas d'écart.

### 4.2 Reproduction (copie de whoop.sqlite)
- FC max p99,5 = **169** (max observé 182) ; FC de repos = 60,3.
- Le 12/11 : 401 min en « Z1 » (20-60 % FCR), TRIMP 203, **strain 11,15** (cache : 11,14).
- Le 13/11 : 639 min en Z1 + 70 min en Z5, TRIMP 590, **strain 13,77** (cache : 13,9).
- Le 14/11 : TRIMP 116, **strain 9,79** (cache : 9,03).
- La course : FC 165-170 tenue environ 75 min (de 30 à 105 min).
- Les tables `health_sample` et `external_workout` étaient vides dans le backup 1301 : **la Watch n'a pas contribué** à ce calcul.

### 4.3 Défauts classés

| # | Sévérité | Fichier:ligne (à revérifier) | Problème | Impact |
|---|---|---|---|---|
| R1 | **CRITIQUE** | `Daily/Strain.swift:77`, `:73`, `:89`, `:249` | Seuil d'activité à 20 % de FCR ; `zoneIndex` renvoie 0 pour 20-60 % avec un poids de 0,5 | Marcher à 85 bpm compte ; la vie courante pèse 200 de TRIMP, soit ~11 de strain, et écrase la course |
| R2 | **CRITIQUE** | `LocalMetricsEngine.swift:489`, `:500`, `:755` | `estimateHRmax(..., age: nil)` sur un pool de 3 jours | FC max = 169 (la FC de la course elle-même) ; %FCR saturé à 100 % ; 70 min en zone 5 à tort ; valeur qui change à mesure que l'historique grandit |
| R3 | MAJEUR | `Strain.swift:54` + difficulté 0,45 | D = 5000 est **inatteignable** (il faudrait plus de 1 600 min en Z5) | Strain plafonné vers 15 ; plage utile observée de 9 à 14 |
| R4 | MAJEUR | `Strain.swift:313-326` | `karvZoneMinutes` met 20-60 % en Z1 | 639 « minutes de Z1 » affichées, faux |
| R5 | MAJEUR | `Baselines.swift:282` + `Recovery.swift:96`, `:103` | Dispersion déjà MAD × 1,4826 (σ), puis multipliée encore par 1,253 | σ gonflé de 25 % ; z-scores écrasés ; scores tirés vers 50 |
| R6 | MAJEUR | `SupplementalHeartRate.swift:21-46` | Le bracelet est **toujours prioritaire**, y compris en course | Le PPG du poignet décroche en course (cadence-lock) ; FC de la Watch ignorée là où elle est la plus fiable |
| R7 | MAJEUR | `LocalMetricsEngine.swift:759` | En express, FCR = p10 de la FC éveillée et FCmax = pool 14 jours ; en full, FCR de nuit et pool 60 jours | Strain express et strain full divergent |
| R8 | MAJEUR | `AdviceEngine.swift:217` + `LocalMetricsEngine.swift:592-594` | `strainBaseline` passée à nil si non « usable » ; confiance « low » ou « high », jamais « medium » ; « high » dès 4 jours | Cible de strain donnée avec une confiance surestimée |
| R9 | MINEUR | `Recovery.swift:185-188` | Doc : k = 1,6 et z0 = −0,2 ; code : 1,2 et 0 | Z = 0 donne 50 au lieu de 58 |
| R10 | MINEUR | `Daily.swift:200` | Une nuit de 141 min (13/11) compte comme nuit HRV valide | Baseline biaisée |
| R11 | MINEUR | `LoopModels.swift:223` | `recoveryStatus` contient la **confiance**, pas l'état de récupération | « low » se lit comme « fatigue » |

### 4.4 Cause la plus probable du strain faux
Le couple **seuil 20 % FCR / zone 0 à 0,5** (R1), associé à la compression logarithmique. Environ 400-640 min d'activité légère produisent un socle de strain de 10-11 ; la course de 10 km n'ajoute que ~2,7 points. R2 aggrave le tableau : la FC max de 169, tirée de la course faute d'âge et d'historique, gonfle la zone 5.

### 4.5 Fiabilité de la baseline (récupération)
- Le code exige **4 nuits HRV valides antérieures** pour passer en « provisional » (premier score, confiance moyenne), puis **14 nuits** pour « trusted ».
- Le 11/11 n'a pas de nuit. Au 14/11, il y a 3 nuits valides, dont une de 141 min.
- Premier score possible : **le 16/11** si chaque nuit est valide. Confiance haute : vers le **26/11** (15e jour).
- Recommandation de l'agent : une baseline HRV/FCR (ln RMSSD sur 7 jours glissants) est exploitable vers **7 nuits** et fiable vers **14 nuits**. Le seuil de 4 nuits est optimiste, surtout avec une MAD sur 4 points.
- « low » affiché aujourd'hui = **absence de baseline**, pas une fatigue mesurée.

---

## 5. Workouts et réconciliation (audit Opus, complet)

### 5.1 Verdict
Deux causes se cumulent pour la course de 10 km :
1. **La Watch n'a jamais été importée** : l'import HealthKit n'a pas tourné (tables vides dans les deux backups).
2. **La détection bracelet est inadaptée** : un seuil absolu et un gap trop large fusionnent la course avec l'échauffement et la récupération.

### 5.2 Reproduction
L'agent a rejoué l'algorithme de détection en Python : il reproduit **exactement** les 12 sessions du cache. Le diagnostic est donc fiable.

### 5.3 Séances détectées par le bracelet (cache)
Les 12 entrées sont toutes `kind = "detected_cardio"`, sans sport ni distance. Plusieurs durées sont invraisemblables : 11 145 s (3 h 06, pic 182, début 13/11 à 14h54 Paris), 10 543 s (21h03-23h59, soirée sans sport), 5 716 s (17h13).

### 5.4 Défauts classés

| # | Sévérité | Fichier:ligne (à revérifier) | Problème | Impact |
|---|---|---|---|---|
| W1 | **CRITIQUE** | `LocalMetricsEngine.swift:932` | Seuil = `max(p10 + 35, 110)`. Ici p10 = 66, donc **110 bpm**. Ta FC de jour est à 95-115 | La queue de récupération (15h-15h40, ~113) prolonge la course ; soirée sans sport = séance de 10 543 s ; idem 5 716 s |
| W2 | **CRITIQUE** | `LocalMetricsEngine.swift:940` | `maxGap` de 12 min (prévu pour la musculation) appliqué à tout | Un échantillon ≥ 110 toutes les 12 min suffit à prolonger la séance ; fusions de plusieurs heures |
| W3 | **CRITIQUE** | `LocalMetricsEngine.swift:966`, `:399` | `kind` toujours `"detected_cardio"` ; `strain` nil ; aucune séance `external_workout` rattachée | `WorkoutSport.swift:17` tombe sur `default` ; `TimelineBuilder.swift:39` affiche « Detected Cardio » ; sport et distance de la Watch jamais propagés |
| W4 | MAJEUR | `HealthKitImporter.swift:89` | Import lancé seulement par `HealthImportView.swift:26/83` ou la tâche manuelle `HealthBackgroundSync.swift:165` | Aucune sync au lancement, aucun observer ; base vide sans action manuelle |
| W5 | MAJEUR | `HealthReconciliation.swift:282-317` | Regroupement transitif, critère de 50 % de la plus courte | Un bloc bracelet de 3 h absorbe plusieurs séances Watch distinctes (course puis marche de retour) ; séances perdues |
| W6 | MAJEUR | `HealthReconciliation.swift:34` | `classify` cherche « watch » dans le **nom** de la source | Une course Strava ou Nike Run Club devient `.healthKit` ; les bornes du bloc de 3 h sont gardées |
| W7 | MINEUR | `ExternalWorkoutStore.swift:58`, `HealthDayReport.swift:145` | Filtre par jour de début en UTC ; la détection coupe à minuit UTC | Séance à cheval sur minuit coupée en deux côté bracelet |
| W8 | MINEUR | `LoopModels.swift:293` | Une rejection masque toute séance future couverte à ≥ 50 % | Un faux bloc rejeté peut faire disparaître une vraie séance plus tard dans le même créneau |
| W9 | MINEUR | `LoopTests` | Aucun test de `detectWorkoutSessions` ; aucun test de bout en bout Watch → timeline | Régressions non détectées |

### 5.5 Correction attendue sur la journée du 13/11
Une séance d'environ **4 600 à 5 000 s**, avec sport « running », distance ~10 km, bornes 13h26 → 14h42 UTC.

---

## 6. Pipeline de données (audit Sonnet, complet)

### 6.1 Verdict
Le **brut est sain** : clé naturelle idempotente, transaction décodé + brut + curseur, ack après commit. Les dérivés faux viennent surtout de la **couche cache et incrémental** et de la **définition du jour**.

### 6.2 Défauts classés

| # | Sévérité | Fichier:ligne (à revérifier) | Problème | Impact |
|---|---|---|---|---|
| P1 | **CRITIQUE** | `LoopDataRepository.swift:120`, `:270-278` + `LocalMetricsEngine.swift:272-285`, `:511-513` | `requestBackgroundRefresh` appelle `refresh(days: 3)` ; `computeCore` ne renvoie que 3 jours et écrase `daily`, `sleepSessions`, `stress`, `dayCounts` | Cache amputé à 3 jours ; récupération et baselines froides sur ces 3 jours ; récupération perdue jusqu'au prochain recalcul complet au foreground |
| P2 | **CRITIQUE** | `LocalMetricsEngine.swift:237-246` | Le gel ne teste que le **premier** jour modifié (`earliest`) | Tous les jours modifiés entre `earliest` et J-2 sont sautés ; `currentDayCounts` persisté (`:700`), donc le jour n'est plus jamais recalculé ; sommeil et strain figés avec données incomplètes |
| P3 | MAJEUR | `LocalMetricsEngine.swift:168-180`, `:858-870` ; `LoopDataRepository.swift:167-172` | `dayBounds`, rattachement d'une nuit (date UTC de fin), « aujourd'hui » en UTC | Strain entre 00h et 02h compte pour la veille ; le jour courant bascule à 02h ; fenêtre de sommeil décalée de 1-2 h |
| P4 | MAJEUR | `LocalMetricsEngine.swift:343-356` (100 000 en express `:728-742`) | `ORDER BY ts ASC LIMIT 250 000` sans erreur si atteint | Fin de fenêtre tronquée silencieusement : réveils coupés, sessions raccourcies, strain du soir manquant |
| P5 | MAJEUR | `BLEBondingHandshake.swift:80` ; `BLEConnectionManager.swift:647-661`, `:996-1003` | `SET_CLOCK` envoyé à chaque connexion ; `ClockPolicy` (conditionnel) n'est appelé qu'après un `GET_CLOCK` qui n'arrive jamais ; le fallback pose une référence identité (device = wall, +10 s) ; `clockRef` jamais remis à nil entre connexions | La dérive du RTC avant `SET_CLOCK` décale tout l'historique ; les type-40 live sont décalés |
| P6 | MAJEUR | `StreamStore.swift:62-81` (ON CONFLICT DO NOTHING) | Un live décalé de ±1 s et un historique donnent des clés différentes : HR et RR **dupliqués** ; clé RR `(ts, rrMs)` supprime deux battements identiques dans la même seconde ; events de même `(ts, kind)` perdent leur payload | HRV et détection d'immobilité faussées |
| P7 | MAJEUR | `LocalMetricsEngine.swift:372-373`, `:744` | Sommeil sur le proxy gravity (delta) ; stress, strain et express sur |g| (aveugle à l'orientation, DIAGNOSIS §8ter) | Mouvement sous-estimé ; stress et workouts incohérents avec le sommeil |
| P8 | MAJEUR | `LoopDataRepository.swift:152-164` ; fire-and-forget `:80`, `:95`, `:107` | Un full peut sauvegarder le cache pendant qu'un express calcule ; l'express écrase ensuite avec un état ancien (lost update) ; `Task { try? await store.saveCache }` peut se réordonner | Données du cache perdues ou écrasées par une version plus ancienne |
| P9 | MINEUR | `Backfiller.swift:144-147` | Sur `.complete`, les frames depuis le dernier END sont jetées sans commit | À vérifier : re-servies seulement si le trim n'a pas avancé |
| P10 | MINEUR | `Backfiller.swift:261-268` | `startTs/endTs` du `RawBatchMeta` valent `ref.wall` (faux) ; fallback `ClockRef(now, now)` (`:199`) | Horodatages du brut faux si fallback utilisé pour des frames non type-47 |
| P11 | MINEUR | `LoopDataRepository.swift:231` | Fingerprint global n'inclut pas les échantillons Santé | Un import Santé ne déclenche pas de refresh sans `force` |
| P12 | MINEUR | `Reads.swift:173`, `LocalDeviceID.swift:30` | `purgeOrphans` supprime tout autre deviceId ; restauration sous un autre id invisible sans `reassign` | Risque de perte d'historique après `LocalDeviceID.set` |
| P13 | MINEUR | `BLEConnectionManager.swift:598-602` | Le Collector garde une référence forte au store ; fermeture de la DB avant restauration non garantie | Restauration instable |
| P14 | MINEUR | `RawOutbox.swift:257` | Le raw live jamais « synced » n'est jamais purgé (serveur supprimé) | Croissance de la base sans limite |

### 6.3 Top 5 avant toute refonte de formule
1. Ne jamais écraser le cache de 60 jours avec un refresh de 3 jours (merge par date).
2. Rendre le gel sûr : ne figer que les jours réellement stables, et ne persister `dayCounts` que pour les jours recalculés.
3. Calendrier local explicite (Europe/Paris, stocké avec le snapshot) pour jours, nuits et express.
4. Détecter la troncature `LIMIT` et échouer proprement au lieu de renvoyer un résultat partiel.
5. Fiabiliser l'horloge (reset de `clockRef`, dérive mesurée, plus de `SET_CLOCK` aveugle) et dédupliquer live et historique, avec le même proxy partout.

---

## 7. Architecture : serveur externe ou on-device ? (audit Sonnet, complet)

### 7.1 Verdict
**Ne pas déporter le calcul.** Ajouter une couche IA optionnelle autour d'un moteur local.

### 7.2 Raisons
- Le goulot est le **signal et les algorithmes**, pas la puissance de calcul. Un serveur ne rend pas le sommeil plus juste.
- Le serveur Python a été **supprimé le 18/06/2026** (cutover offline-first, voir `DIAGNOSIS.md`). Le recréer annulerait ce choix.
- CLAUDE.md pose déjà le serveur comme chemin **optionnel**, jamais une dépendance.
- Une IA qui produit des scores (Recovery, Strain, Sleep) serait **non reproductible et non validée**.
- Contrainte « No ground truth » de CLAUDE.md : sans vérité terrain, on ne peut pas se dire « proche de WHOOP ». Apple Santé (cf. section 2) offre une première référence.

### 7.3 Répartition on-device / serveur

| Élément | Lieu | Raison |
|---|---|---|
| Segmentation et staging du sommeil, HRV, RHR, respiration, Recovery, Strain, Stress, calories | **On-device** | Déterministe, hors-ligne, testable |
| Baselines 30 j | On-device | Personnelles, peu coûteuses |
| Fusion HealthKit, alarme intelligente | On-device | Latences et permissions |
| Coach en langage naturel, explication d'un score, rapports hebdo/mensuels | Serveur possible, **opt-in** | LLM ; entrée = résumé agrégé, pas la FC brute |
| Suggestion de correction de segments | Serveur possible, **jamais appliquée automatiquement** | Validation utilisateur |
| Entraînement offline d'un classifieur de stades | Serveur possible (hors LLM) | Le modèle exporté (Core ML ou arbre) tourne ensuite en local |

### 7.4 Risques
- **Données de santé** : HR, HRV, sommeil et température sont sensibles (RGPD art. 9). Envoi serveur = consentement explicite, chiffrement, minimisation, droit à l'effacement.
- **Réseau** : `TodayView` ne lit que le cache disque ; garder cette propriété.
- **Coût** : calcul serveur et LLM facturés (à l'appel ou au token). Cache par jour, appels à la demande, plafond.
- **Sync** : retomber sur les deux stores dérivés concurrents (P5 de `DIAGNOSIS.md`) et des conflits de version d'algo.
- **Local-first** : figer les scores en local avec un `algoVersion`.
- **Dépendance fournisseur** : isoler le LLM derrière un protocole.

### 7.5 IA : valeur et danger

**Valeur réelle** :
1. Explications en langage naturel des drivers déjà calculés (`adviceSignals`, aujourd'hui « jamais rendu »).
2. Détection d'anomalies : FC de repos en hausse, HRV en baisse, signes de maladie.
3. Suggestion de correction de segments (fusion ou découpe) avec confiance, validée par l'utilisateur.
4. Coaching en remplacement de la `CoachCard` statique.

**Danger** :
1. Scores Recovery, Strain, Sleep produits par un LLM : non reproductibles, non validables.
2. Conseils médicaux (arythmie, apnée) à partir de SpO2 non calibrée.
3. Hallucination de chiffres : l'IA ne doit citer que les champs fournis (test automatique).
4. Correction automatique qui masque les bugs du moteur.

**Pattern recommandé** : moteur déterministe local qui émet scores, confiance et `adviceSignals` ; une couche IA lit ce JSON agrégé, explique et propose des corrections marginales, bornées, réversibles, toujours validées. L'IA peut aussi tourner on-device (Foundation Models d'Apple) sans envoi réseau.

### 7.6 Modèles (si l'IA est retenue)
Modèles à utiliser (IDs confirmés dans les instructions du projet) : `claude-opus-5-5` pour le raisonnement, `claude-haiku-5-5` pour le volume. Sans données brutes identifiantes.

---

## 8. Plan d'action en 4 phases

### Phase 1 — Fiabiliser et mesurer (local)
Actions :
- Corriger P1 (refresh à 3 jours), P2 (gel), P4 (troncature) et P3 (calendrier local).
- Corriger la race deviceId (déjà corrigée au bootstrap selon l'audit pipeline ; à confirmer).
- Constituer une **vérité terrain** : Apple Santé est la première référence disponible. Étendre l'historique et étiqueter à la main quelques nuits de contrôle.

Critères de sortie :
- 0 session de sommeil > 14 h sur 60 jours.
- Recalcul 60 jours < 60 s.
- Erreur de début/fin de sommeil < 15 min sur ≥ 90 % des 30 nuits de référence.

### Phase 2 — Calibrer le moteur
Actions :
- Corriger S1 (tendance FC), S2 (flux resp), S3 (échelle de mouvement), S4 et S5 (éveil et durées minimales).
- Corriger R1 (seuil de strain à 50 % FCR), R2 (âge dans la FC max), R3 (échelle D), R5 (double facteur de dispersion).
- Corriger W1 et W2 (seuil et gap de détection des séances).
- Fitter ou masquer la SpO2 et la respiration (« non calibré » affiché).

Critères de sortie :
- Durée totale de sommeil à ±20 min sur 80 % des nuits.
- Concordance des stades (Cohen κ) ≥ 0,5 sur les 30 nuits.
- RHR et HRV à ±5 % de la référence.
- Tout score non calibré affiché « non calibré ».
- Test de non-régression : la nuit 13→14 et la course du 13/11 comme fixtures.

### Phase 3 — Intégration Santé et réconciliation
Actions :
- W3 et W4 : fusionner les séances Apple Santé dans le moteur (sport, bornes, distance viennent de la Watch) ; import automatique au lancement et en arrière-plan (`HKObserverQuery`).
- W5 et W6 : réconciliation sans transitivité, classement par `sourceRevision` et non par nom.
- R6 : pendant une séance Watch, préférer la FC de la Watch.
- P7 : proxy gravity partout.

Critères de sortie :
- La course du 13/11 est une séance « running » de ~4 600 à 5 000 s, 10 km, bornes 13h26-14h42 UTC.
- Aucune séance Watch perdue sur 30 jours.

### Phase 4 — IA d'explication, puis serveur optionnel
Actions :
- Brancher `adviceSignals` à un texte (Foundation Models ou gabarits).
- Anomalies à seuils simples.
- Serveur uniquement pour le coach en langage naturel : résumés agrégés, pas de FC brute, clé jamais embarquée, plafond de coût, suppression à la demande.

Critères de sortie :
- 100 % des chiffres cités présents dans le JSON d'entrée (test automatique).
- App complète en mode avion, 0 appel réseau pour le calcul.
- Coût < 1 €/mois.
- ≥ 70 % de corrections de segments proposées jugées correctes sur les nuits de référence.
- 0 score modifié par l'IA.

---

## 9. Points de vigilance

- **Baseline** : les scores de récupération ne sont pas exploitables avant ~7 nuits valides, et fiables vers 14 nuits. Le « low » actuel n'est pas de la fatigue.
- **Fuseau horaire** : tout le moteur doit travailler en Europe/Paris explicite ; le bracelet travaille en UTC.
- **Horloge du bracelet** : dérive jamais corrigée pour l'historique (P5).
- **Pas de tests de concordance** : les tests existants sont des parity tests Swift/Python ou des invariants triviaux. Les tests de parité baseline, récupération et strain ont un corps vide (`DailyParityTests.swift:18`, `:90`, `:100`). À corriger avant toute refonte.
- **Données manquantes** : une absence de donnée est souvent traitée comme du sommeil ou comme du repos. Il faut distinguer « non mesuré » de « zéro ».

---

## 10. Questions ouvertes
1. Ordre des correctifs : sommeil et strain d'abord, ou workouts et import d'abord ? (question en attente)
2. Étendre l'export Apple Santé à 30 nuits ou plus : possible pour l'étiquetage de référence ?
3. Analyser le backup `Loop-2026-11-12-2327` (non fait) pour élargir la vérité terrain.
4. Confirmer les numéros de ligne cités dans le code actuel (certains viennent de `DIAGNOSIS.md`).
5. Mapping exact des codes `sportType` HealthKit (37, 50, 52, 63…) dans `WorkoutSport.swift`.

---

## 11. Annexe : commandes utiles (lecture seule)

Ouvrir une base sans la modifier :
```bash
python3 -I -c "import sqlite3; con=sqlite3.connect('file:/Users/theo/Downloads/Loop-2026-11-14-1308.loopbackup/whoop.sqlite?mode=ro', uri=True); print(con.execute('select count(*) from health_sample').fetchone())"
```

Lire les séances Apple Santé :
```bash
python3 -I -c "import sqlite3; con=sqlite3.connect('file:/Users/theo/Downloads/Loop-2026-11-14-1308.loopbackup/whoop.sqlite?mode=ro', uri=True); [print(r) for r in con.execute('select sportType,startDate,endDate,durationSec,distanceM,sourceName from external_workout order by startDate desc limit 10')]"
```

Lire les stades de sommeil Apple (valeurs : 0 inBed, 2 awake, 3 core, 4 deep, 5 REM) :
```bash
python3 -I -c "import sqlite3; con=sqlite3.connect('file:/Users/theo/Downloads/Loop-2026-11-14-1308.loopbackup/whoop.sqlite?mode=ro', uri=True); [print(r) for r in con.execute('select value,startDate,endDate from health_sample where type=\"sleepAnalysis\" order by startDate desc limit 20')]"
```

Les dates `startDate` de `health_sample` et `external_workout` sont des timestamps Unix (UTC).
