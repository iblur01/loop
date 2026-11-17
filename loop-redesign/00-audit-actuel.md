# 00 — Audit de l'app Loop actuelle

> Référentiel : `loop/Loop/Features/**` au 2026-06-19. Source unique : `LoopDataRepository.cache` (LoopCache) + `DeviceConnectionViewModel.state`. Architecture offline-first (plus de serveur VPS, backup `.loopbackup`).

## Arborescence actuelle

```
LoopApp
└── MainTabView (3 tabs)
    ├── Today (sun.max.fill)        → TodayView
    │   ├── SleepDetailView         (navigationDestination .sleep)
    │   ├── RecoveryDetailView      (navigationDestination .recovery)
    │   └── StrainDetailView        (navigationDestination .strain)
    ├── Device (applewatch)         → DeviceView
    └── Settings (gearshape.fill)   → SettingsView

Sheets root (DeviceSheetModifier):
├── NoSensorSheet        (iOS 26+ Liquid Glass / fallback)
└── SensorDetectedSheet  (iOS 26+ / fallback)

Onboarding/ — répertoire VIDE
```

## Page par page

### Today — `Features/Today/TodayView.swift:28`

Navigation par jour via `DateNavigator` en toolbar. Pull-to-refresh = recalcul incrémental.

| Bloc | Composant | Données |
|---|---|---|
| Header | `TodayGreetingHeader` | "Bonjour/Bonsoir **Théo**" (hardcodé), pill batterie, pill statut (sync bracelet / recalcul % / à jour · Xm / calculé il y a Xh / erreur) |
| Métriques | `MetricsCard` 3 anneaux **ou** `ExpressMetricsCard` | Sleep % / Recovery % / Strain x/21. En express : Strain + Stress seulement |
| Timeline | `ActivityTimeline` + `ActivityTimelineCard` | Sessions sommeil (sleep/nap si <180min) + workouts (sport, HR moy/pic, rejet). 3 items puis "Afficher plus" |
| Stress | `StressCard` (si dispo et non-express) | Score /3, bande LOW/STEADY/HIGH, sparkline, AVG/HIGH/ACTIVE dépliables |
| Coach | `CoachCard` | Conseil contextuel (Optimal Health / Moderate Day / Prioritise Sleep / Rest & Recover / Ease Off) |
| Device | `DeviceSectionHeader` + `DeviceChargingCard`/`DeviceBatteryCriticalCard` | Uniquement si charge ou batterie ≤15% |

### Sleep detail — `Features/Today/Detail/SleepDetailView.swift:35`

Backdrop dégradé par score. `SleepCoachModel`.

| Carte | Données |
|---|---|
| `SleepCoachHeroCard` | Qualité (Excellent/Bon/Correct/À améliorer), date, résumé, grille 4 : Durée / Récupérateur / Endormi à / Réveil à |
| `SleepRibbonCard` | Hypnogramme Apple-Health (Éveil/REM/Léger/Profond), curseur draggable |
| `SleepStageBalanceCard` | Barres Deep/REM/Léger (% du total) |
| `SleepInsightSection` | 3 drivers : Dette de sommeil / Efficacité / Continuité ou Fragmentation |
| `SleepTonightPlanSection` | Plan : Au lit (calculé) / Réveil (07:00 hardcodé) + message coach |

### Recovery detail — `Features/Today/Detail/RecoveryDetailView.swift:21`

Backdrop par bande (red/yellow/green/calibrating). `RecoveryCoachModel` z-score 30j.

| Carte | Données |
|---|---|
| `RecoveryHeroCard` | Score % (78pt), "RECOVERY", headline haute/moyenne/basse |
| `RecoveryMetricsCard` | 4 rows : HRV / RHR / Resp / Sommeil. Sub-score + delta "±X vs 30j" |
| `RecoveryInsightCard` | Explication statique |

### Strain detail — `Features/Today/Detail/StrainDetailView.swift:21`

Backdrop spectre bleu. `StrainCoachModel`.

