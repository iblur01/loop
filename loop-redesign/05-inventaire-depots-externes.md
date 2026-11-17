# 05 — Inventaire feature-par-feature des dépôts externes

> Référence pour l'implémentation. Pour chaque feature : où la trouver, ce qu'elle fait, ce qu'il faut pour la porter vers Loop.

## Sources

| Repo | Langue | Plateforme | Rôle |
|---|---|---|---|
| `/Users/theo/dev/whoop/goose` | Swift + Rust | iOS 26+ | Alpha très complète, WHOOP 5.0 + Gen4, AI coach |
| `/Users/theo/dev/whoop/my-whoop` | Swift | iOS legacy | OpenWhoop (server-dependent) + cadrage redesign |
| `/Users/theo/dev/whoop/openwhoop-gen4-debug` | Rust | CLI | Codec + algos purs, Gen4+Gen5 |
| `github.com/OpenStrap/edge` | Dart | Flutter iOS+Android | 12+ écrans, déterministe, screenshots publiés |

---

## 1. Smart Alarm / Réveil intelligent

### my-whoop (le plus complet, 2-couches)
- `Alarm/AlarmView.swift` : config UI (heure, smart-wake toggle, lead 5-30min, enable/disable)
- `Alarm/SmartAlarmController.swift` : smart-wake = fenêtre `leadMinutes` avant heure, `ENTER_HIGH_FREQ_SYNC` (cmd 96) pour HR dense, fire early sur HR rise ≥5 bpm, `EXIT_HIGH_FREQ_SYNC` (cmd 97) sur tous les chemins (safety invariant)
- `BLE/Commands.swift` `setAlarmPayload` : cmd `SET_ALARM_TIME=66` payload `[0x01]+epoch u32 LE+[0x00×4]`
- Commandes : `setAlarmTime=66`, `getAlarmTime=67`, `runAlarm=68` (buzz immédiat), `disableAlarm=69`
- Test alarm buzz : `runHapticsPattern(patternId=2, loops=3)` + `runAlarm`
- **Note** : firmware alarm fire même si app killed / phone locked (true wearable alarm)

### Goose (Gen4 + Gen5, plus élaboré)
- `HealthSleepSheetsViews.swift:223` `SleepV2AlarmSheet` : 4 modes (Smart/Regular/Needed/Off) + pattern haptic (Progressive/Gentle/Medium/Intense)
- `GooseBLEClient+UserActions.swift:372` : `queryWhoopAlarm`, `setWhoopAlarm`, `runWhoopAlarmNow`, `disableWhoopAlarms`
- Gen5 payload 21 bytes (reverse-engineered depuis pcapng)
- `SleepBridgeViews.swift:90` : `SleepAlarmBridgeSection` (debug/evidence)

### openwhoop-gen4-debug
- `packet_implementations.rs:203-230` `alarm_time()`
- Gen4 payload `[rev=0x01][unix u32 LE][padding 4 bytes]` — **les 4 padding bytes sont inconnus** (smart-wake window ?)
- `device.rs` `ring_alarm()`, `get_alarm()`
- **Smart alarm window NOT IMPLEMENTED** — flaggué TODO dans README + HANDOVER

### OpenStrap/edge
- Pas d'alarm implémentée (Flutter, backend-driven)

### Porting vers Loop
- **Firmware RTC alarm (basique)** : 1-2j. Cmd `SET_ALARM_TIME=66` déjà dans `WhoopProtocol` ? Vérifier `Packages/WhoopProtocol/`. UI dans Sleep detail → AlarmSheet.
- **Smart-wake HR heuristic** : 3-5j. Reprendre `SmartAlarmController.swift` (logique pure testable) + cmds 96/97.
- **Haptic pattern picker** : 1j. 4 patterns WHOOP.

---

## 2. Notifications locales

