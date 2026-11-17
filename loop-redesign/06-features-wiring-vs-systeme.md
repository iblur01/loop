# 06 — Classification des features : wiring UI vs système à construire

> Seuil de classification :
> - **Wiring UI** = les données sont déjà en cache (`LoopCache` / `DailySnapshot` / `connection.state`) ou le calcul est trivial dans une view. Pas de nouveau modèle de persistence, pas de BLE, pas de framework système, pas d'algo à porter. Juste créer/brancher des vues SwiftUI.
> - **Système à construire** = nécessite un nouveau modèle persistence, des commandes BLE, un framework iOS (UNUserNotificationCenter, CLLocationManager, ActivityKit), un algo à porter depuis un dépôt externe, ou une modification du moteur (`LoopStrapEngine` / `LocalMetricsEngine`).

## A — Wiring UI pur (données déjà là, juste créer/brancher)

### A1 — Quick wins (champ → label, ~1h chacun)

| # | Feature | Donnée source | Page cible | Travail |
|---|---|---|---|---|
| A1-1 | Sleep in-sleep grid : Efficacité | `SleepSession.efficiency` (`LoopModels.swift:264`) | Sleep detail | 1 tuile |
| A1-2 | Sleep in-sleep grid : FC repos | `SleepSession.restingHr` (`:265`) | Sleep detail | 1 tuile |
| A1-3 | Sleep in-sleep grid : HRV | `SleepSession.avgHrv` (`:266`) | Sleep detail | 1 tuile |
| A1-4 | Real bedtime (remplace 07:00 hardcodé) | `DailySnapshot.sleepStart` (`:133`) | Sleep detail plan | Remplacer `wakeText`/`bedtimeText` dans `SleepCoachModel` |
| A1-5 | Real wake | `DailySnapshot.sleepEnd` (`:134`) | Sleep detail plan | idem |
| A1-6 | Recovery band badge textuel | `DailySnapshot.recoveryBand` (`:142`) | Recovery detail | Badge "Green"/"Yellow"/"Red" |
| A1-7 | Recovery status sous-headline | `DailySnapshot.recoveryStatus` (`:141`) | Recovery detail | "Haute"/"Moyenne"/"Basse" |
| A1-8 | Workout strain badge | `WorkoutSession.strain` (`:277`) | Activity Timeline + Strain detail | Badge sur card workout |
| A1-9 | Workout calories tuile | `WorkoutSession.caloriesKcal` (`:280`) | Activity Timeline | Tuile calories |
| A1-10 | CoachCard depuis adviceSignals[] | `DailySnapshot.adviceSignals` (`:157`) | Today coach card | Boucler sur les signals au lieu du if/else dur |
| A1-11 | Nom user dynamique | `UserPreferences.firstName` (à ajouter, juste UserDefaults) | Today header | Remplacer `"Théo"` hardcodé |

### A2 — Pages/Charts à construire (données en cache, ~1-5j chacun)

| # | Feature | Donnée source | Page cible | Travail | Inspiration |
|---|---|---|---|---|---|
| A2-1 | **HeartRateDetailView** (courbe HR 6h/24h/3j/7j + AVG/MIN/MAX) | `LoopCache.hrSamples[]` (déjà en cache, jamais rendu) | NEW page détail | 2-3j | my-whoop `HeartRateDetailView.swift` |
| A2-2 | **TrendsView** (7/30/90d : Recovery/HRV/RHR/Strain/Sleep) | `LoopCache.daily[]` (60j en cache) | NEW tab ou page | 3-5j | my-whoop `TrendsView.swift` + `MetricChart.swift` + `MetricKind.swift` |
| A2-3 | **Sleep 7-nuit chart** (Gantt régularité coucher/réveil) | `LoopCache.sleepSessions[]` | Sleep detail | 1-2j | my-whoop `SevenNightChart.swift` |
| A2-4 | **StressDetailView** (timeline 24h + breakdown High/Med/Low + trend 7j) | `StressSnapshot.timeline[]` + `summary` (en cache) | NEW page détail | 2-3j | Goose `StressV2OverviewPage` |
| A2-5 | **HR zones 5** (Strain detail + Workout detail) | calcul depuis `hrSamples` + `restingHR` + `maxHR` (maxHR = max du cache) | Strain detail | 2j | Goose `HeartRateZonesSection` |
| A2-6 | **Day strain curve** (cumul heure par heure) | calcul depuis `hrSamples` par heure | Strain detail | 1-2j | Goose `StrainV2DailyLoadCard` |
| A2-7 | **Sleep debt + sleep needed** tuiles | calcul `Σ(sleepTargetMin - totalSleepMin)` sur 7j glissants depuis `cache.daily` | Today + Sleep detail | 1j | OpenStrap Sleep |
| A2-8 | **Recap hebdomadaire shareable** | `cache.daily` 7 derniers jours | Today → RecapView | 1-2j | OpenStrap `Recap` + `ShareLink` |
| A2-9 | **WorkoutDetailView** (header + stats strip + 6-zone HR breakdown + calories) | `WorkoutSession` + calcul zones depuis `hrSamples` | NEW page détail (depuis Activity Timeline) | 2j | my-whoop `WorkoutDetailView.swift` |

