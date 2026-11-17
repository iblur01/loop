# 03 — Données disponibles mais non affichées

Données déjà calculées par `LocalMetricsEngine` et stockées dans `LoopCache` / `DailySnapshot`, mais **jamais rendues en UI**. Classées par facilité d'activation (de la plus triviale à la plus travaillée).

## Niveau 1 — Trivial (champ → label, ~1h par tuile)

| Donnée | Source | Page cible | Travail |
|---|---|---|---|
| `SleepSession.efficiency: Double?` | `LoopModels.swift:264` | Sleep detail (in-sleep grid) | Une tuile "Efficacité 92%" |
| `SleepSession.restingHr: Int?` | `LoopModels.swift:265` | Sleep detail (in-sleep grid) | Une tuile "FC repos 52 bpm" |
| `SleepSession.avgHrv: Double?` | `LoopModels.swift:266` | Sleep detail (in-sleep grid) | Une tuile "HRV 68 ms" |
| `DailySnapshot.sleepStart: Double?` | `LoopModels.swift:133` | Sleep detail plan + Timeline | Remplace le "07:00" hardcodé du plan |
| `DailySnapshot.sleepEnd: Double?` | `LoopModels.swift:134` | Sleep detail plan + Timeline | idem |
| `DailySnapshot.recoveryBand: String?` | `LoopModels.swift:142` | Recovery detail badge | Badge "Green"/"Yellow"/"Red" |
| `DailySnapshot.recoveryStatus: String` | `LoopModels.swift:141` | Recovery detail sous-headline | "high"/"medium"/"low" → "Haute"/"Moyenne"/"Basse" |
| `WorkoutSession.strain: Double?` | `LoopModels.swift:277` | Activity Timeline + Strain detail | Badge strain sur card workout |
| `WorkoutSession.caloriesKcal: Double?` | `LoopModels.swift:280` | Activity Timeline + Workout detail (P2) | Tuile calories |
| `WorkoutSession.durationS: Int?` | `LoopModels.swift:279` | Activity Timeline (déjà utilisé en fallback) | Prioriser sur `endTs - startTs` quand dispo |
| `ServerSummary.sampleCount` par stream | `LoopModels.swift:98` | Profile → Avancé | "X échantillons HR, Y RR…" pour debug |
| `LoopCache.computedRowCount` + `dayCounts` | `LoopModels.swift:15` | Profile → Avancé | État incrémentalité (déjà utilisé en interne, à exposer) |

## Niveau 2 — Moyen (chart à construire, ~1 jour)

| Donnée | Source | Page cible | Travail |
|---|---|---|---|
| `hrSamples[]` (cache) | `LoopModels.swift:326` | HeartRateDetailView (NEW) | Courbe HR 6h/24h/3j/7j avec AVG/MIN/MAX. Reprend `HeartRateDetailView` d'OpenWhoop (cf. 05). |
| Historique `cache.daily` 60j | `LoopModels.swift:5` | TrendsView (NEW P1) | 7/30/90d pour Recovery / HRV / RHR / Strain / Sleep. Reprend `TrendsView` + `TrendChartCard` d'OpenWhoop. |
| Historique `cache.sleepSessions` | `LoopModels.swift:6` | Sleep detail 7-nuit chart | Gantt 7 lignes (coucher/réveil). Reprend `SevenNightChart` d'OpenWhoop. |
| `StressSnapshot.timeline[]` | `LoopModels.swift:303` | StressDetailView (NEW) | Courbe 24h + breakdown. Reprend `StressV2TimelineChart` de Goose. |
| Sleep debt cumulé | calcul depuis `cache.daily` | Sleep detail + Today | `Σ(sleepTargetMin - totalSleepMin)` sur 7j glissants |
| Sleep needed ce soir | calcul depuis `cache.daily` | Sleep detail + Today | `sleepTargetMin + sleepDebt/4` (formule WHOOP-like) |
| HR zones 5 par jour | calcul depuis `hrSamples` + `restingHR` + `maxHR` | Strain detail + Workout detail | `HRR = (bpm - resting) / (max - resting)`, 5 zones, minutes. Reprend `HeartRateZonesSection` de Goose. |
| Day strain curve | calcul depuis `hrSamples` par heure | Strain detail | Strain cumulé heure par heure. Reprend `StrainV2DailyLoadCard` de Goose. |
| `adviceSignals[]` structurés | `DailySnapshot.adviceSignals` | Today CoachCard enrichi | Boucler sur les signals (type + message) au lieu du if/else dur. Déjà fait dans `SleepCoachModel.drivers`, généraliser. |
| `computeProgress.stage` | `repository.computeProgress` | Profile → Avancé | Liste détaillée des étapes (déjà textuel dans header, à exposer en debug) |

## Niveau 3 — Complexe (algo à porter, ~1 semaine)

