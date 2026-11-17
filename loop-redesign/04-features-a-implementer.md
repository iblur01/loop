# 04 — Features à implémenter (backlog priorisé)

Synthèse des features présentes dans Goose / my-whoop / openwhoop-gen4-debug / OpenStrap-edge et absentes de Loop aujourd'hui. Classées par priorité produit (P0 = doit avoir pour la refonte, P1 = should have, P2 = nice to have).

> Pour le détail technique feature-par-feature (fichiers, algos, commandes BLE), voir `05-inventaire-depots-externes.md`.

## P0 — Refonte des pages existantes

| # | Feature | Source d'inspiration | Travail estimé |
|---|---|---|---|
| P0-1 | **Onboarding 4 étapes** (BT/Notif/Connect/Profile) | Goose `OnboardingView.swift` | 2-3j |
| P0-2 | **ProfileView** (prénom, DOB, sexe, taille, poids, unit system, heure de réveil, objectif sommeil) | Goose `MoreProfileView.swift` + OpenWhoop `SettingsView.swift` | 2j |
| P0-3 | **DeviceView** repensée en page user (hero batterie + actions courantes) | Goose `DeviceView.swift` + OpenStrap `Profile` | 1-2j |
| P0-4 | **DeviceAdvancedView** (tout le debug actuel déplacé) | — | 0.5j (cut/paste) |
| P0-5 | **AdvancedView** sous Profile (Debug, simulations, recalcul perf) | — | 0.5j (cut/paste) |
| P0-6 | **Activation données niveau 1** (cf. 03) | — | 1-2j |
| P0-7 | **Traduction FR** des chaînes EN | — | 0.5j |
| P0-8 | **Fusion glass shells** (7 → 1) | — | 1j |
| P0-9 | **Suppression placeholders morts** (cf. 02) | — | 0.5j |

## P1 — Features nouvelles majeures

| # | Feature | Source | Travail estimé | Prérequis |
|---|---|---|---|---|
| P1-1 | **TrendsView** (7/30/90d charts Recovery / HRV / RHR / Strain / Sleep) | OpenWhoop `TrendsView.swift` + `MetricChart.swift` + `MetricKind.swift` | 3-5j | Données en cache (✓) |
| P1-2 | **HeartRateDetailView** (courbe HR 6h/24h/3j/7j + stats + zones) | OpenWhoop `HeartRateDetailView.swift` | 2-3j | `hrSamples` en cache (✓) |
| P1-3 | **StressDetailView** (timeline 24h + breakdown + trend 7j) | Goose `StressV2OverviewPage` | 2-3j | `StressSnapshot.timeline` en cache (✓) |
| P1-4 | **Sleep 7-nuit chart** (Gantt régularité coucher/réveil) | OpenWhoop `SevenNightChart.swift` | 1-2j | `sleepSessions` en cache (✓) |
| P1-5 | **Sleep in-sleep signals grid** (RHR/HRV/Resp bientôt/Skin Temp bientôt) | OpenWhoop `SleepView.inSleepSignalsSection` | 1j | SleepSession fields (✓ pour RHR/HRV) |
| P1-6 | **HR zones 5** (Strain detail + Workout detail) | Goose `HeartRateZonesSection` + OpenWhoop `WorkoutDetailView.zoneSection` | 2j | Calcul depuis `hrSamples` + `restingHR` + `maxHR` |
| P1-7 | **Day strain curve** (cumul heure par heure) | Goose `StrainV2DailyLoadCard` | 1-2j | Calcul depuis `hrSamples` |
| P1-8 | **Health Monitor** (HRV/RHR/Resp/SpO₂/Temp avec "hors normal pour toi") | Goose `HealthMonitorView` + cadrage OpenWhoop | 3-5j | Resp/SpO₂/Temp nécessitent exposer les champs du codec (cf. 03 niveau 3) |
| P1-9 | **Journal** (tags : alcool/caféine/repas tardif/voyage/maladie/stress/supplements + note libre + correlation) | Cadrage OpenWhoop P1 | 5-7j | Nouveau modèle persistence |
| P1-10 | **Smart alarm 2-couches** (firmware RTC + smart-wake HR heuristic) | my-whoop `SmartAlarmController.swift` + `AlarmView.swift` | 3-5j | Commande BLE `SET_ALARM_TIME=66` (✓ dans WhoopProtocol) |
| P1-11 | **Notifications locales** (battery alerts edge-triggered + recovery-ready + sync-stale nudge) | my-whoop `BatteryAlertMonitor.swift` + `RecoveryNotifier.swift` + `SyncNudge.swift` | 2-3j | `UNUserNotificationCenter` |
| P1-12 | **Sleep debt + sleep needed** tuiles (Today + Sleep detail) | OpenStrap `Sleep` + cadrage | 1j | Calcul depuis `cache.daily` |
| P1-13 | **Recap hebdomadaire shareable** (card avec chiffres clés + `ShareLink`) | OpenStrap `Recap` | 1-2j | Données en cache (✓) |
| P1-14 | **WorkoutDetailView** (header + stats strip + 6-zone breakdown + calories) | OpenWhoop `WorkoutDetailView.swift` | 2j | `WorkoutSession` + calcul zones |
| P1-15 | **Calories** (BMR Mifflin-St Jeor + activity) | OpenWhoop server `calories.py` | 1-2j | Profile body (P0-2) |

