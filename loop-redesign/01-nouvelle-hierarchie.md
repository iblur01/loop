# 01 — Nouvelle hiérarchie proposée

> Objectifs : Page Profile → Settings → Advanced. Vraie page Device. Today enrichie. Tendances + Health Monitor + Journal + Coach ajoutés en backlog.

## Arborescence cible

```
LoopApp
├── (Onboarding — NEW,_first-run gate)
│   └── OnboardingView (4 étapes : BT/Notifications/Connect/Profile)
│
└── MainTabView (3 tabs)
    │
    ├── Today (sun.max.fill)           → TodayView (enrichie)
    │   ├── SleepDetailView            (enrichie : + in-sleep signals, + 7-nuit chart, + alarm entry)
    │   ├── RecoveryDetailView         (enrichie : + trends HRV/RHR, - row Resp)
    │   ├── StrainDetailView           (enrichie : + HR zones, + workouts du jour)
    │   ├── StressDetailView           (NEW : timeline 24h + breakdown)
    │   └── HeartRateDetailView        (NEW : courbe HR brute 6h/24h/7j)
    │
    ├── Device (applewatch)            → DeviceView (vraie page utilisateur)
    │   ├── DeviceAdvancedView         (NEW destination : tout le debug actuel)
    │   └── (sheet) NoSensorSheet / SensorDetectedSheet (déjà là)
    │
    └── Profile (person.crop.circle.fill) → ProfileView (NEW)
        ├── SettingsView               (réglages utilisateur simples)
        │   └── BackupView             (export/import .loopbackup, dédié)
        └── AdvancedView               (NEW : tout ce qui est technique/danger)

Tendances / Health Monitor / Journal / Coach = P1/P2 (cf. 04-features-a-implementer.md)
```

### Changements vs arborescence actuelle