### my-whoop (le modèle parfait pour Loop)
- `Alerts/BatteryAlertMonitor.swift` + `Alerts/BatteryAlerts.swift` : edge-triggered cross-down threshold, re-arm on charge, `BatteryAlertEvaluator` pure/testé
- `Alerts/RecoveryNotifier.swift` : fire une fois par UTC day quand recovery dispo ("Today's recovery is X%"), dedup par jour
- `Sync/SyncNudge.swift` : schedule-ahead ~6h, cancel on sync, fire only on real stall (force-quit workaround)
- Config : `DeviceSettingsView.batteryAlertsSection` (seuils 5-95% + toggles)

### Goose
- `OnboardingView.swift:459` requestAuthorization `[.alert, .badge, .sound]` (étape onboarding)
- Pitch : "Connection/reconnect status, Battery and sync reminders, Local alerts only"
- Pas d'implé de battery alerts / recovery notifier aussi détaillée que my-whoop

### Porting vers Loop
- **3 notifications** à implémenter (P1-11) : battery alerts + recovery-ready + sync-stale nudge. Reprendre les 3 fichiers de my-whoop presque tels quels (logique pure).

---

## 3. Onboarding

### Goose (le plus complet, 6 étapes)
- `OnboardingView.swift:8` : healthKit (import poids) → location (GPS workouts) → bluetooth → notifications → connect (BLE scan) → profile (firstName/DOB/units/height/weight/gender)
- Auto-skip si permission déjà résolue
- Validation : height 90-245cm, weight 30-320kg, name ≤40 chars, gender required, DOB 13-120y
- Persistence : `OnboardingProfilePersistence` + `@AppStorage(OnboardingStorage.*)`
- Re-do depuis More > Developer

### my-whoop / Loop actuel
- Aucun onboarding (splash 1.8s dans OpenWhoop ; rien dans Loop)

### Porting vers Loop
- **4 étapes** suffisent (pas de HealthKit ni GPS en M1) : BT/Notifications/Connect/Profile. 2-3j.

---

## 4. Recovery / Sleep / Strain / Stress — pages détail

### Goose (V2 "Bevel-style" le plus abouti)
- `SleepV2OverviewPage` (`HealthSleepOverviewViews.swift:6`) : hero + sleep window card (wind down / target bedtime / schedule timeline / sleep needed) + alarm sheet + insights sheet + timeline stages + 8 trend rows + bevel trend sheet
- `RecoveryV2OverviewPage` (`HealthRecoveryStressViews.swift:6`) : hero + scenic background + trend card/band + 6 trend rows (Recovery/HRV/RHR/Resp/SpO₂/Temp) + empty state
- `StrainV2OverviewPage` (`HealthMetricFamilyStrainViews.swift:395`) : hero + score gauge + daily load card + zone meter + 5 HR zones + insights sheet + 5 trend rows
- `StressV2OverviewPage` (`HealthRecoveryStressViews.swift:198`) : hero + score gauge + scenic bg + timeline chart + daily chart + breakdown (High/Medium/Low) + date picker + 3 trend rows
- `CardioLoadView` (`HealthCardioViews.swift:19`) : status (Calibrating/Detraining/Maintaining/Peaking/Productive/Fatigued/Overtraining) + trend panel + detail chart + breakdown + calendar sheet + calibration sheet
- `EnergyBankView` (`HealthSupplementalViews.swift:6`) : chart energy + stress, total charged/drawn, primary sleep charge, usage list

### my-whoop (modèle pour Trends + détail metric)
- `Tabs/TrendsView.swift` : 7D/30D/90D picker + 5 `TrendChartCard` (recovery/HRV/RHR/strain/sleep) + raw HR card + day list
- `Charts/MetricChart.swift` + `Charts/MetricKind.swift` : système de chart factorisé (line pour recovery/HRV/RHR, bar pour strain/sleep, bands couleur recovery)
- `Charts/MetricDetailView.swift` : 1W/1M/3M/6M range selector + stats strip + zoomable + paging prev/next
- `Charts/HeartRateDetailView.swift` : 6H/24H/3D/7D + AVG/MIN/MAX/LATEST + tap-to-highlight
- `Tabs/SevenNightChart.swift` : Gantt 7 lignes (coucher/réveil régularité)
- `Tabs/DayDetailView.swift` : per-day breakdown (recovery+strain+sleep+body signals grid)
- `Tabs/WorkoutDetailView.swift` : header + stats strip + 6-zone HR breakdown + bars + minutes + %