| Carte | Données |
|---|---|
| `StrainHeroCard` | Strain x.x (78pt), "DAY STRAIN", headline calme/aligné/dépassé |
| `StrainMetricsCard` | 4 rows : Effort / Cible (confiance) / Récupération / RHR. Sub-score + delta |
| `StrainInsightCard` | Explication statique |

### Device — `Features/Device/DeviceView.swift:22`

List technique/debug, navigationTitle "Device".

| Section | Données |
|---|---|
| Informations appareil | Nom, Modèle (hardcodé "WHOOP 4.0"), ID local, UUID BLE, Firmwares Harvard/Boylston, nom annoncé, hello |
| Device Status | Batterie + symbole, connection, progress scanning/bonding |
| Base de données locale | Lignes décodées / total / batches / stockage / dernier HR / jours / sessions |
| Synchronisation & calcul | Dernier calcul / échantillon / connexion, état, forcer sync, toggle HR temps réel |
| Diagnostic | Copier rapport, recalcul complet (perf) |
| Logs connexion | 30 dernières lignes |

### Settings — `Features/Settings/SettingsView.swift:18`

| Section | État |
|---|---|
| Account → Profile | **Placeholder non fonctionnel** |
| App Settings → Notifications / Appearance | **Placeholders non fonctionnels** |
| Calcul du strain | Slider difficulté — fonctionnel |
| Données | Recalcul partiel/total — fonctionnel |
| Sauvegarde | Export/import `.loopbackup` — fonctionnel |
| Maintenance | Purge doublons / purge all — fonctionnel (destructif) |
| Debug | Copier logs, simuler batterie — fonctionnel |
| Sign Out | **Bouton no-op** |

### Pairing sheets (root)

- `NoSensorSheet` (2 étapes : no sensor → pairing check LED bleue + tuto YouTube générique)
- `SensorDetectedSheet` (nom/modèle/batterie + Connecter/Ignorer). iOS 26+ Liquid Glass, fallback minimal iOS <26.

## Incohérences transverses

- **Langue** : mix FR/EN partout (CoachCard conseils EN, StressCard EN, Device/Settings headers EN, le reste FR)
- **Glass shells dupliqués** : 7 copies quasi-identiques (Metrics/Coach/Stress/BraceletSync/DeviceCard/Activity/Express)
- **Recovery & Strain detail** partagent la même structure Hero/Metrics/Insight → forte duplication
- **DateNavigator** répété dans Today + 3 details

## Composants/UI morte

- `BraceletSyncStatusCard` — existe, **non branché** sur Today
- Settings Account / App Settings / Sign Out — **placeholders no-op**
- Row **Resp** en recovery — toujours "--" (champ server-only absent en local-first)
- `adviceSignals` (structured advice dans DailySnapshot) — **jamais rendu**
- `SleepSession.efficiency` / `restingHr` / `avgHrv` — **non affichés** dans Sleep detail
- `sleepStart` / `sleepEnd` (DailySnapshot) — **non utilisés** pour le plan
- `WorkoutSession.strain` / `caloriesKcal` — **non affichés** dans timeline
- `hrSamples` (cache) — **pas de courbe HR** nulle part
- Historique 30j — **pas de charts**, juste delta textuel

## Données déjà calculées mais invisibles

| Champ | Source | Endroit actuel |
|---|---|---|
| `recoveryStatus` / `recoveryBand` | DailySnapshot | Couleur uniquement, pas de label |
| `adviceSignals[]` | DailySnapshot | Rien |
| `hrSamples[]` | LoopCache | Rien (pas de chart HR) |
| `sleepStart` / `sleepEnd` | DailySnapshot | Rien (plan utilise 07:00 hardcodé) |
| `SleepSession.efficiency/restingHr/avgHrv` | SleepSession | Rien |
| `WorkoutSession.strain/caloriesKcal` | WorkoutSession | Rien (juste HR moy/pic) |
| `summary.sampleCount` (par stream) | ServerSummary | Rien |
| `computeProgress.stage` | repository | Header textuel uniquement |
| Historique complet daily (60j) | cache.daily | DateNavigator only, pas de trends |