## P2 — Nice to have / plus loin

| # | Feature | Source | Travail estimé | Notes |
|---|---|---|---|---|
| P2-1 | **Coach IA LLM** (chat avec OpenAI Responses API + tool calling + ChatGPT OAuth) | Goose `OpenAICoachChat.swift` + `CoachLocalToolContext.swift` | 2-3 semaines | Déjà planifié Loop Milestone 2 (COACH-01..05) |
| P2-2 | **Live Workout** (enregistreur sport temps réel + GPS + Live Activity + Dynamic Island) | Goose `FitnessLiveWorkoutViews.swift` + `WorkoutLiveActivityController.swift` + OpenStrap `Live workout` | 2-3 semaines | CLLocationManager + ActivityKit |
| P2-3 | **Passive workout auto-detection** (depuis movement packets) | Goose `PassiveActivityDetector.swift` | 1 semaine | Band movement packets |
| P2-4 | **Cardio Load** (weekly training load + status calibration/detraining/peaking…) | Goose `CardioLoadView.swift` + `CardioLoadAlgorithmSummary` | 1-2 semaines | Algo Goose à porter |
| P2-5 | **Energy Bank** (charge/drain daily) | Goose `EnergyBankView.swift` | 1 semaine | Algo Goose |
| P2-6 | **Sleep consistency score** | openwhoop-gen4-debug `sleep_consistency.rs` | 2-3j | ~80 lignes math pure |
| P2-7 | **Respiratory rate / SpO₂ / Skin Temp** (exposer les champs du codec) | openwhoop-gen4-debug `whoop_data.rs` (déjà décodé) | 1-2 semaines | Bouge le moteur Swift pour exposer ces champs dans `DailySnapshot` |
| P2-8 | **Deep-link routing** (`loop://today`, `loop://device`, etc.) | Goose `AppRouter.swift` | 2-3j | utile pour notifications → page |
| P2-9 | **Sync toast + failure sheet** (global root overlay) | Goose `RootView.swift` `SyncToastHost` | 1-2j | meilleur que le pill actuel |
| P2-10 | **Onboarding redo** (depuis Advanced) | Goose `MoreDebugViews.swift:416` | 0.5j | |
| P2-11 | **Bilingual FR/EN** (LanguageManager + L10n dictionary) | my-whoop `LanguageManager.swift` | 1 semaine | gros travail si on veut vraiment bilingue |
| P2-12 | **Auto workout detection** (sans GPS, juste HR) | OpenWhoop server `exercise.py` | 1-2 semaines | déjà partiellement dans le moteur (workoutSessions) |

## Features présentes dans les dépôts externes MAIS non pertinentes pour Loop

| Feature | Pourquoi pas Loop |
|---|---|
| Goose **Overnight Guard** (capture overnight raw frames durable spool) | Trop research/RE, pas user-facing |
| Goose **Packet/Algorithm/Calibration debug surfaces** | Déjà couvert par AdvancedView (version minimal) |
| Goose **WHOOP 5.0 (Gen5) support** | Loop cible WHOOP 4.0 seulement |
| openwhoop-gen4-debug **WHOOP API firmware download** | Serveur-dépendant, exclu par offline-first |
| OpenStrap **self-hosted backend toggle** | Loop est 100% offline, pas de backend |
| OpenWhoop **server-dependent metrics** | Loop est offline-first |
| openwhoop-gen4-debug **PostgreSQL sync** | Pas pertinent |

## Décisions à prendre

1. **P1-9 Journal** : priorité haute (cadrage OpenWhoop le met P1, Goose ne l'a pas encore) ou P2 ? Le journal est précieux pour la corrélation recovery/sleep.
2. **P1-10 Smart alarm** : 2-couches complet (firmware + smart-wake) ou juste firmware RTC d'abord (1j) puis smart-wake en P2 ?
3. **P2-2 Live Workout** : c'est gros (GPS + Live Activity). Tu en as besoin en M1 ou plus tard ?
4. **P2-7 Resp/SpO₂/Skin Temp** : c'est le chantier moteur (LoopStrapEngine) le plus impactant pour enrichir Recovery + Health Monitor. Lancer en parallèle de la refonte UI ou après ?
5. **P2-1 Coach LLM** : tu confirmes que c'est Milestone 2 (donc hors cette refonte) ?