### OpenStrap/edge (12 écrans, déterministe)
- Today/Recovery/Sleep/Activity/Strain detail/Stats/Coach/Metrics/Notifications/Recap/Live workout/Profile
- Home-screen widget + Live Activity iOS

### Porting vers Loop
- **TrendsView** : reprendre `TrendsView.swift` + `MetricChart.swift` + `MetricKind.swift` d'OpenWhoop (3-5j)
- **HeartRateDetailView** : reprendre `HeartRateDetailView.swift` (2-3j)
- **StressDetailView** : reprendre `StressV2OverviewPage` de Goose (2-3j)
- **Sleep 7-nuit** : reprendre `SevenNightChart.swift` (1-2j)
- **WorkoutDetailView** : reprendre `WorkoutDetailView.swift` (2j)

---

## 5. Device management

### Goose (le plus complet)
- `DeviceView.swift:4` : 2 panels (Status / Advanced)
  - Status : connection header (connected/connecting/scanning + name + last sync) + image WHOOP + big battery % + animated `BatteryRail` avec charge pulse
  - Advanced : firmware, battery, charging, last sync, strap clock drift, model, live HR, connection, historical sync, high freq sync, RR packets, Rust status, last parsed frame
  - `DeviceActionGrid` 10 boutons : Bluetooth, Scan/Stop, Connect, Reconnect, Sync/Syncing, High Freq/Exit HF, Watch RR/Stop RR, Hello, Clock, Forget
- `ConnectionView.swift:3` (Connection Lab) : low-level BLE debug séparé
- `GooseBLEClient+Commands.swift` + `+UserActions.swift` + `+VitalsAndLogging.swift` + `+HistoricalCommands.swift`
- Battery auto-refresh 60s

### my-whoop
- `Live/LiveView.swift` : console (LINK/BOND/BATT/WRIST chips + sync freshness + storage + reboot warning) + live HR 72pt + R-R intervals list
- `Settings/DeviceSettingsView.swift` : connect/disconnect + HR start/stop + battery + sync + haptics (pattern 0-7 + loops 0-5) + research/raw capture + log
- `BLE/StuckStrapDetector.swift` : detect connected-but-not-logging
- `BLE/Commands.swift` : `GET_EXTENDED_BATTERY_INFO=98` (voltage mV), `REPORT_VERSION_INFO=7`, `GET_HELLO_HARVARD=35` (serial, charging, isWorn)

### openwhoop-gen4-debug (commands techniques)
- `packet_implementations.rs` : tous les constructeurs de commandes
- Battery : `GET_BATTERY_LEVEL=26` → u16 LE / 10 = % (la standard BLE Battery Service `0x180f` retourne 100% bogus — utiliser la commande vendor)
- `GET_BATTERY_PACK_INFO=151` (parsing incomplet sans WHOOP Body)
- `GetHelloHarvard=35` : serial, charging flag, isWorn

### Porting vers Loop
- **DeviceView repensé** : reprendre `DeviceView.swift:4` de Goose (Status panel) — hero batterie + actions courantes. 1-2j.
- **DeviceAdvancedView** : déplacer tout le debug actuel + ajouter strap clock drift + extended battery info. 0.5-1j.

---

## 6. Live Activity / Widget

### Loop actuel
- `LoopWidgets/` : `LoopMetricsWidget` (systemSmall + systemMedium + accessoryCircular + accessoryRectangular) + `BraceletBatteryLiveActivityWidget` (Live Activity batterie ≤5% / charge)
- `Loop/Shared/LoopWidgetSnapshotStore.swift` : snapshot Sleep/Recovery/Strain/Battery
- `MainTabView.publishWidgetSnapshot()` : publie sur change

### Goose
- `GooseWorkoutLiveActivityExtension/` : `WorkoutLiveActivityWidget` (lock-screen + Dynamic Island expanded/compact/minimal) — workout stats (HR, calories, distance, elapsed)
- `WorkoutLiveActivityController.swift` : start/update/end with 15s min interval + 30min dismissal
- Pas de WidgetKit home-screen widgets