| Donnée | Source externe | Page cible | Travail |
|---|---|---|---|
| **Respiratory rate** | openwhoop-gen4-debug `whoop_data.rs` (déjà dans le stream décodé) | Recovery detail + Health Monitor | Le raw `resp_rate` est dans les history packets V12/V24 — il faut l'extraire côté LoopStrapEngine et l'exposer dans `DailySnapshot.respRateBpm` |
| **SpO₂ %** | idem (Gen5 packet V18 ; Gen4 limite) | Recovery detail + Health Monitor | Idem — champ déjà décodé par le codec Rust, à porter dans le moteur Swift |
| **Skin temperature deviation** | idem (raw `skin_temp`) | Recovery detail + Health Monitor | Idem — `skin_temp` dans le packet, à convertir en delta vs baseline 30j |
| **Sleep stages précis (light/deep/REM)** | openwhoop-gen4-debug n'a PAS l'algo (sleep binaire seulement) ; WHOOP server a un classifieur | Sleep detail hypnogramme | **Déjà rendu en estimé** dans `SleepCoachModel.estimatedHypnogram` — pour avoir du réel, il faut porter un classifieur (le PPG-green 4-cat du notebook, ou un classifieur ML plus poussé) |
| **Recovery score weighted** | openwhoop-gen4-debug a juste RHR/HRV proxy ; Goose a `goose_recovery_v0` | Recovery detail | Le moteur Swift a déjà un recovery score (logistic sur z-score HRV) — pourrait être enrichi vers un weighted multi-factor (HRV + RHR + sleep + resp). Cf. `RecoveryCoachModel` qui le fait déjà en UI, à porter dans l'engine. |
| **Sleep consistency score** | openwhoop-gen4-debug `sleep_consistency.rs` | Sleep detail + Trends | Circular mean + CV de start/end/midpoint/duration sur 7j. ~80 lignes de math pure. |
| **Cardio Load (weekly)** | Goose `CardioLoadView` | Health Monitor (P1) | Algo complet dans Goose (`CardioLoadAlgorithmSummary`). |
| **Energy Bank** | Goose `EnergyBankView` | Today ou Health Monitor | Algo Goose. |
| **Calories (BMR + activity)** | OpenWhoop server `calories.py` | Strain detail + Profile | Calcul depuis profile (BMR Mifflin-St Jeor) + strain + activity. Reprend `calories.py`. |

## Synthèse — priorité d'activation

**Quick wins (1-2j, déjà en cache)** :
1. Sleep in-sleep grid (efficiency + restingHr + avgHrv depuis SleepSession)
2. Real bedtime/wake (sleepStart/sleepEnd) dans Sleep plan
3. Recovery band label + status text
4. Workout strain + calories dans Activity Timeline
5. `adviceSignals[]` dans CoachCard

**Moyen terme (1-2 semaines, charts à construire)** :
6. HeartRateDetailView (courbe HR)
7. TrendsView (7/30/90d)
8. Sleep 7-nuit chart
9. StressDetailView (24h + breakdown)
10. HR zones 5 (Strain detail + Workout detail)
11. Day strain curve
12. Sleep debt + sleep needed (Today)

**Backlog (algo à porter)** :
13. Respiratory rate, SpO₂, Skin Temp (déjà décodé côté codec, à exposer)
14. Sleep consistency score
15. Calories
16. Cardio Load
17. Energy Bank

## Liste complète des champs DailySnapshot non rendus

```swift
// Déjà rendus : date, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
// sleepScore, restingHR, avgHrv, recovery, strain, sleepTargetMin, targetStrain,
// targetStrainConfidence, recentOverload

// NON rendus :
sleepStart: Double?          // Unix seconds
sleepEnd: Double?            // Unix seconds
recoveryStatus: String       // "low" | "medium" | "high"
recoveryBand: String?        // "red" | "yellow" | "green"
adviceSignals: [AdviceSignal] // structured list — juste recentOverload est exploité
isExpress: Bool              // utilisé pour le toggle MetricsCard/Express, OK
```

## Liste complète des champs SleepSession non rendus

```swift
// Déjà rendus : startTs, endTs, stages (hypnogramme)
// NON rendus :
efficiency: Double?
restingHr: Int?
avgHrv: Double?
```

## Liste complète des champs WorkoutSession non rendus

```swift
// Déjà rendus : startTs, endTs, avgHr, peakHr, kind
// NON rendus :
strain: Double?
durationS: Int?        // utilisé en fallback seulement
caloriesKcal: Double?
```

## Liste complète des champs StressSnapshot à exploiter plus

```swift
// Déjà rendus : latest.score, summary.avgScore, summary.highMinutes, summary.activityMinutes, timeline (sparkline)
// Sous-exploités :
timeline[]              // 24h complète — pour courbe détaillée, pas juste sparkline
summary.maxScore        // non affiché
summary.avgNonActivityScore // non affiché
latest.hrBpm, latest.rmssdMs, latest.movementIntensity, latest.context // non affichés (debug?)
```