### A3 — Refactor UI / nettoyage (pas de donnée nouvelle)

| # | Feature | Travail |
|---|---|---|
| A3-1 | Traduction FR des ~15 chaînes EN (CoachCard, StressCard, DeviceView, SettingsView, DateNavigator) | 0.5j |
| A3-2 | Fusion 7 glass shells → 1 `LoopGlassShell(accent:)` partagée | 1j |
| A3-3 | Suppression 8 placeholders morts (Settings Account/App Settings/Appearance/Sign Out, row Resp, URL YouTube, completedCount=2, "Théo") | 0.5j |
| A3-4 | Fusion Recovery/Strain Hero/Metrics/Insight → 1 `MetricFamilyDetailView` générique | 1-2j |
| A3-5 | Fusion Recovery/Strain GradientBackdrop → 1 `BandGradientBackdrop(band:)` | 0.5j |
| A3-6 | Fusion section headers (DeviceSectionHeader + ActivityTimelineHeader) → `LoopSectionHeader` | 0.5j |
| A3-7 | `DateFormatter` en `static let` partagés (généraliser les quelques-uns déjà faits) | 0.5j |
| A3-8 | **DeviceView repensée** en page user (hero batterie + 4 actions courantes) — cut/paste du debug vers DeviceAdvancedView | 1-2j |
| A3-9 | **DeviceAdvancedView** (tout le debug actuel déplacé) | 0.5j |
| A3-10 | **ProfileView** (prénom/DOB/sexe/taille/poids/units/heure réveil/objectif sommeil/difficulté strain/préférences) — UserDefaults seulement | 2j |
| A3-11 | **AdvancedView** sous Profile (Debug/simulations/recalcul perf/logs) — cut/paste | 0.5j |
| A3-12 | **BackupView** dédié (déplacer section Sauvegarde de Settings + ajouter AirDrop `ShareLink`) | 1j |
| A3-13 | **Onboarding 4 étapes** (BT/Notif/Connect/Profile) — UI + UserDefaults, pas de système | 2-3j |
| A3-14 | **Deep-link routing** (`loop://today`, `loop://device`, etc.) — `NSUserActivity` / URL scheme | 2-3j |
| A3-15 | **Sync toast + failure sheet** (root overlay) — UI seulement, lit `coordinator.status` déjà publié | 1-2j |
| A3-16 | Simplifier `StressCard` Today (non-expandable, navigue vers StressDetailView) une fois A2-4 fait | 0.5j |

### Total A (wiring UI pur) : ~30-45 jours-homme

---

## B — Système à construire (algo/persistence/BLE/framework)

### B1 — Système léger (algo pur ou petit modèle, ~2-5j)