| Avant | Après | Raison |
|---|---|---|
| 3 tabs Today/Device/Settings | 3 tabs Today/Device/**Profile** | Settings caché derrière Profile (1 niveau), visuel plus personnel |
| Settings contient tout (user + debug + destructif) | Profile → **Settings** (user) + **Advanced** (technique/danger) | Séparation claire user/dev |
| DeviceView = page debug technique | DeviceView = page user (statut + actions courantes) → DeviceAdvancedView pour le debug | Vraie page device |
| Onboarding/ vide | OnboardingView 4 étapes (BT/Notif/Connect/Profile) | First-run, comme Goose |
| Pas de Trends | TrendsView en P1 (cf. 04) | Données historiques dispo, juste pas rendues |
| Pas de Health Monitor | HealthMonitorView en P1 | HRV/RHR/resp/SpO₂/temp — la plupart déjà en cache |
| Pas de Journal | JournalView en P1 | Tag-based, important pour correlation |
| CoachCard simple | CoachView tab séparé en P2 (LLM) | Pas en M1 |

## Détail par page cible

### Today (enrichie)

Garde la structure actuelle (header + anneaux + timeline + stress + coach + device) mais ajoute :

**Nouvelles sections au scroll** :
- **Health Monitor strip** : 4 tuiles HRV / RHR / Resp / Skin Temp avec mini-sparkline 7j et delta vs baseline. Tappable → HealthMonitorView (P1). Pour les champs absents (Resp/SpO₂/SkinTemp en local-first), afficher "— bientôt" avec un tag "bientôt" plutôt que "--" silencieux.
- **Tendances rapides** : 3 mini-charts 14j (Recovery / HRV / Strain) en carousel horizontal. Tappable → TrendsView (P1).
- **Sleep debt / sommeil needed** : tuile "dette de sommeil : -1h20" + "besoin ce soir : 8h12" (déjà calculé par le moteur, juste pas rendu).
- **Weekly recap card** : bouton "Récap de la semaine" → RecapView (P1, shareable).

**Header enrichi** :
- Remplacer "Théo" hardcodé par `UserPreferences.firstName` (à ajouter)
- Pill batterie actuelle + nouvelle pill "wear time" (dernier sample HR récent)

**CoachCard** :
- Traduire en FR (incohérent avec le reste)
- `completedCount` à 0 par défaut, pas 2
- Utiliser `adviceSignals[]` structurés quand dispo (cf. 03)

### Sleep detail (enrichi)

Garde le backdrop dégradé et les 5 cartes actuelles. Ajoute :

- **In-sleep signals grid** : 4 tuiles — RHR / HRV / (Resp bientôt) / (Skin Temp bientôt). Reprend le pattern OpenWhoop `inSleepSignalsSection`. Utilise `SleepSession.restingHr` / `avgHrv` (déjà dans le modèle, non rendus).
- **7-nuit sleep/wake chart** (Gantt) : 7 lignes, axe "heures depuis 18h", montre régularité coucher/réveil. Source : `cache.sleepSessions` filtré 7 derniers. Reprend `SevenNightChart` d'OpenWhoop.
- **Alarm card** : tuile "Réveil intelligent" — mode (Off/Regular/Smart/Needed) + heure. Tappable → AlarmSheet (cf. 04). Source : `UserPreferences.alarm*` + commande bracelet `SET_ALARM_TIME=66`.
- **Real bedtime/wake** : remplacer le "07:00" hardcodé du `SleepTonightPlanSection` par `sleepStart`/`sleepEnd` du DailySnapshot si dispo, fallback heuristique.
- **Trends rows** : 6 lignes (Score / Durée / REM / Profond / HR dip / Bedtime) avec mini-sparkline + delta vs 30j. Source : `cache.daily`.

### Recovery detail (enrichi)

- **Supprimer la row Resp** (toujours "--" en local-first) → la remplacer par une row **Skin Temp** quand le champ sera dispo, sinon juste 3 rows (HRV/RHR/Sleep). Moins trompeur.
- **Trend sheet** : bouton "Voir 30j" → chart Recovery / HRV / RHR sur 30j (cf. TrendsView P1).
- **HRV 30j chart inline** : mini-chart sous la row HRV (déjà la donnée, juste pas le visuel).
- **Band label** : afficher `recoveryBand` ("green"/"yellow"/"red") comme badge textuel, pas juste la couleur.
- **Sleep debt** : tuile "dette cumulée" calculée depuis `cache.daily` (somme `sleepTargetMin - totalSleepMin`).

### Strain detail (enrichi)

- **HR zones (5)** : barres horizontales avec minutes + %. Source : re-compute depuis `hrSamples` du jour. Reprend `HeartRateZonesSection` de Goose.
- **Day strain curve** : courbe strain cumulé heure par heure (cf. `StrainV2DailyLoadCard` Goose).
- **Workouts du jour** : liste des `WorkoutSession` du jour sélectionné (au lieu d'être seulement sur Today). Card tappable → WorkoutDetailView (P2, cf. 04).
- **Calories** : tuile "dépense estimée" (calcul depuis strain + profile, cf. 04).

### Stress detail (NEW)

Page entière pour le stress (actuellement juste une card expandable sur Today) :
- **Hero** : score /3 avec bande couleur, heure du dernier sample
- **Timeline 24h** : courbe score heure par heure + zones LOW/STEADY/HIGH colorées (cf. `StressV2TimelineChart` Goose)
- **Breakdown** : 3 tuiles High minutes / Medium minutes / Low minutes (cf. `StressV2BreakdownSection`)
- **Stats** : AVG / MAX / Activity minutes
- **Trend 7j** : mini-chart

### Heart Rate detail (NEW)

- **Courbe HR 6h/24h/3j/7j** : source `cache.hrSamples` (déjà en cache, jamais rendu). Reprend `HeartRateDetailView` d'OpenWhoop.
- **Stats** : AVG / MIN / MAX / Latest
- **Zones overlay** : 5 zones colorées derrière la courbe

### Device (vraie page user)

Replace le debug actuel par :

```
DeviceView
├── Hero : nom du bracelet + image WHOOP + battery % grand + animation de charge
├── Status : Connected/Connecting/Scanning/Disconnected + last sync freshness
├── Quick actions grid (4 boutons) :
│   ├── Connecter / Déconnecter
│   ├── Forcer la sync
│   ├── HR temps réel (toggle)
│   └── Oublier le bracelet (confirm)
├── Bandeau strap-stuck (si détecté) : action "Redémarre"
├── Notifications battery (toggle + seuils) — si pas déjà dans Settings
└── Lien "Informations avancées" → DeviceAdvancedView
```

`DeviceAdvancedView` récupère TOUT le contenu actuel de DeviceView (firmware, UUID, DB stats, logs, diagnostic, recalcul perf) — rien n'est perdu, juste déplacé.

### Profile (NEW)

```
ProfileView
├── Header : avatar (initiales) + nom + "WHOOP 4.0 · theo-whoop"
├── Section "Profil corporel" :
│   ├── Prénom
│   ├── Date de naissance → âge
│   ├── Sexe (F/M/NB)
│   ├── Taille (cm / ft-in selon unit system)
│   ├── Poids (kg / lb)
│   └── Unit system (Imperial/Metric toggle)
├── Section "Réveil" :
│   ├── Heure de réveil cible (pour le sleep plan — remplace le 07:00 hardcodé)
│   └── (P1) Mode alarme (Off/Regular/Smart/Needed)
├── Section "Objectif sommeil" : heures cibles par nuit (remplace le 8h par défaut)
├── Section "Difficulté du strain" : slider (ex-Settings)
├── Section "Préférences" :
│   ├── Langue (FR/EN — ajouter L10n)
│   ├── Apparence (System/Light/Dark)
│   └── Notifications (master toggle + battery alerts + recovery-ready)
├── Section "Données" :
│   ├── Recalcul partiel / total (ex-Settings)
│   ├── Sauvegarde .loopbackup → BackupView
│   └── Maintenance (purge) → confirm dialog
└── Lien "Avancé" → AdvancedView
```

`AdvancedView` récupère : Debug (copier logs, simulations Live Activity), Logs connexion, infos firmware détaillées, recalcul complet perf, et tout ce qui est cassable.

## Mapping données → pages (récap)

| Donnée | Page cible | Source |
|---|---|---|
| `DailySnapshot.*` | Today + 3 details | cache |
| `SleepSession.efficiency/restingHr/avgHrv` | Sleep detail (in-sleep grid) | cache |
| `SleepSession.stages` | Sleep detail (hypnogramme, déjà rendu) | cache |
| `StressSnapshot.timeline` | Stress detail (24h) + Trends | cache |
| `hrSamples[]` | Heart Rate detail + Strain zones | cache |
| `adviceSignals[]` | Today coach card + (P2) Coach | cache |
| `recoveryBand` / `recoveryStatus` | Recovery detail (badge) | cache |
| `sleepStart` / `sleepEnd` | Sleep detail plan | cache |
| `WorkoutSession.strain/caloriesKcal` | Strain detail + Workout detail | cache |
| Historique daily 60j | Trends (P1) | cache |
| Battery + charging | Device hero + Profile notifications | connection.state |
| `computeProgress.stage` | Today header + Settings/Advanced | repository |

## À valider avant implémentation

1. **Tab Profile** vs tab Settings : Profile rend la page plus personnelle, mais plus de taps pour atteindre les réglages. OK pour toi ?
2. **Onboarding** : 4 étapes comme Goose (BT/Notif/Connect/Profile) ou plus court (Connect/Profile only) ?
3. **Device tab** : tu veux vraiment un tab séparé pour Device, ou plutôt une entry dans Profile → Device ? (OpenStrap a mis Device dans Profile ; Goose a un bouton device dans la top bar de Home)
4. **Trends/Health Monitor/Journal/Coach** : P1 tout, ou prioriser Trends + Journal d'abord, Coach en P2 ?
5. **Langue** : FR uniquement, ou FR+EN bilingue comme OpenWhoop ?