### OpenStrap/edge
- Home-screen widget (recovery/strain/sleep self-refreshing) via `home_widget` package
- Live Activity iOS (workout stats lock screen + Dynamic Island)

### Porting vers Loop
- **Widget metrics** : déjà en place, OK
- **Live Activity workout** : seulement si P2-2 Live Workout (plus tard)

---

## 7. Journal / Symptom tracking

### État des dépôts
- **Aucun dépôt ne l'a implémenté** — Goose a un doc TODO (`docs/goose-swift-mvp/Coach.md:39-46`), non fait
- Cadrage OpenWhoop le met **P1** : "Journal — Habitudes, notes, tags, correlation avec recovery/sleep" — tags suggérés : alcool, caféine, repas tardif, voyage, maladie, stress, workout, supplements

### Porting vers Loop
- **Modèle persistence** à créer : `JournalEntry` (date, tags[], note, optional metrics context)
- **UI** : `JournalView` (calendar + entries list) + `JournalEntryEditor` (tag chips + note field + date picker)
- **Correlation** (P2) : "Alcool la veille → -12% recovery en moyenne"
- 5-7j pour la base, +1-2 semaines pour la correlation

---

## 8. Coach IA

### Goose (le modèle complet, LLM)
- `OpenAICoachChat.swift:4` : `@MainActor` ObservableObject, streaming SSE, conversation persistée (UserDefaults, 80 msg cap)
- OAuth ChatGPT device-code : `CodexSelfContainedAuthClient` (`CodexEmbeddedAuth.swift`) + keychain `CodexStoredChatGPTAuth`
- Model presets : `gpt-5.5` low/medium/high effort (`CoachChatTypes.swift:57`)
- Tool calling : `load_stats`, `get_activities`, `get_capture_sessions`, `get_raw_session_data` (`CoachLocalToolContext.swift:4` construit le JSON context)
- UI : `CoachChatScreen.swift:3` (bubbles, connection strip, suggestions, composer, cancel)
- Deep links : `gooseswift://coach`, `gooseswift://coach/embedded-login`, `goose://codex-auth`
- **Deterministic local coach** aussi : `CoachTips.swift:14` `CoachTipFactory` produit `CoachInlineTip` pour Home/Sleep/Recovery/Strain/Stress

### Loop actuel
- `CoachCard.swift` : déterministe simple (if/else sur recovery/sleepScore/recentOverload)
- `SleepCoachModel.coachingMessage` : déterministe français
- Milestone 2 planifié : COACH-01..05 (LLM)

### Porting vers Loop
- **Court terme** : enrichir CoachCard déterministe avec `adviceSignals[]` (1-2j)
- **Milestones 2** : reprendre `OpenAICoachChat.swift` + `CoachLocalToolContext.swift` (2-3 semaines)

---

## 9. Workout tracking

### Goose (le plus complet, avec GPS)
- 19 `ActivityKind` (`ActivityModels.swift:12`) : Run/Indoor Run/Walk/Hike/Road Ride/MTB/Soccer/Strength/HIIT/Yoga/Row/Indoor Ride/Elliptical/Stair Stepper/Pilates/Barre/Functional Training/Pool Swim
- `ActivitySessionModel.swift:6` : ObservableObject avec 60Hz tick, avg/max HR, 5 zone durations
- `ActivityLocationTracker.swift:6` : CLLocationManager, `kCLLocationAccuracyBest`, 5m filter, **background updates enabled**, `showsBackgroundLocationIndicator = true`, cap 360 route points, pace-colored segments
- `GooseAppModel+ActivityRecording.swift` : begin/finish, high-freq history sync pendant workout
- `FitnessLiveWorkoutViews.swift` : paged metrics (Overview/HR/Segment/Split/Elevation/Rings), control dock (pause/resume/end + control lock 5s), countdown, activity picker
- `FitnessSummaryViews.swift:6` : post-workout summary (details card + route map + pace block + zone ribbon + elevation chart + activity rings + segment badge)
- `PassiveActivityDetector.swift:12` : auto-start/finish depuis band movement packets (8s GPS prime, 45s start duration, 120s stop quiet, 60s min recording), classifie activity depuis pace/HR/motion