| # | Feature | Système à construire | Travail | Source à porter |
|---|---|---|---|---|
| B1-1 | **Sleep consistency score** (circular mean + CV de start/end/midpoint/duration sur 7j) | Algo pure math (~80 LOC), pas de persistence (calcul à la volée depuis `cache.sleepSessions`) | 2-3j | openwhoop-gen4-debug `sleep_consistency.rs` + `helpers/time_math.rs` |
| B1-2 | **Calories** (BMR Mifflin-St Jeor + activity from strain) | Calcul depuis profile body (P0 ProfileView) + strain. Pas de persistence (calcul à la volée). | 1-2j | my-whoop server `calories.py` |
| B1-3 | **Journal V1** (tags + note libre + date, sans correlation) | Nouveau modèle `JournalEntry` + persistence (SQLite via GRDB ou JSON dans cache). UI calendar + editor. | 3-5j | Cadrage OpenWhoop (pas d'implé de référence) |
| B1-4 | **Health Monitor V1** (HRV + RHR + Sleep seulement, resp/SpO₂/temp en placeholder "bientôt") | UI seulement — les 3 métriques sont en cache. Les placeholders "bientôt" sont du wiring. | 2-3j | Goose `HealthMonitorView` |

### B2 — Système moyen (framework iOS ou BLE, ~3-10j)

| # | Feature | Système à construire | Travail | Source à porter |
|---|---|---|---|---|
| B2-1 | **Smart alarm 2-couches** (firmware RTC + smart-wake HR heuristic) | (a) Commandes BLE 66/67/68/69/96/97 — vérifier `WhoopProtocol`, ajouter si manquant. (b) `SmartAlarmController` (logique pure testable, fenêtre lead-time, HR rise ≥5 bpm, EXIT_HIGH_FREQ_SYNC invariant). (c) Persistence config alarm (`UserPreferences.alarm*`). (d) UI `AlarmSheet` (mode Off/Regular/Smart/Needed + heure + pattern haptic). | 3-5j | my-whoop `SmartAlarmController.swift` + `AlarmView.swift` + `Commands.swift` |
| B2-2 | **Notifications locales** (battery alerts edge-triggered + recovery-ready + sync-stale nudge) | (a) `UNUserNotificationCenter` permission request. (b) `BatteryAlertMonitor` (edge-triggered cross-down threshold, re-arm on charge) — pure + testable. (c) `RecoveryNotifier` (fire once per UTC day quand recovery dispo). (d) `SyncNudge` (schedule-ahead 6h, cancel on sync). (e) UI config seuils. | 2-3j | my-whoop `BatteryAlertMonitor.swift` + `BatteryAlerts.swift` + `RecoveryNotifier.swift` + `SyncNudge.swift` |
| B2-3 | **Journal correlation** (au-delà du V1 : "alcool la veille → -12% recovery en moyenne") | Algo stats (moyenne recovery conditionnelle par tag, sur fenêtre glissante). Pas de ML, juste des agrégats. | +3-5j sur B1-3 | — |
| B2-4 | **Respiratory rate** (exposer le champ depuis le codec) | Modifier `LoopStrapEngine` pour décoder `resp_rate` depuis les history packets V12/V24 et l'exposer dans `DailySnapshot.respRateBpm`. Le raw est déjà décodé par le codec Rust. | 3-5j (côté moteur) | openwhoop-gen4-debug `whoop_data.rs` |
| B2-5 | **SpO₂ %** | idem — modifier le moteur pour exposer `spo2Pct` dans `DailySnapshot`. Gen4 limité, Gen5 packet V18. | 3-5j | openwhoop-gen4-debug `whoop_data.rs` |
| B2-6 | **Skin temperature deviation** | idem — décoder `skin_temp` + calculer delta vs baseline 30j (nécessite baseline = moyenne glissante, persister ou calculer à la volée). | 5-7j | openwhoop-gen4-debug `whoop_data.rs` |
| B2-7 | **Calendar heatmap** (TrendsView enrichment : heatmap année complète) | UI custom (grid 365 jours colorée par recovery). Données en cache (60j) + placeholder pour plus ancien. | 2-3j | — |

### B3 — Système lourd (multi-semaines)

| # | Feature | Système à construire | Travail | Source à porter |
|---|---|---|---|---|
| B3-1 | **Coach IA LLM** (chat OpenAI Responses API + tool calling + ChatGPT OAuth) | (a) OAuth device-code flow (`CodexSelfContainedAuthClient`) + keychain. (b) Streaming SSE + tool calling (`load_stats`, `get_activities`, etc.). (c) Persistence conversation (UserDefaults, 80 msg cap). (d) UI chat (bubbles, composer, cancel, suggestions). (e) `CoachLocalToolContext` (JSON context depuis cache). (f) Model presets (gpt-5.5 low/medium/high). | 2-3 semaines | Goose `OpenAICoachChat.swift` + `OpenAICoachResponsesClient.swift` + `CodexEmbeddedAuth.swift` + `CoachLocalToolContext.swift` + `CoachChatScreen.swift` |
| B3-2 | **Live Workout** (enregistreur sport temps réel + GPS + Live Activity + Dynamic Island) | (a) `CLLocationManager` (background updates, `showsBackgroundLocationIndicator`, 5m filter, cap 360 route points). (b) `ActivitySessionModel` (60Hz tick, avg/max HR, 5 zones, pause/resume/end, control lock 5s). (c) 19 `ActivityKind` + pace zones + elevation. (d) `ActivityKit` Live Activity (lock screen + Dynamic Island expanded/compact/minimal). (e) `WorkoutLiveActivityController` (start/update/end 15s min interval, 30min dismissal). (f) High-freq history sync pendant workout (cmd 96/97). (g) Post-workout summary (route map, pace block, zone ribbon, elevation chart, activity rings). | 2-3 semaines | Goose `ActivityModels.swift` + `ActivitySessionModel.swift` + `ActivityLocationTracker.swift` + `FitnessLiveWorkoutViews.swift` + `FitnessSummaryViews.swift` + `WorkoutLiveActivityController.swift` + `GooseWorkoutLiveActivityExtension/` |
| B3-3 | **Passive workout auto-detection** (depuis band movement packets, sans manual start) | `PassiveActivityDetector` (8s GPS prime, 45s start duration, 120s stop quiet, 60s min recording, classifie activity depuis pace/HR/motion). Wire sur `GooseAppModel+PacketPublishing.swift:702`. | 1 semaine | Goose `PassiveActivityDetector.swift` |
| B3-4 | **Cardio Load** (weekly training load + status Calibrating/Detraining/Maintaining/Peaking/Productive/Fatigued/Overtraining) | Algo `CardioLoadAlgorithmSummary` à porter. UI complète (hero + trend panel + detail chart + breakdown + calendar sheet + calibration sheet). | 1-2 semaines | Goose `CardioLoadView.swift` + `HealthCardioViews.swift` |
| B3-5 | **Energy Bank** (charge/drain daily, primary sleep charge contribution) | Algo Goose à porter. UI (chart energy+stress, total charged/drawn, usage list). | 1 semaine | Goose `EnergyBankView.swift` + `HealthSupplementalViews.swift:6` |
| B3-6 | **Bilingual FR/EN** (LanguageManager + L10n dictionary complet) | Système i18n : `LanguageManager` + dictionnaire `L10n` (toutes les chaînes de l'app). Pas de `.strings` files, tout in-code comme my-whoop. | 1 semaine | my-whoop `Localization/LanguageManager.swift` |
| B3-7 | **Sleep stages précis (light/deep/REM) réel** (pas estimé) | Port un classifieur : soit le PPG-green 4-cat du notebook openwhoop-gen4-debug (simple, ~100 LOC), soit un classifieur ML plus poussé. À valider contre données réelles. | 1-2 semaines | openwhoop-gen4-debug `notebooks/sleep-detection.ipynb` (PPG-green thresholds) |
| B3-8 | **Recovery score weighted multi-factor** (HRV + RHR + sleep + resp, comme WHOOP) | Modifier `LoopStrapEngine.Recovery` pour weighted multi-factor au lieu du logistic HRV seul. `RecoveryCoachModel` le fait déjà en UI (à porter dans l'engine). Validation contre données réelles. | 1-2 semaines | Goose `goose_recovery_v0` + `RecoveryCoachModel.swift` (déjà fait en UI) |

### Total B (système à construire) :
- B1 (léger) : ~10-15 jh
- B2 (moyen) : ~20-35 jh
- B3 (lourd) : ~8-12 semaines

---

## C — Matrice priorisation rapide

| Priorité | Feature | Catégorie | Effort | Dépendance |
|---|---|---|---|---|
| **P0** | A3-3 Suppression placeholders morts | A3 | 0.5j | — |
| **P0** | A3-1 Traduction FR | A3 | 0.5j | — |
| **P0** | A3-10 ProfileView | A3 | 2j | — |
| **P0** | A3-8 DeviceView repensée + A3-9 Advanced | A3 | 2j | — |
| **P0** | A3-11 AdvancedView + A3-12 BackupView | A3 | 1.5j | — |
| **P0** | A3-13 Onboarding 4 étapes | A3 | 2-3j | — |
| **P0** | A1 (tous quick wins) | A1 | 2j | — |
| **P0** | A3-2 Fusion glass shells | A3 | 1j | — |
| **P1** | A2-1 HeartRateDetailView | A2 | 2-3j | — |
| **P1** | A2-2 TrendsView | A2 | 3-5j | — |
| **P1** | A2-4 StressDetailView | A2 | 2-3j | — |
| **P1** | A2-3 Sleep 7-nuit | A2 | 1-2j | — |
| **P1** | A2-5 HR zones + A2-6 Day strain curve | A2 | 3-4j | — |
| **P1** | A2-9 WorkoutDetailView | A2 | 2j | A2-5 |
| **P1** | A2-7 Sleep debt + sleep needed | A2 | 1j | — |
| **P1** | A2-8 Recap hebdo | A2 | 1-2j | — |
| **P1** | A3-4/A3-5/A3-6 Fusions Hero/Backdrop/Header | A3 | 2j | — |
| **P1** | B2-2 Notifications locales | B2 | 2-3j | — |
| **P1** | B2-1 Smart alarm 2-couches | B2 | 3-5j | B2-2 (permission) |
| **P1** | B1-3 Journal V1 | B1 | 3-5j | — |
| **P1** | B1-4 Health Monitor V1 | B1 | 2-3j | — |
| **P1** | B1-2 Calories | B1 | 1-2j | A3-10 (profile) |
| **P1** | B1-1 Sleep consistency | B1 | 2-3j | — |
| **P2** | B2-3 Journal correlation | B2 | 3-5j | B1-3 |
| **P2** | B2-4/B2-5/B2-6 Resp/SpO₂/Skin Temp | B2 | 2-3 sem | — |
| **P2** | B2-7 Calendar heatmap | B2 | 2-3j | A2-2 |
| **P2** | A3-14 Deep-link routing | A3 | 2-3j | B2-2 (notifications) |
| **P2** | A3-15 Sync toast | A3 | 1-2j | — |
| **P2** | B3-1 Coach LLM | B3 | 2-3 sem | — |
| **P2** | B3-2 Live Workout | B3 | 2-3 sem | — |
| **P2** | B3-3 Passive auto-detect | B3 | 1 sem | B3-2 |
| **P2** | B3-4 Cardio Load | B3 | 1-2 sem | — |
| **P2** | B3-5 Energy Bank | B3 | 1 sem | — |
| **P2** | B3-6 Bilingual FR/EN | B3 | 1 sem | — |
| **P3** | B3-7 Sleep stages réel | B3 | 1-2 sem | — |
| **P3** | B3-8 Recovery weighted | B3 | 1-2 sem | B2-4/5/6 |

---

## D — Résumé exécutif

| Catégorie | Count | Effort total | Sans système |
|---|---|---|---|
| **A — Wiring UI pur** | 36 features | ~30-45 jh | ✅ Aucun système à construire |
| **B1 — Système léger** | 4 features | ~10-15 jh | 🟡 Algo pur ou petit modèle persistence |
| **B2 — Système moyen** | 7 features | ~20-35 jh | 🟠 Framework iOS (UNUserNotificationCenter, BLE commands) ou modification moteur |
| **B3 — Système lourd** | 8 features | ~8-12 sem | 🔴 Multi-semaines (LLM, GPS, ActivityKit, algos complexes, i18n) |

**Recommandation ordre d'attaque** :
1. **P0 tout-en-wiring** (A3 + A1) : ~2 semaines → app nettoyée, Profile/Device/Onboarding en place, données niveau 1 affichées
2. **P1 wiring** (A2 + fusions A3) : ~3 semaines → Trends/HR/Stress/Workout details, charts
3. **P1 systèmes légers/moyens** (B1 + B2-1/B2-2) : ~3 semaines → Notifications, Smart alarm, Journal, Health Monitor, Calories, Sleep consistency
4. **P2/P3 systèmes lourds** (B3) : backlog, par besoin

Soit ~8 semaines pour P0+P1 complet (wiring + systèmes légers/moyens), puis backlog P2/P3.