### my-whoop (auto-detect server-side, plus simple)
- `Tabs/WorkoutsView.swift` : list 30 derniers workouts auto-détectés (date/duration/avg HR/strain/calories)
- `Tabs/WorkoutDetailView.swift` : header + stats strip (strain, avg HR, peak HR, calories) + 6-zone HR breakdown
- Auto-detection server-side (`exercise.py` / `activity.py`)
- Calorie backfill sur profile save (60j recompute)

### Loop actuel
- `ActivityTimeline` : affiche les `WorkoutSession` auto-détectés (déjà dans le moteur), avec rejet utilisateur. Pas de GPS, pas de live workout, pas de workout detail view.

### Porting vers Loop
- **WorkoutDetailView** (P1-14) : reprendre `WorkoutDetailView.swift` d'OpenWhoop (2j) — afficher le détail d'une `WorkoutSession` existante
- **Live Workout** (P2-2) : 2-3 semaines, GPS + Live Activity
- **Passive auto-detection** : déjà partiellement dans le moteur Loop (workoutSessions)

---

## 10. Export / Backup

### Loop actuel
- `BackupCoordinator` : export/import `.loopbackup` (`whoop.sqlite` + `cache.json` + `meta.json`) via `UIDocumentPickerViewController`. Custom UTType `com.iblur01.loop.backup`. Aucun entitlement.

### Goose
- `GooseLocalDataExporter.swift:418` : `.goosebundle.json` (schema `goose.local-data-export.v1`), base64 + SHA-256, `FileProtectionType.completeUntilFirstUserAuthentication`
- `MoreRawExportView.swift` : export window + scope + filters (capture sessions, packet types, sensor signals, metric families, algorithm ids, raw-bytes toggle) + AirDrop ShareLinks

### my-whoop
- Server-mediated only (Uploader + ServerSync + restoreIfEmpty 400j)
- Pas de file export

### Porting vers Loop
- **BackupView** dédié sous Profile → Settings : reprendre la section actuelle + ajouter AirDrop ShareLink (1-2j)
- Pas besoin du filtre complexe de Goose (trop research)

---

## 11. Health Monitor (vitals + "hors normal pour toi")

### Goose
- `HealthMonitorView` (`HealthDashboardViews.swift:472`) : resting HR + resting HRV + respiratory rate + oxygen saturation + wrist temperature, avec trend sheets

### Cadrage OpenWhoop (P1)
- "Health Monitor (HRV/RHR/resp/SpO₂/temp + 'out of normal for you' wording)"

### Porting vers Loop
- **P1-8** : 3-5j. Nécessite d'exposer Resp/SpO₂/Skin Temp côté moteur (P2-7) pour avoir toutes les tuiles. V1 avec HRV + RHR + Sleep seulement (déjà en cache), puis enrichir.

---

## 12. Trends / Stats

### my-whoop (le plus simple et réutilisable)
- `Tabs/TrendsView.swift` : 7D/30D/90D segmented + 5 trend chart cards + raw HR card + day list
- `Charts/MetricKind.swift` : enum qui drive tout (style, color, mark, y-domain, formatting) — ajouter une metric = 1 case

### Goose (plus élaboré)
- Bevel-style trend sheets : `SleepV2BevelTrendSheet` + range selector + trend chart
- Cardio Load charts : `CardioLoadDetailChart`, `CardioLoadTrendPanel`, `CardioLoadCalendarSheet`
- HR hourly timeline : `HealthDataStore.heartRateHourlyTimelineRows()`

### OpenStrap/edge
- `Stats` : week/month/3-month trends strain/recovery/RHR/sleep/wear

### Porting vers Loop
- **TrendsView** (P1-1) : reprendre `TrendsView.swift` + `MetricChart.swift` + `MetricKind.swift` d'OpenWhoop. 3-5j. Données en cache (60j daily).

---

## 13. Recap / Shareable

### OpenStrap/edge
- `Recap` : card shareable de la semaine (chiffres clés + `share_plus`)

### Porting vers Loop
- **P1-13** : 1-2j. `ShareLink` SwiftUI avec une card générée (Image renderer ou juste texte mis en forme).

---

## 14. BLE commands spécifiques (référence technique)

### Depuis openwhoop-gen4-debug `constants.rs`
| Command | Opcode | Usage |
|---|---|---|
| `ToggleRealtimeHr` | 3 | Start/stop live HR stream |
| `ReportVersionInfo` | 7 | Firmware Harvard + Boylston |
| `SetClock` | 10 | Set strap RTC (obligatoire à chaque connect) |
| `GetClock` | 11 | Read strap clock (drift) |
| `SendHistoricalData` | 22 | Start history offload |
| `HistoricalDataResult` | 23 | ACK batch + token echo (`inner[13:21]`) |
| `GetBatteryLevel` | 26 | u16 LE / 10 = % |
| `RebootStrap` | 29 | Force reboot (stuck strap) |
| `SetReadPointer` | 33 | Position read cursor |
| `GetDataRange` | 34 | Min/max ts available |
| `GetHelloHarvard` | 35 | Serial, charging flag, isWorn |
| `SetAlarmTime` | 66 | `[0x01]+epoch u32 LE+[0x00×4]` (padding smart-wake ?) |
| `GetAlarmTime` | 67 | Read current alarm |
| `RunAlarm` | 68 | Fire haptic immediately |
| `DisableAlarm` | 69 | Disable all alarms |
| `EnterHighFreqSync` | 96 | Dense HR for smart-wake window |
| `ExitHighFreqSync` | 97 | Exit dense mode (safety invariant) |
| `ToggleImuMode` | 106 | Start/stop IMU stream |
| `GetBatteryPackInfo` | 151 | Battery pack details (parsing incomplet) |
| `RunHapticPatternMaverick` | 19 | Gen5 haptic |
| `AbortHistoricalTransmit` | 20 | Abort history |
| `ForceTrim` | 25 | Erase flash (DANGEROUS, gated) |

### Events (surfaced)
| Event | Opcode | Usage |
|---|---|---|
| `ChargingOn` / `ChargingOff` | 7 / 8 | Charging state |
| `WristOn` / `WristOff` | 9 / 10 | Wrist detection |
| `DoubleTap` | 14 | Double-tap gesture |
| `BatteryPackConnected` / `Removed` | 21 / 22 | Charger dock |
| `StrapDrivenAlarmSet` / `Executed` | 56 / 57 | Firmware alarm |
| `AppDrivenAlarmExecuted` | 58 | App-triggered alarm |
| `HapticsFired` | 60 | Haptic event |

### Vérifier côté Loop
- Toutes ces commandes sont-elles déjà dans `Packages/WhoopProtocol/` ? Faire un diff entre `constants.rs` et `protocol/whoop_protocol.json` pour identifier les gaps.

---

## 15. Algos purs à porter (openwhoop-gen4-debug → LoopStrapEngine)

| Algo | Fichier Rust | LOC | Complexité | Priorité |
|---|---|---|---|---|
| Gravity-based sleep/activity detection | `algos/src/activity.rs` | ~150 | Moyenne | Déjà dans LoopStrapEngine (vérifier parité) |
| RMSSD HRV | `algos/src/sleep.rs` | ~50 | Triviale | Déjà dans LoopStrapEngine |
| Baevsky stress index | `algos/src/stress.rs` | ~80 | Moyenne | Déjà dans LoopStrapEngine |
| Edwards TRIMP strain → 0-21 | `algos/src/strain.rs` | ~100 | Moyenne | Déjà dans LoopStrapEngine |
| Sleep consistency (circular mean + CV) | `algos/src/sleep_consistency.rs` | ~80 | Triviale | **À porter** (P2-6) |
| Circular time math | `algos/src/helpers/time_math.rs` | ~40 | Triviale | Requis pour sleep consistency |
| Exercise metrics (count/duration stats) | `algos/src/exercise.rs` | ~30 | Triviale | Déjà couvert par `WorkoutSession` |

---

## 16. Cadrage OpenWhoop — features planifiées non implémentées

Source : `my-whoop/2026-06-12-openwhoop-redesign-cadrage.md` (lire en full pour le détail)

**North Star** : "Comment va mon corps aujourd'hui, qu'est-ce qui explique cet état, et quelle action raisonnable je peux prendre ?"

**Principes design** : Daily first (<10s) · Explain don't decorate (every score = factors + confidence) · Local-first trust (visible freshness/sync/limits) · Calm physiology · Progressive depth · No medical overclaim

**Priorités produit** :
- **P0** : Today (cockpit), Recovery, Sleep, Device & Sync
- **P1** : Health Monitor, Trends (7/30/90d + calendar heatmap), Journal (tags + note + correlation), Insights/Coach
- **P2** : Stress, Workouts/Exercise, Body Profile
- **P3 (out of scope)** : Healthspan/long-term, Labs/medical (ECG/blood pressure)

**Idées par page** (cf. cadrage pour le détail) :
- Today : hero Recovery vs Readiness vs Body Battery (décision ouverte) — "Tonight target" card — "What hurt sleep" placeholders — regularity streak — "What changed" section — "Signals to trust most" — data-quality timeline — calendar heatmap — weekly summary
- Recovery : "Why is my recovery low?" Q&A — weekly review
- Sleep : sleep needed + debt + consistency streak
- Device & Sync : top-level tab ou settings entry (décision ouverte)
- Trends : calendar heatmap + chronological feed

**First wave build order** : 1) Today, 2) Device & Sync, 3) Sleep, 4) Recovery, 5) Trends

**Loop Milestone 1 ROADMAP** (`loop/.planning/ROADMAP.md`) : 7 phases portant le calc engine Python → Swift (Foundation → HRV → Sleep staging → Kubios fixpeaks → Welch PSD/HRV-frequency → Daily metrics → Advice signals + offline cutover). **Milestone 2 (deferred)** = LLM coach.

---

## 17. OpenStrap/edge — résumé des 12 écrans

Source : README + screenshots (https://github.com/OpenStrap/edge)

| Écran | Description |
|---|---|
| Today | Readiness up top, Strain/Sleep/HRV gauges, plan du jour |
| Recovery | Readiness breakdown (RHR, sleep, consistency) |
| Sleep | Time asleep vs need, stage estimate, efficiency, debt, nocturnal heart |
| Activity | Day strain, time in HR zones, training load, auto-detected workouts |
| Strain detail | Strain built through day, zone breakdown, HR highs/lows |
| Stats | Week/month/3-month trends strain/recovery/RHR/sleep/wear |
| Coach | Deterministic plan: strain target + ranked plain-English suggestions |
| Metrics | Full tile set: RHR, calories, steps, wear time, stress, HRV (RMSSD), blood-O₂ |
| Notifications | Server nudges (sleep debt, recovery, milestones), capped |
| Recap | Shareable weekly card |
| Live workout | Real-time HR, live strain, calories, burn rate |
| Profile | Device + wear status, body metrics, self-hosted-backend toggle |

iOS extras : Home-screen widget (recovery/strain/sleep, self-refreshing) + Live Activity (workout stats lock screen + Dynamic Island)

**Stack** : `flutter_blue_plus`, `sqflite`, `http`, `provider`, `shared_preferences`, `workmanager` (BG sync 15min), `home_widget`, `fl_chart`, `google_fonts`, `hugeicons`, `share_plus`

**Architecture** : `AppState` (ChangeNotifier) single source of truth · BleEngine · LocalDb (`raw_records` PK = frame hex, INSERT OR IGNORE) · Uploader (POST → delete local) · BGTask 15min

**Principes applicables à Loop** :
- Raw frames PK = frame hex → retries safe (Loop fait déjà ça côté WhoopStore)
- Uploader delete-after-confirm (Loop n'upload pas, pas pertinent)
- BGTask 15min wakeup (Loop a déjà `BackgroundTaskManager`, vérifier la fréquence)
- AppState single source of truth → Loop a `LoopDataRepository.cache` (équivalent)
